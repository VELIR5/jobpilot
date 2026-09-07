[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[0-9a-fA-F]{40}$")]
  [string]$TargetSha
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Require-EnvironmentValue([string]$Name) {
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) {
    throw "Missing required runner environment variable: $Name"
  }
  return $value
}

function Invoke-Checked([string]$FilePath, [string[]]$Arguments) {
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath failed with exit code $LASTEXITCODE"
  }
}

function Stop-JobPilotTask([string]$TaskName) {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  if ($task.State -eq "Running") {
    Stop-ScheduledTask -TaskName $TaskName
    $deadline = (Get-Date).AddSeconds(30)
    do {
      Start-Sleep -Milliseconds 500
      $task = Get-ScheduledTask -TaskName $TaskName
    } while ($task.State -eq "Running" -and (Get-Date) -lt $deadline)
    if ($task.State -eq "Running") { throw "Scheduled task $TaskName did not stop" }
  }
}

function Start-JobPilotTask([string]$TaskName) {
  Start-ScheduledTask -TaskName $TaskName
}

function Write-ReleaseMetadata([string]$ProjectRoot, [string]$Sha, [string]$ReleasedAt, [string]$PersistentDataDir) {
  $content = @(
    "JOBPILOT_RELEASE_SHA=`"$Sha`""
    "JOBPILOT_RELEASED_AT=`"$ReleasedAt`""
    "JOBPILOT_DATA_DIR=`"$PersistentDataDir`""
  ) -join [Environment]::NewLine
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText(
    (Join-Path $ProjectRoot ".jobpilot-release.env"),
    $content + [Environment]::NewLine,
    $utf8NoBom
  )
}

function Wait-ForRelease([string]$Url, [string]$ExpectedSha, [int]$TimeoutSeconds = 90) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    try {
      $response = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 10 -Headers @{ "Cache-Control" = "no-cache" }
      if ($response.status -eq "ok" -and $response.releaseSha -eq $ExpectedSha) { return }
    } catch {
      # The application may still be starting.
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw "Release health check did not report $ExpectedSha at $Url"
}

function Wait-ForHttpOk([string]$Url, [int]$TimeoutSeconds = 90) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    try {
      $response = Invoke-WebRequest -Uri $Url -Method Get -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 5
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) { return }
    } catch {
      # The application may still be starting.
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw "HTTP readiness check failed at $Url"
}

$productionDir = [IO.Path]::GetFullPath((Require-EnvironmentValue "JOBPILOT_PRODUCTION_DIR"))
$taskName = if ($env:JOBPILOT_TASK_NAME) { $env:JOBPILOT_TASK_NAME } else { "JobPilot" }
$localHealthUrl = if ($env:JOBPILOT_LOCAL_HEALTH_URL) { $env:JOBPILOT_LOCAL_HEALTH_URL } else { "http://127.0.0.1:3000/api/health" }
$publicHealthUrl = if ($env:JOBPILOT_PUBLIC_HEALTH_URL) { $env:JOBPILOT_PUBLIC_HEALTH_URL } else { "https://job.vcrelay.com/api/health" }
$dataDir = [IO.Path]::GetFullPath((Require-EnvironmentValue "JOBPILOT_DEPLOY_DATA_DIR"))

if (-not (Test-Path -LiteralPath (Join-Path $productionDir ".git"))) {
  throw "JOBPILOT_PRODUCTION_DIR is not a Git checkout: $productionDir"
}
if ($env:GITHUB_WORKSPACE -and [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE).TrimEnd('\') -eq $productionDir.TrimEnd('\')) {
  throw "The production checkout must be separate from the Actions runner workspace"
}
if (-not (Test-Path -LiteralPath (Join-Path $productionDir ".env"))) {
  throw "Production .env is missing; refusing to deploy"
}
if ($dataDir.StartsWith($productionDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "The persistent SQLite directory must be outside the production Git checkout"
}
if (-not (Test-Path -LiteralPath (Join-Path $dataDir "jobpilot.db"))) {
  throw "Existing production database not found in JOBPILOT_DEPLOY_DATA_DIR; refusing to create an empty replacement"
}
Get-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null

$originUrl = (& git -C $productionDir remote get-url origin).Trim()
if ($LASTEXITCODE -ne 0 -or $originUrl -notmatch "(?:github\.com[:/])VELIR5/jobpilot(?:\.git)?$") {
  throw "Production checkout origin is not VELIR5/jobpilot"
}

$trackedChanges = & git -C $productionDir status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect the production checkout" }
if ($trackedChanges) { throw "Production checkout has tracked changes; refusing to overwrite them" }

Invoke-Checked "git" @("-C", $productionDir, "fetch", "--prune", "origin", "master")
Invoke-Checked "git" @("-C", $productionDir, "cat-file", "-e", "$TargetSha^{commit}")
$masterSha = (& git -C $productionDir rev-parse "origin/master").Trim().ToLowerInvariant()
$targetShaNormalized = $TargetSha.ToLowerInvariant()
if ($targetShaNormalized -ne $masterSha) { throw "Target commit is no longer the tip of origin/master" }

$previousSha = (& git -C $productionDir rev-parse HEAD).Trim().ToLowerInvariant()
if ($previousSha -eq $targetShaNormalized) {
  Write-Host "Production already points to $targetShaNormalized; verifying health only."
  try {
    Wait-ForRelease $publicHealthUrl $targetShaNormalized 20
  } catch {
    Write-ReleaseMetadata $productionDir $targetShaNormalized ([DateTime]::UtcNow.ToString("o")) $dataDir
    Stop-JobPilotTask $taskName
    Start-JobPilotTask $taskName
    Wait-ForRelease $localHealthUrl $targetShaNormalized
    Wait-ForRelease $publicHealthUrl $targetShaNormalized
  }
  exit 0
}
& git -C $productionDir merge-base --is-ancestor $previousSha $targetShaNormalized
if ($LASTEXITCODE -ne 0) { throw "Target commit is not a forward update from the deployed commit" }

$releasedAt = [DateTime]::UtcNow.ToString("o")
$backupRoot = Join-Path $dataDir "backups"
$backupDir = Join-Path $backupRoot ("deploy-{0}-{1}" -f [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), $previousSha.Substring(0, 12))
$buildBackup = Join-Path $productionDir ".next-build.deploy-rollback"
$temporaryBuildData = Join-Path ([IO.Path]::GetTempPath()) ("jobpilot-build-{0}" -f $targetShaNormalized)
$releaseSwitched = $false
$buildBackedUp = $false
$taskStopped = $false

try {
  Stop-JobPilotTask $taskName
  $taskStopped = $true

  New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
  foreach ($name in @("jobpilot.db", "jobpilot.db-wal", "jobpilot.db-shm")) {
    $source = Join-Path $dataDir $name
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $backupDir -Force }
  }

  if (Test-Path -LiteralPath $buildBackup) { Remove-Item -LiteralPath $buildBackup -Recurse -Force }
  $currentBuild = Join-Path $productionDir ".next-build"
  if (Test-Path -LiteralPath $currentBuild) {
    Move-Item -LiteralPath $currentBuild -Destination $buildBackup
    $buildBackedUp = $true
  }

  Invoke-Checked "git" @("-C", $productionDir, "checkout", "--detach", $targetShaNormalized)
  $releaseSwitched = $true
  Write-ReleaseMetadata $productionDir $targetShaNormalized $releasedAt $dataDir
  $env:JOBPILOT_RELEASE_SHA = $targetShaNormalized
  $env:JOBPILOT_RELEASED_AT = $releasedAt

  Push-Location $productionDir
  try {
    Invoke-Checked "npm.cmd" @("ci", "--no-audit", "--no-fund")
    New-Item -ItemType Directory -Path $temporaryBuildData -Force | Out-Null
    $env:JOBPILOT_DATA_DIR = $temporaryBuildData
    Invoke-Checked "npm.cmd" @("run", "db:push")
    Invoke-Checked "npm.cmd" @("run", "build")
    $env:JOBPILOT_DATA_DIR = $dataDir
    Invoke-Checked "npm.cmd" @("run", "db:push")
  } finally {
    $env:JOBPILOT_DATA_DIR = $dataDir
    Pop-Location
  }

  Start-JobPilotTask $taskName
  $taskStopped = $false
  Wait-ForRelease $localHealthUrl $targetShaNormalized
  Wait-ForRelease $publicHealthUrl $targetShaNormalized

  if (Test-Path -LiteralPath $buildBackup) { Remove-Item -LiteralPath $buildBackup -Recurse -Force }
  Write-Host "Deployment verified: $targetShaNormalized"
} catch {
  $failure = $_
  Write-Warning "Deployment failed; restoring code and process to $previousSha. Database migrations are not reversed."
  try {
    Stop-JobPilotTask $taskName
    $taskStopped = $true
    if ($releaseSwitched) { Invoke-Checked "git" @("-C", $productionDir, "checkout", "--detach", $previousSha) }
    Write-ReleaseMetadata $productionDir $previousSha ([DateTime]::UtcNow.ToString("o")) $dataDir

    $currentBuild = Join-Path $productionDir ".next-build"
    if ($buildBackedUp -and (Test-Path -LiteralPath $buildBackup)) {
      if (Test-Path -LiteralPath $currentBuild) { Remove-Item -LiteralPath $currentBuild -Recurse -Force }
      Move-Item -LiteralPath $buildBackup -Destination $currentBuild
    }

    if ($releaseSwitched) {
      Push-Location $productionDir
      try {
        Invoke-Checked "npm.cmd" @("ci", "--no-audit", "--no-fund")
        if (-not (Test-Path -LiteralPath $currentBuild)) {
          $env:JOBPILOT_DATA_DIR = $temporaryBuildData
          Invoke-Checked "npm.cmd" @("run", "db:push")
          Invoke-Checked "npm.cmd" @("run", "build")
        }
      } finally {
        $env:JOBPILOT_DATA_DIR = $dataDir
        Pop-Location
      }
    }
    Start-JobPilotTask $taskName
    $taskStopped = $false
    try {
      Wait-ForRelease $localHealthUrl $previousSha 60
      Wait-ForRelease $publicHealthUrl $previousSha 60
    } catch {
      $localReadyUrl = $localHealthUrl -replace '/api/health.*$', '/gate'
      $publicReadyUrl = $publicHealthUrl -replace '/api/health.*$', '/gate'
      Wait-ForHttpOk $localReadyUrl 60
      Wait-ForHttpOk $publicReadyUrl 60
      Write-Warning "Rollback is serving traffic, but the previous release cannot report its exact SHA."
    }
  } catch {
    Write-Warning "Automatic process rollback also failed: $($_.Exception.Message)"
  }
  throw $failure
} finally {
  if (Test-Path -LiteralPath $temporaryBuildData) {
    Remove-Item -LiteralPath $temporaryBuildData -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($taskStopped) {
    try { Start-JobPilotTask $taskName } catch { Write-Warning "Unable to restart $taskName" }
  }
}
