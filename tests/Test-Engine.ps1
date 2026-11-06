param([string]$PythonExe = 'python', [switch]$FrozenHelper)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$text = [IO.File]::ReadAllText((Join-Path $root 'assets\migrate.ps1'))
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
if($errors){throw($errors|Out-String)}
foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {Invoke-Expression $node.Extent.Text}
$fixture=Join-Path $PSScriptRoot ('engine-fixture-'+[Guid]::NewGuid().ToString('N'))
$profileRoot=Join-Path $fixture 'profile-测试'
$destinationRoot=Join-Path $fixture 'destination'
$workRoot=Join-Path $destinationRoot '.migration'
$statusPath=Join-Path $workRoot 'status.json';$logPath=Join-Path $workRoot 'migration.log'
$HelperExecutable=(Get-Command $PythonExe).Source
$HelperScript=if($FrozenHelper){''}else{Join-Path $root 'app.py'}
$cacheAliases=@{};$CleanBackups=$false;$CleanupOnly=$false
$plans=@(@{Name='data';Source=(Join-Path $profileRoot 'data');Destination=(Join-Path $destinationRoot 'data')})
New-Item -ItemType Directory -Path $plans[0].Source,$workRoot -Force|Out-Null
function Busy-Processes {return @()}
Set-Content -LiteralPath (Join-Path $plans[0].Source 'state.sqlite') -Value 'old database'
Set-Content -LiteralPath (Join-Path $plans[0].Source 'state.sqlite-wal') -Value 'stale WAL'
New-Item -ItemType Directory -Path (Join-Path $plans[0].Source 'empty')|Out-Null
$padding='p' * (230 - $plans[0].Source.Length - 10)
$longDirectory=Join-Path $plans[0].Source $padding
New-Item -ItemType Directory -Path $longDirectory|Out-Null
Set-Content -LiteralPath (Join-Path $longDirectory 'unicode-测试.js') -Value 'long path content'
Copy-Tree $plans[0]|Out-Null
Remove-Item -LiteralPath (Join-Path $plans[0].Source 'state.sqlite-wal')
Set-Content -LiteralPath (Join-Path $plans[0].Source 'state.sqlite') -Value 'new database'
Set-Content -LiteralPath (Join-Path $plans[0].Source 'state.sqlite-shm') -Value 'transient'
$result=Switch-Tree $plans[0]
if($result.state -ne 'linked_backup_retained'){throw 'Backup was not retained by default.'}
if(-not(Is-Linked $plans[0])){throw 'Source junction is missing.'}
if(Test-Path -LiteralPath (Join-Path $plans[0].Destination 'state.sqlite-wal')){throw 'Stale WAL was retained.'}
if(Test-Path -LiteralPath (Join-Path $plans[0].Destination 'state.sqlite-shm')){throw 'SHM index was retained.'}
if((Get-Content -LiteralPath (Join-Path $plans[0].Source 'state.sqlite') -Raw).Trim() -ne 'new database'){throw 'Final sync lost changed content.'}
if(-not(Test-Path -LiteralPath $result.backup)){throw 'Backup is missing.'}
$CleanupOnly=$true
$result=Switch-Tree $plans[0]
if($result.state -ne 'already_linked'){throw 'Cleanup/rerun did not finish correctly.'}
$record=Join-Path $workRoot 'transaction-data.json'
$json=[IO.File]::ReadAllText($record)
[IO.File]::WriteAllText($record,$json,(New-Object Text.UTF8Encoding($false)))
if((Switch-Tree $plans[0]).state -ne 'already_linked'){throw 'UTF-8 without BOM was not read correctly.'}
$rejected=$false
try{Assert-Entry @{Name='bad';Source=$profileRoot;Destination=$destinationRoot}}catch{$rejected=$true}
if(-not $rejected){throw 'Unapproved roots were accepted.'}
@{passed=$true;checks=@('changed file synchronization','stale WAL removal','transient SHM exclusion','default backup retention','junction switch','long backup path verification','guarded backup cleanup','UTF-8 BOM and no-BOM records','idempotent resume','unapproved-root rejection');fixture=$fixture}|ConvertTo-Json -Depth 4
