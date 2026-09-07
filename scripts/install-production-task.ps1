[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectRoot,
  [Parameter(Mandatory = $true)]
  [string]$DataDir,
  [Parameter(Mandatory = $true)]
  [string]$ReleasesDir,
  [string]$UploadDir,
  [ValidatePattern("^[A-Za-z0-9_.-]+$")]
  [string]$TaskName = "JobPilot",
  [ValidatePattern("^[A-Za-z0-9_.-]+$")]
  [string]$DeployTaskName = "JobPilotDeploy",
  [ValidateRange(2, 30)]
  [int]$PollMinutes = 3,
  [string]$LocalReadyUrl = "http://127.0.0.1:3000/gate",
  [switch]$EnableDeployment
)

$ErrorActionPreference = "Stop"
$project = [IO.Path]::GetFullPath($ProjectRoot)
$persistentData = [IO.Path]::GetFullPath($DataDir)
$releaseRoot = [IO.Path]::GetFullPath($ReleasesDir)
$persistentUploads = if ($UploadDir) { [IO.Path]::GetFullPath($UploadDir) } else { Join-Path $project "data\uploads" }
$launcher = Join-Path $project "scripts\run-production.ps1"
$poller = Join-Path $project "scripts\poll-production-deploy.ps1"
if (-not (Test-Path -LiteralPath $launcher)) { throw "Missing launcher: $launcher" }
if (-not (Test-Path -LiteralPath $poller)) { throw "Missing deployment poller: $poller" }
if (-not (Test-Path -LiteralPath (Join-Path $project ".env"))) { throw "Missing production .env" }
if ($persistentData.StartsWith($project.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "DataDir must be outside the production Git checkout"
}
if (-not (Test-Path -LiteralPath (Join-Path $persistentData "jobpilot.db"))) {
  throw "DataDir does not contain the existing production jobpilot.db"
}
if ($releaseRoot -eq $project -or $releaseRoot.StartsWith($project.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $project.StartsWith($releaseRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "ReleasesDir must not overlap the production Git checkout"
}
if ($releaseRoot -eq $persistentData -or $releaseRoot.StartsWith($persistentData.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $persistentData.StartsWith($releaseRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "ReleasesDir must not overlap DataDir"
}
if ($releaseRoot -eq $persistentUploads -or $releaseRoot.StartsWith($persistentUploads.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or $persistentUploads.StartsWith($releaseRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
  throw "ReleasesDir must not overlap UploadDir"
}
New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null
New-Item -ItemType Directory -Path $persistentUploads -Force | Out-Null

$quotedProject = '"' + $project + '"'
$quotedData = '"' + $persistentData + '"'
$quotedUploads = '"' + $persistentUploads + '"'
$quotedReleases = '"' + $releaseRoot + '"'
$quotedLauncher = '"' + $launcher + '"'
$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File $quotedLauncher -ProjectRoot $quotedProject -DataDir $quotedData -UploadDir $quotedUploads -ReleasesDir $quotedReleases" `
  -WorkingDirectory $project
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -RestartCount 3 `
  -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Principal $principal `
  -Description "JobPilot production Node service" `
  -Force | Out-Null

$quotedPoller = '"' + $poller + '"'
$deployAction = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File $quotedPoller -ProjectRoot $quotedProject -DataDir $quotedData -UploadDir $quotedUploads -ReleasesDir $quotedReleases -TaskName $TaskName" `
  -WorkingDirectory $project
$deployTrigger = New-ScheduledTaskTrigger `
  -Once `
  -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes $PollMinutes)
$deploySettings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -MultipleInstances IgnoreNew

Register-ScheduledTask `
  -TaskName $DeployTaskName `
  -Action $deployAction `
  -Trigger $deployTrigger `
  -Settings $deploySettings `
  -Principal $principal `
  -Description "Deploy the latest CI-validated JobPilot master commit" `
  -Force | Out-Null

Remove-Item -LiteralPath (Join-Path $project ".jobpilot-deploy-enabled") -Force -ErrorAction SilentlyContinue
if (-not $EnableDeployment) {
  Write-Warning "Deployment poller installed but disabled. Create .jobpilot-deploy-enabled after protecting master."
}

Start-ScheduledTask -TaskName $TaskName
$deadline = (Get-Date).AddSeconds(60)
do {
  try {
    $response = Invoke-WebRequest -Uri $LocalReadyUrl -Method Get -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 5
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
      if ($EnableDeployment) {
        New-Item -ItemType File -Path (Join-Path $project ".jobpilot-deploy-enabled") -Force | Out-Null
      }
      Start-ScheduledTask -TaskName $DeployTaskName
      Write-Host "Scheduled tasks $TaskName and $DeployTaskName installed; JobPilot is serving $LocalReadyUrl"
      exit 0
    }
  } catch {
    # The application may still be starting.
  }
  Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
throw "JobPilot did not become ready; scheduled task result: $($taskInfo.LastTaskResult)"
