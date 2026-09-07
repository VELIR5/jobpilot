[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectRoot,
  [Parameter(Mandatory = $true)]
  [string]$DataDir,
  [Parameter(Mandatory = $true)]
  [string]$UploadDir,
  [Parameter(Mandatory = $true)]
  [string]$ReleasesDir
)

$ErrorActionPreference = "Stop"
$project = [IO.Path]::GetFullPath($ProjectRoot)
$persistentData = [IO.Path]::GetFullPath($DataDir)
$persistentUploads = [IO.Path]::GetFullPath($UploadDir)
$releaseRoot = [IO.Path]::GetFullPath($ReleasesDir)
$pointerPath = Join-Path $project ".jobpilot-current-release"
$runtimeRoot = if (Test-Path -LiteralPath $pointerPath) {
  [IO.Path]::GetFullPath((Get-Content -LiteralPath $pointerPath -TotalCount 1).Trim())
} else {
  $project
}
$releasePrefix = $releaseRoot.TrimEnd('\') + '\'
if ($runtimeRoot -ne $project -and -not $runtimeRoot.StartsWith($releasePrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Current release pointer is outside the approved runtime directories"
}
Set-Location $runtimeRoot

if (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot ".env"))) {
  throw "Missing production .env in $runtimeRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot ".next-build"))) {
  throw "Missing production build in $runtimeRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $runtimeRoot "node_modules"))) {
  throw "Missing production dependencies in $runtimeRoot"
}
if (-not (Test-Path -LiteralPath (Join-Path $persistentData "jobpilot.db"))) {
  throw "Production database not found in $persistentData"
}

$releaseEnvironment = Join-Path $runtimeRoot ".jobpilot-release.env"
if (Test-Path -LiteralPath $releaseEnvironment) {
  foreach ($line in Get-Content -LiteralPath $releaseEnvironment) {
    if ($line -match '^([A-Z0-9_]+)="(.*)"$') {
      [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
    }
  }
}

$env:JOBPILOT_DATA_DIR = $persistentData
$env:JOBPILOT_UPLOAD_DIR = $persistentUploads
$env:NODE_ENV = "production"
& npm.cmd run start
exit $LASTEXITCODE
