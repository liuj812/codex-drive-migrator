[CmdletBinding()]
param(
    [string]$DestinationRoot = 'D:\Codex',
    [string]$HelperExecutable,
    [string]$HelperScript = '',
    [switch]$ValidateOnly,
    [switch]$CleanBackups,
    [switch]$CleanupOnly,
    [switch]$MoveApplication,
    [int]$WaitHours = 2
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$profileRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
$destinationRoot = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
if (-not [IO.Path]::IsPathRooted($DestinationRoot) -or $destinationRoot -notmatch '^[D-Zd-z]:\\[^\\]') { throw 'Choose a local directory on a drive other than C (for example D:\Codex).' }
if (-not (Test-Path -LiteralPath ([IO.Path]::GetPathRoot($destinationRoot)))) { throw 'Destination drive is not available.' }
if ((New-Object IO.DriveInfo([IO.Path]::GetPathRoot($destinationRoot))).DriveFormat -ne 'NTFS') { throw 'The destination must use NTFS to preserve access permissions.' }
$destinationDrive = [IO.Path]::GetPathRoot($destinationRoot).TrimEnd('\')
$workRoot = Join-Path $destinationRoot '.migration'
$statusPath = Join-Path $workRoot 'status.json'
$logPath = Join-Path $workRoot 'migration.log'
$plans = @(
    @{Name='data'; Source="$profileRoot\.codex"; Destination="$destinationRoot\data"},
    @{Name='agents'; Source="$profileRoot\.agents"; Destination="$destinationRoot\agents"},
    @{Name='runtimes'; Source="$profileRoot\.cache\codex-runtimes"; Destination="$destinationRoot\runtimes"},
    @{Name='engine'; Source="$profileRoot\AppData\Local\OpenAI\Codex"; Destination="$destinationRoot\engine"},
    @{Name='local'; Source="$profileRoot\AppData\Local\Codex"; Destination="$destinationRoot\local"},
    @{Name='roaming'; Source="$profileRoot\AppData\Roaming\Codex"; Destination="$destinationRoot\roaming"}
)
$packageCache = "$profileRoot\AppData\Local\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache"
$cacheAliases = @{
    local = @{virtual="$profileRoot\AppData\Local\Codex"; physical="$packageCache\Local\Codex"}
    roaming = @{virtual="$profileRoot\AppData\Roaming\Codex"; physical="$packageCache\Roaming\Codex"}
}
$windowsManagedOnD = @()
$packageCacheItem = Get-Item -LiteralPath $packageCache -Force -ErrorAction SilentlyContinue
if ($packageCacheItem -and ($packageCacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
    [string]@($packageCacheItem.Target)[0] -like ($destinationDrive + '\*')) {
    $windowsManagedOnD += @{name='Windows-managed Codex cache'; location=[string]@($packageCacheItem.Target)[0]}
    $plans = @($plans | Where-Object { $_.Name -notin @('local','roaming') })
}
foreach ($entry in $plans) {
    if ($cacheAliases.ContainsKey($entry.Name) -and (Test-Path -LiteralPath $cacheAliases[$entry.Name].physical)) {
        $entry.Source = $cacheAliases[$entry.Name].physical
    }
}
function Full-Path([string]$Path) { return [IO.Path]::GetFullPath($Path).TrimEnd('\') }
function Long-Path([string]$Path) {
    # The .codex-migration-<guid> backup suffix can push nested paths past
    # MAX_PATH (260), which breaks Get-ChildItem / Get-Item / Get-FileHash.
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.Length -ge 240) { return '\\?\' + $Path }
    return $Path
}
function Assert-Entry($Entry) {
    $source = Full-Path $Entry.Source
    $target = Full-Path $Entry.Destination
    if (-not $source.StartsWith($profileRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe source: $source" }
    if (-not $target.StartsWith($destinationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe target: $target" }
    if ($source -ne $Entry.Source -or $target -ne $Entry.Destination) { throw 'Noncanonical migration path.' }
    if (@($plans | Where-Object { $_.Source -eq $source -and $_.Destination -eq $target }).Count -ne 1) { throw 'Unlisted migration entry.' }
    for ($parent = $target; $parent; $parent = [IO.Path]::GetDirectoryName($parent)) {
        $item = Get-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Target has a redirected ancestor: $parent" }
    }
}
function Log([string]$Message) {
    Add-Content -LiteralPath $logPath -Value ('{0:o} {1}' -f (Get-Date), $Message) -Encoding UTF8
}
function Status([string]$Stage, $Details) {
    $value = @{stage=$Stage; time=(Get-Date).ToString('o'); pid=$PID; details=$Details; destination=$destinationRoot}
    $json = $value | ConvertTo-Json -Depth 8
    $temporary = "$statusPath.$PID.tmp"
    [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $statusPath -Force
    Log ($Stage + ' ' + ($Details | ConvertTo-Json -Depth 6 -Compress))
}
function Is-Linked($Entry) {
    $item = Get-Item -LiteralPath $Entry.Source -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    if ((Full-Path ([string]@($item.Target)[0])) -ne (Full-Path $Entry.Destination)) { throw "Unexpected existing link: $($Entry.Source)" }
    return $true
}
function Busy-Processes {
    # Paths can be unavailable for sandboxed child processes. Unknown ChatGPT
    # processes are treated as busy rather than risking an active database.
    $busy = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $name = [IO.Path]::GetFileNameWithoutExtension($_.Name)
        $path = $_.ExecutablePath
        ($name -eq 'ChatGPT' -and (-not $path -or $path -like '*\WindowsApps\OpenAI.Codex_*\*')) -or
        ($name -in @('codex', 'codex-code-mode-host')) -or
        ($path -and ($path.StartsWith("$profileRoot\AppData\Local\OpenAI\Codex\", [StringComparison]::OrdinalIgnoreCase) -or
                        $path.StartsWith("$destinationRoot\engine\", [StringComparison]::OrdinalIgnoreCase)))
    } | ForEach-Object { [pscustomobject]@{Id=$_.ProcessId; ProcessName=[IO.Path]::GetFileNameWithoutExtension($_.Name); Path=$_.ExecutablePath} })
    return $busy
}
function Assert-Idle {
    if (@(Busy-Processes).Count -gt 0) { throw 'Codex is running or was reopened. Quit it completely, then run the migration again.' }
}
function Ensure-Target($Entry) {
    Assert-Entry $Entry
    $marker = Join-Path $workRoot ('owned-' + $Entry.Name + '.json')
    if (Test-Path -LiteralPath $marker) {
        $owner = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cacheAliases.ContainsKey($Entry.Name) -and $owner.source -eq $cacheAliases[$Entry.Name].virtual -and
            $Entry.Source -eq $cacheAliases[$Entry.Name].physical -and $owner.destination -eq $Entry.Destination) {
            $owner.source = $Entry.Source
            $owner | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
            Log ('Resolved physical MSIX cache path for ' + $Entry.Name)
        }
        if ($owner.source -ne $Entry.Source -or $owner.destination -ne $Entry.Destination) { throw 'Ownership marker does not match.' }
    } else {
        if (Test-Path -LiteralPath $Entry.Destination) { throw "Existing destination is not managed by this migration: $($Entry.Destination)" }
        @{source=$Entry.Source; destination=$Entry.Destination} | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
    }
    if (-not (Test-Path -LiteralPath $Entry.Destination)) {
        New-Item -ItemType Directory -Path $Entry.Destination -Force | Out-Null
    }
    $sourceAcl = Get-Acl -LiteralPath $Entry.Source
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $accessSection = [Security.AccessControl.AccessControlSections]::Access
    $acl.SetSecurityDescriptorSddlForm($sourceAcl.GetSecurityDescriptorSddlForm($accessSection), $accessSection)
    $acl.SetAccessRuleProtection($true, $true)
    $directoryInfo = New-Object IO.DirectoryInfo($Entry.Destination)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [IO.FileSystemAclExtensions]::SetAccessControl($directoryInfo, $acl)
    } else {
        $directoryInfo.SetAccessControl($acl)
    }
}
function Prepare-Access($Entry) {
    # Copy only DACLs through .NET. Set-Acl/robocopy /COPY:S may request
    # audit privileges that a standard Windows user does not have.
    $sourceRoot = Full-Path $Entry.Source
    $stack = New-Object 'Collections.Generic.Stack[string]'
    $stack.Push($sourceRoot)
    $accessSection = [Security.AccessControl.AccessControlSections]::Access
    $prepared = 0; $lastProgress = Get-Date
    while ($stack.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction Stop) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.Name -like '*.sqlite-shm') { continue }
            $relative = $item.FullName.Substring($sourceRoot.Length).TrimStart('\')
            $copyPath = Join-Path $Entry.Destination $relative
            if (-not (Test-Path -LiteralPath $copyPath)) {
                if ($item.PSIsContainer) { New-Item -ItemType Directory -Path $copyPath -Force | Out-Null }
                else { [IO.File]::WriteAllBytes($copyPath, [byte[]]@()) }
            }
            $existing = Get-Item -LiteralPath $copyPath -Force
            if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unexpected existing link: $relative" }
            $sourceAcl = Get-Acl -LiteralPath $item.FullName
            if ($item.PSIsContainer) {
                $acl = New-Object Security.AccessControl.DirectorySecurity
                $copyInfo = New-Object IO.DirectoryInfo($copyPath)
                $stack.Push($item.FullName)
            } else {
                $acl = New-Object Security.AccessControl.FileSecurity
                $copyInfo = New-Object IO.FileInfo($copyPath)
            }
            $acl.SetSecurityDescriptorSddlForm($sourceAcl.GetSecurityDescriptorSddlForm($accessSection), $accessSection)
            if ($PSVersionTable.PSEdition -eq 'Core') { [IO.FileSystemAclExtensions]::SetAccessControl($copyInfo, $acl) }
            else { $copyInfo.SetAccessControl($acl) }
            $prepared++
            if (((Get-Date) - $lastProgress).TotalSeconds -ge 15) {
                Status 'preparing_permissions' @{name=$Entry.Name; files=$prepared; message='Preparing destination permissions.'}
                $lastProgress = Get-Date
            }
        }
    }
}
function Copy-Tree($Entry, [switch]$FinalSync) {
    Assert-Entry $Entry
    if (Is-Linked $Entry) { return 0 }
    if (-not (Test-Path -LiteralPath $Entry.Source)) { return 0 }
    Ensure-Target $Entry
    Prepare-Access $Entry
    $copyLog = Join-Path $workRoot ('copy-' + $Entry.Name + '.log')
    $options = @('/E', '/COPY:DAT', '/DCOPY:DAT', '/SJ', '/SL', '/R:1', '/W:1', '/MT:8', '/NFL', '/NDL', '/NP', '/NJH', '/NJS', '/XF', '*.sqlite-shm', "/LOG+:$copyLog")
    if ($FinalSync) {
        Assert-Idle
        # The destination was created by this migration and its absolute path
        # was checked above. Remove stale precopied WAL/SHM files and caches.
        $options += @('/PURGE', '/IS', '/IT')
    }
    & "$env:SystemRoot\System32\robocopy.exe" $Entry.Source $Entry.Destination @options | Out-Null
    $code = $LASTEXITCODE
    # SQLite -shm is a memory-mapped WAL index. Its bytes change without
    # updating the timestamp, so robocopy keeps a stale copy and the hash
    # check fails. SQLite rebuilds it from the -wal on next open, so drop
    # every copy left over from earlier runs.
    Get-ChildItem -LiteralPath $Entry.Destination -Recurse -Filter '*.sqlite-shm' -Force -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    Log ('Copy ' + $Entry.Name + ' exit=' + $code)
    if ($FinalSync -and $code -ge 8) { throw "Copy failed for $($Entry.Name); see $copyLog" }
    Ensure-Target $Entry
    return $code
}
function Invoke-TreeIO([string]$Operation, [string[]]$Paths, [string]$Name) {
    if (-not $HelperExecutable -or -not (Test-Path -LiteralPath $HelperExecutable)) { throw 'Bundled verification helper is unavailable.' }
    $requestPath = Join-Path $workRoot ('io-' + [Guid]::NewGuid().ToString('N') + '.json')
    $responsePath = $requestPath + '.result'
    @{operation=$Operation; paths=$Paths; profile=$profileRoot; destination=$destinationRoot; records=$workRoot; result=$responsePath} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    $arguments = '--tree-io "' + $requestPath + '"'
    if ($HelperScript) { $arguments = '"' + $HelperScript + '" ' + $arguments }
    try {
        $process = Start-Process -FilePath $HelperExecutable -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $last = ''
        while (-not $process.HasExited) {
            if (Test-Path -LiteralPath $responsePath) {
                $record = Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($record.event -eq 'progress' -and [string]$record.files -ne $last) {
                    Status 'verifying' @{name=$Name; files=$record.files; bytes=$record.bytes}
                    $last = [string]$record.files
                }
            }
            Start-Sleep -Milliseconds 250
            $process.Refresh()
        }
        if (-not (Test-Path -LiteralPath $responsePath)) { throw 'Verification helper exited without a result.' }
        $answer = Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($process.ExitCode -ne 0 -or $answer.event -ne 'result') { throw ('Verification failed: ' + $answer.message) }
        return @{files=$answer.files; bytes=$answer.bytes; links=$answer.links}
    } finally {
        Remove-Item -LiteralPath $requestPath,$responsePath -Force -ErrorAction SilentlyContinue
    }
}
function Verify-Tree([string]$Source, [string]$Target, [string]$Name) {
    $result = Invoke-TreeIO 'verify' @($Source,$Target) $Name
    Log ('Verified ' + $Name + ' files=' + $result.files + ' bytes=' + $result.bytes + ' links=' + $result.links)
    return $result
}
function Remove-VerifiedBackup([string]$Backup, $Entry) {
    Invoke-TreeIO 'remove-backup' @($Backup,$Entry.Source,$Entry.Destination) $Entry.Name | Out-Null
}
function Switch-Tree($Entry) {
    Assert-Entry $Entry
    $record = Join-Path $workRoot ('transaction-' + $Entry.Name + '.json')
    if (Test-Path -LiteralPath $record) {
        $prior = Get-Content -LiteralPath $record -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($prior.source -ne $Entry.Source -or $prior.destination -ne $Entry.Destination) { throw 'Transaction path mismatch.' }
        if ($prior.backup -and (Test-Path -LiteralPath $prior.backup)) {
            $priorBackup = Full-Path $prior.backup
            if (-not $priorBackup.StartsWith($Entry.Source + '.codex-migration-', [StringComparison]::OrdinalIgnoreCase) -or
                $priorBackup.Substring($Entry.Source.Length) -notmatch '^\.codex-migration-[a-f0-9]{32}$') { throw 'Unsafe recovery path.' }
            Assert-Idle
            $priorItem = Get-Item -LiteralPath $priorBackup -Force
            if ($priorItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Recovery backup must be a real directory.' }
            if (-not (Test-Path -LiteralPath $Entry.Source)) {
                Rename-Item -LiteralPath $priorBackup -NewName ([IO.Path]::GetFileName($Entry.Source))
                Log ('Recovered original source: ' + $Entry.Source)
            } elseif (Is-Linked $Entry) {
                if (-not $CleanBackups -and -not $CleanupOnly) { return @{name=$Entry.Name; state='linked_backup_retained'; backup=$priorBackup} }
                $check = Verify-Tree $priorBackup $Entry.Destination $Entry.Name
                if ($check.links -gt 0) { return @{name=$Entry.Name; state='linked_backup_retained'; backup=$priorBackup; verified=$check} }
                Assert-Idle
                Remove-VerifiedBackup $priorBackup $Entry
                @{source=$Entry.Source; destination=$Entry.Destination; phase='complete'; verified=$check} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $record -Encoding UTF8
            } else { throw 'Both source and recovery backup exist. Keep both and inspect the transaction record.' }
        }
    }
    if (Is-Linked $Entry) { return @{name=$Entry.Name; state='already_linked'} }
    if (-not (Test-Path -LiteralPath $Entry.Source)) { return @{name=$Entry.Name; state='not_present'} }
    if ($CleanupOnly) { return @{name=$Entry.Name; state='not_migrated'} }
    Assert-Idle
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Status 'final_copy' @{name=$Entry.Name; attempt=$attempt; message='Keep Codex closed.'}
            Copy-Tree $Entry -FinalSync | Out-Null
            Status 'verifying' @{name=$Entry.Name; attempt=$attempt; message='SHA256 verification; keep Codex closed.'}
            $verified = Verify-Tree $Entry.Source $Entry.Destination $Entry.Name
            break
        } catch {
            if ($attempt -eq 3) { throw }
            Assert-Idle
            Status 'waiting_for_files_to_settle' @{name=$Entry.Name; attempt=$attempt; reason=$_.Exception.Message}
            Start-Sleep -Seconds 15
        }
    }
    Assert-Idle
    $suffix = '.codex-migration-' + [Guid]::NewGuid().ToString('N')
    $backup = (Full-Path $Entry.Source) + $suffix
    if ($backup -ne ($Entry.Source + $suffix) -or -not $backup.StartsWith($profileRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe backup path.' }
    @{source=$Entry.Source; destination=$Entry.Destination; backup=$backup; phase='before_rename'} | ConvertTo-Json | Set-Content -LiteralPath $record -Encoding UTF8
    Rename-Item -LiteralPath $Entry.Source -NewName ([IO.Path]::GetFileName($backup))
    try {
        New-Item -ItemType Junction -Path $Entry.Source -Target $Entry.Destination | Out-Null
        if (-not (Is-Linked $Entry)) { throw 'Junction validation failed.' }
    } catch {
        if (-not (Test-Path -LiteralPath $Entry.Source)) { Rename-Item -LiteralPath $backup -NewName ([IO.Path]::GetFileName($Entry.Source)) }
        throw
    }
    @{source=$Entry.Source; destination=$Entry.Destination; backup=$backup; phase='linked_backup_retained'} | ConvertTo-Json | Set-Content -LiteralPath $record -Encoding UTF8
    if (-not $CleanBackups) { return @{name=$Entry.Name; state='linked_backup_retained'; backup=$backup; verified=$verified} }
    # A second verification protects the only C-drive copy before removing it.
    Verify-Tree $backup $Entry.Destination $Entry.Name | Out-Null
    Assert-Idle
    $backupItem = Get-Item -LiteralPath $backup -Force
    if ((Full-Path $backupItem.FullName) -ne $backup -or ($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe backup deletion target.' }
    if ($verified.links -gt 0) {
        Log ("Backup kept because it contains links: $backup")
        return @{name=$Entry.Name; state='linked_backup_retained'; backup=$backup; verified=$verified}
    }
    Status 'removing_verified_c_copy' @{name=$Entry.Name; bytes=$verified.bytes}
    try { Remove-VerifiedBackup $backup $Entry }
    catch {
        Log ('Verified data is on D; backup cleanup pending: ' + $backup + ' ' + $_.Exception.Message)
        return @{name=$Entry.Name; state='linked_backup_retained'; backup=$backup; verified=$verified; reason=$_.Exception.Message}
    }
    @{source=$Entry.Source; destination=$Entry.Destination; phase='complete'; verified=$verified} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $record -Encoding UTF8
    return @{name=$Entry.Name; state='complete'; verified=$verified}
}
function Move-Application {
    try {
        Assert-Idle
        Import-Module Appx -ErrorAction Stop
        $packages = @(Get-AppxPackage -Name 'OpenAI.Codex*' -ErrorAction Stop | Where-Object { $_.Name -eq 'OpenAI.Codex' -or $_.IsFramework })
        if (-not @($packages | Where-Object { $_.Name -eq 'OpenAI.Codex' }).Count) { throw 'Application package was not found for this user.' }
        $volume = Get-AppxVolume | Where-Object { $_.PackageStorePath -like ($destinationDrive + '\*') } | Select-Object -First 1
        $results = @()
        foreach ($package in $packages) {
            if ($package.IsFramework) { $results += @{name=$package.Name; state='system_managed'; location=$package.InstallLocation}; continue }
            try {
                $location = $package.InstallLocation
                $item = Get-Item -LiteralPath $location -Force
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and [string]@($item.Target)[0] -like ($destinationDrive + '\*')) {
                    $location = [string]@($item.Target)[0]
                }
                if ($location -like 'C:\*') {
                    if (-not $volume) { throw 'Selected drive is not registered as a Windows app volume. Use Windows Settings to move the app.' }
                    Move-AppxPackage -Package $package.PackageFullName -Volume $volume -Confirm:$false -ErrorAction Stop
                    $moved = Get-AppxPackage -Name $package.Name -ErrorAction Stop
                    $location = $moved.InstallLocation
                    $item = Get-Item -LiteralPath $location -Force
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and [string]@($item.Target)[0] -like ($destinationDrive + '\*')) {
                        $location = [string]@($item.Target)[0]
                    }
                }
                if ($location -notlike ($destinationDrive + '\*')) { throw "Package is still at $location" }
                $results += @{name=$package.Name; state='complete'; location=$location}
            } catch {
                Log ('Windows package move pending: ' + $package.Name + ' ' + $_.Exception.Message)
                $results += @{name=$package.Name; state='pending'; message=$_.Exception.Message}
            }
        }
        $state = if (@($results | Where-Object { $_.state -notin @('complete','system_managed') }).Count) { 'pending' } else { 'complete' }
        return @{state=$state; packages=$results}
    } catch {
        Log ('Windows application move pending: ' + $_.Exception.Message)
        return @{state='pending'; message=$_.Exception.Message; action='Windows Settings > Apps > Installed apps > Codex > Move'}
    }
}

foreach ($entry in $plans) { Assert-Entry $entry }
if ($ValidateOnly) {
    @{plans=$plans; busyProcesses=@(Busy-Processes | Select-Object Id,ProcessName); sourceIntact=$true} | ConvertTo-Json -Depth 6
    exit 0
}

New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$mutex = New-Object Threading.Mutex($false, 'Local\CodexDriveMigrator')
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { Write-Output 'A migration process is already running.'; exit 3 }
    $deadline = (Get-Date).AddHours($WaitHours)
    Remove-Item -LiteralPath (Join-Path $workRoot 'cancel.request') -Force -ErrorAction SilentlyContinue
    while ($true) {
        if (Test-Path -LiteralPath (Join-Path $workRoot 'cancel.request')) { Status 'cancelled' 'Cancelled before migration started.'; exit 0 }
        $busy = @(Busy-Processes)
        Status 'waiting_for_codex_exit' @{processes=@($busy | Select-Object Id,ProcessName); message='Quit Codex completely. The migration does not close it for you.'}
        if ($busy.Count -eq 0) {
            Start-Sleep -Seconds 15
            if (@(Busy-Processes).Count -eq 0) { break }
        }
        if ((Get-Date) -gt $deadline) { Status 'waiting_timeout' 'Run start-migration.cmd again after completely quitting Codex.'; exit 2 }
        Start-Sleep -Seconds 5
    }
    if (Test-Path -LiteralPath (Join-Path $workRoot 'cancel.request')) { Status 'cancelled' 'Cancelled before migration started.'; exit 0 }
    $results = @()
    foreach ($entry in $plans) { $results += Switch-Tree $entry }
    Assert-Idle
    $dataEntry = $plans | Where-Object { $_.Name -eq 'data' } | Select-Object -First 1
    if (-not $CleanupOnly -and $dataEntry -and (Is-Linked $dataEntry)) {
        [Environment]::SetEnvironmentVariable('CODEX_HOME', "$destinationRoot\data", 'User')
    }
    Status 'moving_windows_application' 'Data has moved. Asking Windows to move the installed application to D drive.'
    $application = if ($MoveApplication -and -not $CleanupOnly) { Move-Application } else { @{state='not_requested'; note='Use Windows Settings to manage installed application packages.'} }
    $retained = @($results | Where-Object { $_.state -eq 'linked_backup_retained' })
    $stage = if ($application.state -eq 'pending') { 'data_complete_attention_needed' } elseif ($retained.Count) { 'complete_backup_retained' } else { 'complete' }
    $final = @{entries=$results; application=$application; windowsManagedOnD=$windowsManagedOnD; home="$destinationRoot\data"; retainedBackups=$retained; message='C-drive junctions are compatibility pointers. File contents are on D drive.'}
    Status $stage $final
    @("Status: $stage", "Codex data: $destinationRoot\data", ('Application: ' + ($application | ConvertTo-Json -Compress)), 'See migration\status.json for details.') | Set-Content -LiteralPath "$workRoot\RESULT.txt" -Encoding UTF8
} catch {
    Status 'failed' @{message=$_.Exception.Message; instruction='Keep original files and transaction records. See migration.log; no unverified source is deleted.'}
    $_ | Out-String | Add-Content -LiteralPath (Join-Path $workRoot 'worker-error.log') -Encoding UTF8
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
