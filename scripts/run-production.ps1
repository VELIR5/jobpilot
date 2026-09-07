[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectRoot,
  [Parameter(Mandatory = $true)]
  [string]$DataDir
)

$ErrorActionPreference = "Stop"
$project = [IO.Path]::GetFullPath($ProjectRoot)
$persistentData = [IO.Path]::GetFullPath($DataDir)
Set-Location $project

if (-not (Test-Path -LiteralPath (Join-Path $project ".env"))) {
  throw "Missing production .env in $project"
}
if (-not (Test-Path -LiteralPath (Join-Path $persistentData "jobpilot.db"))) {
  throw "Production database not found in $persistentData"
}

$releaseEnvironment = Join-Path $project ".jobpilot-release.env"
if (Test-Path -LiteralPath $releaseEnvironment) {
  foreach ($line in Get-Content -LiteralPath $releaseEnvironment) {
    if ($line -match '^([A-Z0-9_]+)="(.*)"$') {
      [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
    }
  }
}

$env:JOBPILOT_DATA_DIR = $persistentData
$env:NODE_ENV = "production"
& npm.cmd run start
exit $LASTEXITCODE
