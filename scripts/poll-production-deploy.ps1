[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectRoot,
  [Parameter(Mandatory = $true)]
  [string]$DataDir,
  [Parameter(Mandatory = $true)]
  [string]$UploadDir,
  [Parameter(Mandatory = $true)]
  [string]$ReleasesDir,
  [string]$TaskName = "JobPilot",
  [string]$LocalHealthUrl = "http://127.0.0.1:3000/api/health",
  [string]$PublicHealthUrl = "https://job.vcrelay.com/api/health"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$project = [IO.Path]::GetFullPath($ProjectRoot)
$enabledMarker = Join-Path $project ".jobpilot-deploy-enabled"
$blockedMarker = Join-Path $project ".jobpilot-blocked-sha"
if (-not (Test-Path -LiteralPath $enabledMarker)) {
  Write-Host "Automatic deployment is disabled; no release attempted."
  exit 0
}

& git -C $project fetch --prune origin master
if ($LASTEXITCODE -ne 0) { throw "Unable to fetch origin/master" }
$targetSha = (& git -C $project rev-parse "origin/master").Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw "Unable to read the current master commit" }

$headers = @{
  "Accept" = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
  "User-Agent" = "JobPilot-production-poller"
}
$workflowUrl = "https://api.github.com/repos/VELIR5/jobpilot/actions/workflows/ci.yml/runs?branch=master&event=push&status=success&per_page=20"
$workflowRuns = Invoke-RestMethod -Uri $workflowUrl -Method Get -Headers $headers -TimeoutSec 20
$validated = @($workflowRuns.workflow_runs) | Where-Object {
  $_.head_sha -eq $targetSha -and
  $_.head_branch -eq "master" -and
  $_.event -eq "push" -and
  $_.status -eq "completed" -and
  $_.conclusion -eq "success"
} | Select-Object -First 1

if (-not $validated) {
  Write-Host "The current master tip $targetSha has not passed push CI; waiting."
  exit 0
}

if (Test-Path -LiteralPath $blockedMarker) {
  $blockedSha = (Get-Content -LiteralPath $blockedMarker -TotalCount 1).Trim().ToLowerInvariant()
  if ($blockedSha -eq $targetSha) {
    Write-Warning "Automatic deployment of $targetSha is blocked after a failed release; waiting for a newer commit or manual review."
    exit 0
  }
}

$env:JOBPILOT_PRODUCTION_DIR = $project
$env:JOBPILOT_DEPLOY_DATA_DIR = [IO.Path]::GetFullPath($DataDir)
$env:JOBPILOT_UPLOAD_DIR = [IO.Path]::GetFullPath($UploadDir)
$env:JOBPILOT_RELEASES_DIR = [IO.Path]::GetFullPath($ReleasesDir)
$env:JOBPILOT_TASK_NAME = $TaskName
$env:JOBPILOT_LOCAL_HEALTH_URL = $LocalHealthUrl
$env:JOBPILOT_PUBLIC_HEALTH_URL = $PublicHealthUrl

$deployScript = Join-Path $project "scripts\deploy-production.ps1"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deployScript -TargetSha $targetSha
if ($LASTEXITCODE -ne 0) { throw "Production deployment failed with exit code $LASTEXITCODE" }
