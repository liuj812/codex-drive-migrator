param([string]$PythonExe = 'python')
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    & $PythonExe -m PyInstaller --noconfirm --clean --onefile --windowed --noupx --name CodexDriveMigrator --add-data 'assets:assets' --hidden-import self_test app.py
    if($LASTEXITCODE -ne 0){throw 'EXE build failed'}
    $exe=Join-Path $PSScriptRoot 'dist\CodexDriveMigrator.exe'
    $hash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'dist\SHA256SUMS.txt'),($hash+'  CodexDriveMigrator.exe'+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
} finally {Pop-Location}
