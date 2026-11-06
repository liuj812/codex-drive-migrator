param([string]$DestinationRoot, [string]$HelperExecutable, [string]$HelperScript='')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
& "$PSScriptRoot\migrate.ps1" -DestinationRoot $DestinationRoot -HelperExecutable $HelperExecutable -HelperScript $HelperScript -ValidateOnly
