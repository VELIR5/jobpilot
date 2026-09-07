[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectRoot,
  [Parameter(Mandatory = $true)]
  [string]$DataDir,
  [string]$TaskName = "JobPilot",
  [string]$DeployTaskName = "JobPilotDeploy",
  [ValidateRange(2, 30)]
  [int]$PollMinutes = 3,
  [switch]$EnableDeployment
)

$ErrorActionPreference = "Stop"
$project = [IO.Path]::GetFullPath($ProjectRoot)
$persistentData = [IO.Path]::GetFullPath($DataDir)
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

$quotedProject = '"' + $project + '"'
$quotedData = '"' + $persistentData + '"'
$quotedLauncher = '"' + $launcher + '"'
$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File $quotedLauncher -ProjectRoot $quotedProject -DataDir $quotedData" `
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
  -Argument "-NoProfile -ExecutionPolicy Bypass -File $quotedPoller -ProjectRoot $quotedProject -DataDir $quotedData -TaskName $TaskName" `
  -WorkingDirectory $project
$deployTrigger = New-ScheduledTaskTrigger `
  -Once `
  -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes $PollMinutes)
$deploySettings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
  -MultipleInstances IgnoreNew

Register-ScheduledTask `
  -TaskName $DeployTaskName `
  -Action $deployAction `
  -Trigger $deployTrigger `
  -Settings $deploySettings `
  -Principal $principal `
  -Description "Deploy the latest CI-validated JobPilot master commit" `
  -Force | Out-Null

if ($EnableDeployment) {
  New-Item -ItemType File -Path (Join-Path $project ".jobpilot-deploy-enabled") -Force | Out-Null
} else {
  Write-Warning "Deployment poller installed but disabled. Create .jobpilot-deploy-enabled after protecting master."
}

Start-ScheduledTask -TaskName $TaskName
Start-ScheduledTask -TaskName $DeployTaskName
Write-Host "Scheduled tasks $TaskName and $DeployTaskName installed for $project"
