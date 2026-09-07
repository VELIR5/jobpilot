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
  if ([string]::IsNullOrWhiteSpace($value)) { throw "Missing required environment variable: $Name" }
  return $value
}

function Invoke-Checked([string]$FilePath, [string[]]$Arguments) {
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$FilePath failed with exit code $LASTEXITCODE" }
}

function Stop-JobPilotTask([string]$TaskName) {
  $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  if ($task.State -in @("Running", "Queued")) {
    Stop-ScheduledTask -TaskName $TaskName
    $deadline = (Get-Date).AddSeconds(30)
    do {
      Start-Sleep -Milliseconds 500
      $task = Get-ScheduledTask -TaskName $TaskName
    } while ($task.State -in @("Running", "Queued") -and (Get-Date) -lt $deadline)
    if ($task.State -in @("Running", "Queued")) { throw "Scheduled task $TaskName did not stop" }
  }
}

function Start-JobPilotTask([string]$TaskName) {
  Start-ScheduledTask -TaskName $TaskName
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-ReleaseMetadata([string]$RuntimeRoot, [string]$Sha, [string]$ReleasedAt) {
  $content = @(
    "JOBPILOT_RELEASE_SHA=`"$Sha`""
    "JOBPILOT_RELEASED_AT=`"$ReleasedAt`""
  ) -join [Environment]::NewLine
  Write-Utf8NoBom (Join-Path $RuntimeRoot ".jobpilot-release.env") ($content + [Environment]::NewLine)
}

function Copy-RuntimeConfiguration([string]$SourceRoot, [string]$RuntimeRoot) {
  foreach ($name in @(".env", ".env.local", ".env.production", ".env.production.local")) {
    $source = Join-Path $SourceRoot $name
    $destination = Join-Path $RuntimeRoot $name
    if (Test-Path -LiteralPath $source) {
      Copy-Item -LiteralPath $source -Destination $destination -Force
    } elseif (Test-Path -LiteralPath $destination) {
      Remove-Item -LiteralPath $destination -Force
    }
  }
  $feedConfig = Join-Path $SourceRoot "config\job-feeds.json"
  $runtimeFeedConfig = Join-Path $RuntimeRoot "config\job-feeds.json"
  if (Test-Path -LiteralPath $feedConfig) {
    Copy-Item -LiteralPath $feedConfig -Destination $runtimeFeedConfig -Force
  } elseif (Test-Path -LiteralPath $runtimeFeedConfig) {
    Remove-Item -LiteralPath $runtimeFeedConfig -Force
  }
}

function Set-CurrentRuntime([string]$PointerPath, [string]$RuntimeRoot) {
  $temporaryPointer = "$PointerPath.new"
  Write-Utf8NoBom $temporaryPointer ($RuntimeRoot + [Environment]::NewLine)
  if (Test-Path -LiteralPath $PointerPath) {
    [IO.File]::Replace($temporaryPointer, $PointerPath, $null)
  } else {
    [IO.File]::Move($temporaryPointer, $PointerPath)
  }
}

function Read-ReleaseSha([string]$RuntimeRoot) {
  $metadata = Join-Path $RuntimeRoot ".jobpilot-release.env"
  if (Test-Path -LiteralPath $metadata) {
    foreach ($line in Get-Content -LiteralPath $metadata) {
      if ($line -match '^JOBPILOT_RELEASE_SHA="([0-9a-fA-F]{40})"$') { return $Matches[1].ToLowerInvariant() }
    }
  }
  $sha = (& git -C $RuntimeRoot rev-parse HEAD).Trim().ToLowerInvariant()
  if ($LASTEXITCODE -ne 0 -or $sha -notmatch '^[0-9a-f]{40}$') { throw "Unable to identify deployed commit" }
  return $sha
}

function Wait-ForRelease([string]$Url, [string]$ExpectedSha, [int]$TimeoutSeconds = 90) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    try {
      $response = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 10 -Headers @{ "Cache-Control" = "no-cache" }
      if ($response.status -eq "ok" -and $response.releaseSha -eq $ExpectedSha) { return }
    } catch {
      # The process may still be starting.
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
      # The process may still be starting.
    }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  throw "HTTP readiness check failed at $Url"
}

$controlDir = [IO.Path]::GetFullPath((Require-EnvironmentValue "JOBPILOT_PRODUCTION_DIR"))
$dataDir = [IO.Path]::GetFullPath((Require-EnvironmentValue "JOBPILOT_DEPLOY_DATA_DIR"))
$uploadDir = [IO.Path]::GetFullPath((Require-EnvironmentValue "JOBPILOT_UPLOAD_DIR"))
$releaseRoot = [IO.Path]::GetFullPath((Require-EnvironmentValue "JOBPILOT_RELEASES_DIR"))
$taskName = if ($env:JOBPILOT_TASK_NAME) { $env:JOBPILOT_TASK_NAME } else { "JobPilot" }
$localHealthUrl = if ($env:JOBPILOT_LOCAL_HEALTH_URL) { $env:JOBPILOT_LOCAL_HEALTH_URL } else { "http://127.0.0.1:3000/api/health" }
$publicHealthUrl = if ($env:JOBPILOT_PUBLIC_HEALTH_URL) { $env:JOBPILOT_PUBLIC_HEALTH_URL } else { "https://job.vcrelay.com/api/health" }
$pointerPath = Join-Path $controlDir ".jobpilot-current-release"
$blockedPath = Join-Path $controlDir ".jobpilot-blocked-sha"

if (-not (Test-Path -LiteralPath (Join-Path $controlDir ".git"))) { throw "Production control directory is not a Git checkout" }
if (-not (Test-Path -LiteralPath (Join-Path $controlDir ".env"))) { throw "Production .env is missing" }
if (-not (Test-Path -LiteralPath (Join-Path $dataDir "jobpilot.db"))) { throw "Existing production database not found; refusing to create an empty replacement" }
if ($dataDir.StartsWith($controlDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "SQLite data must be outside the Git checkout" }
if ($releaseRoot -eq $controlDir -or $releaseRoot.StartsWith($controlDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $controlDir.StartsWith($releaseRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Release storage must not overlap the Git checkout" }
if ($releaseRoot -eq $dataDir -or $releaseRoot.StartsWith($dataDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $dataDir.StartsWith($releaseRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Release storage must not overlap the SQLite data directory" }
if ($releaseRoot -eq $uploadDir -or $releaseRoot.StartsWith($uploadDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $uploadDir.StartsWith($releaseRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Release storage must not overlap the upload directory" }
Get-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Path $uploadDir -Force | Out-Null
New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null

$originUrl = (& git -C $controlDir remote get-url origin).Trim()
if ($LASTEXITCODE -ne 0 -or $originUrl -notmatch "(?:github\.com[:/])VELIR5/jobpilot(?:\.git)?$") { throw "Production checkout origin is not VELIR5/jobpilot" }
$trackedChanges = & git -C $controlDir status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $trackedChanges) { throw "Production control checkout has tracked changes" }

Invoke-Checked "git" @("-C", $controlDir, "fetch", "--prune", "origin", "master")
$targetShaNormalized = $TargetSha.ToLowerInvariant()
$masterSha = (& git -C $controlDir rev-parse "origin/master").Trim().ToLowerInvariant()
if ($targetShaNormalized -ne $masterSha) { throw "Target commit is no longer the tip of origin/master" }

$previousRuntime = if (Test-Path -LiteralPath $pointerPath) {
  [IO.Path]::GetFullPath((Get-Content -LiteralPath $pointerPath -TotalCount 1).Trim())
} else {
  $controlDir
}
$releasePrefix = $releaseRoot.TrimEnd('\') + '\'
if ($previousRuntime -ne $controlDir -and -not $previousRuntime.StartsWith($releasePrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Current release pointer is outside the approved runtime directories"
}
if (-not (Test-Path -LiteralPath $previousRuntime)) { throw "Current runtime directory does not exist" }
$previousSha = Read-ReleaseSha $previousRuntime

if ($previousSha -eq $targetShaNormalized) {
  try {
    Wait-ForRelease $localHealthUrl $targetShaNormalized 20
  } catch {
    try {
      Stop-JobPilotTask $taskName
      Start-JobPilotTask $taskName
      Wait-ForRelease $localHealthUrl $targetShaNormalized
    } catch {
      Write-Utf8NoBom $blockedPath ($targetShaNormalized + [Environment]::NewLine)
      throw
    }
  }
  try {
    Wait-ForRelease $publicHealthUrl $targetShaNormalized 20
  } catch {
    Write-Warning "The local release is healthy, but the public Cloudflare endpoint is not reporting it."
    exit 0
  }
  Write-Host "Production is healthy at $targetShaNormalized"
  exit 0
}

& git -C $controlDir merge-base --is-ancestor $previousSha $targetShaNormalized
if ($LASTEXITCODE -ne 0) { throw "Target commit is not a forward update from the deployed commit" }

$candidate = Join-Path $releaseRoot $targetShaNormalized
$buildMarker = Join-Path $candidate ".jobpilot-build-complete"
$releasedAt = [DateTime]::UtcNow.ToString("o")
$temporaryBuildData = Join-Path ([IO.Path]::GetTempPath()) ("jobpilot-build-{0}" -f $targetShaNormalized)
$taskStopped = $false
$pointerSwitched = $false
$controlSwitched = $false

try {
  if (Test-Path -LiteralPath $candidate) {
    if (-not (Test-Path -LiteralPath $buildMarker) -or -not (Test-Path -LiteralPath (Join-Path $candidate ".next-build")) -or -not (Test-Path -LiteralPath (Join-Path $candidate "node_modules"))) {
      Invoke-Checked "git" @("-C", $controlDir, "worktree", "remove", "--force", "--force", $candidate)
    }
  }

  if (-not (Test-Path -LiteralPath $candidate)) {
    Invoke-Checked "git" @("-C", $controlDir, "worktree", "add", "--detach", $candidate, $targetShaNormalized)
    Copy-RuntimeConfiguration $controlDir $candidate

    New-Item -ItemType Directory -Path $temporaryBuildData -Force | Out-Null
    $env:JOBPILOT_DATA_DIR = $temporaryBuildData
    $env:JOBPILOT_UPLOAD_DIR = $uploadDir
    $env:JOBPILOT_RELEASE_SHA = $targetShaNormalized
    $env:JOBPILOT_RELEASED_AT = $releasedAt
    Push-Location $candidate
    try {
      Invoke-Checked "npm.cmd" @("ci", "--no-audit", "--no-fund")
      Invoke-Checked "npm.cmd" @("run", "db:push")
      Invoke-Checked "npm.cmd" @("run", "build")
    } finally {
      Pop-Location
    }
    Write-Utf8NoBom $buildMarker ($releasedAt + [Environment]::NewLine)
  } else {
    Copy-RuntimeConfiguration $controlDir $candidate
  }

  Stop-JobPilotTask $taskName
  $taskStopped = $true

  $backupDir = Join-Path (Join-Path $dataDir "backups") ("deploy-{0}-{1}" -f [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss"), $previousSha.Substring(0, 12))
  New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
  foreach ($name in @("jobpilot.db", "jobpilot.db-wal", "jobpilot.db-shm")) {
    $source = Join-Path $dataDir $name
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $backupDir -Force }
  }

  $env:JOBPILOT_DATA_DIR = $dataDir
  Push-Location $candidate
  try { Invoke-Checked "npm.cmd" @("run", "db:push") } finally { Pop-Location }
  Write-ReleaseMetadata $candidate $targetShaNormalized $releasedAt

  Invoke-Checked "git" @("-C", $controlDir, "checkout", "--detach", $targetShaNormalized)
  $controlSwitched = $true
  Set-CurrentRuntime $pointerPath $candidate
  $pointerSwitched = $true

  Start-JobPilotTask $taskName
  $taskStopped = $false
  Wait-ForRelease $localHealthUrl $targetShaNormalized
  Wait-ForRelease $publicHealthUrl $targetShaNormalized
  if (Test-Path -LiteralPath $blockedPath) { Remove-Item -LiteralPath $blockedPath -Force }
  Write-Host "Deployment verified: $targetShaNormalized"
} catch {
  $failure = $_
  Write-Utf8NoBom $blockedPath ($targetShaNormalized + [Environment]::NewLine)
  Write-Warning "Deployment failed; restoring runtime $previousSha. Database migrations are not reversed."
  try {
    if ($taskStopped -or $pointerSwitched -or $controlSwitched) {
      Stop-JobPilotTask $taskName
      $taskStopped = $true
      if ($previousRuntime -eq $controlDir -and $controlSwitched) {
        Invoke-Checked "git" @("-C", $controlDir, "checkout", "--detach", $previousSha)
      }
      Set-CurrentRuntime $pointerPath $previousRuntime
      Start-JobPilotTask $taskName
      $taskStopped = $false
      try {
        Wait-ForRelease $localHealthUrl $previousSha 60
        Wait-ForRelease $publicHealthUrl $previousSha 60
      } catch {
        Wait-ForHttpOk ($localHealthUrl -replace '/api/health.*$', '/gate') 60
        Wait-ForHttpOk ($publicHealthUrl -replace '/api/health.*$', '/gate') 60
        Write-Warning "Rollback is serving traffic, but the previous release cannot report its exact SHA."
      }
    }
  } catch {
    Write-Warning "Automatic runtime rollback also failed: $($_.Exception.Message)"
  }
  throw $failure
} finally {
  if (Test-Path -LiteralPath $temporaryBuildData) { Remove-Item -LiteralPath $temporaryBuildData -Recurse -Force -ErrorAction SilentlyContinue }
  if ($taskStopped) {
    try { Start-JobPilotTask $taskName } catch { Write-Warning "Unable to restart $taskName" }
  }
}
