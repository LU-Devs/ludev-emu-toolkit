param(
    [ValidateSet('run','fix','list','status','stop','kill','init','doctor')]
    [string]$Action = 'status',
    [string]$AvdName,
    [switch]$ColdBoot,
    [switch]$Fast
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$CmdRoot = Split-Path -Parent $ScriptRoot
$ProfileMarker = '# Android Emulator Toolkit PATH bootstrap'

function Add-PathSegment {
    param(
        [string]$BasePath,
        [string]$Segment
    )

    if (-not $BasePath) { return $Segment }
    $parts = $BasePath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' }
    if ($parts -contains $Segment) { return ($parts -join ';') }
    return (($parts + $Segment) -join ';')
}

function Get-SdkRoot {
    $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $defaultSdk = Join-Path $localAppData 'Android\Sdk'

    $candidates = @(
        $defaultSdk,
        $env:ANDROID_SDK_ROOT,
        $env:ANDROID_HOME
    )

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $root = $candidate.Trim().Trim('"')
        if ($root -match '^[A-Za-z]$') { continue }
        if (-not (Test-Path $root)) { continue }

        $adbCheck = Join-Path $root 'platform-tools\adb.exe'
        $emuCheck = Join-Path $root 'emulator\emulator.exe'
        if ((Test-Path $adbCheck) -and (Test-Path $emuCheck)) {
            return $root
        }
    }

    if (-not $candidates -or $candidates.Count -eq 0) {
        throw 'Android SDK not found. Expected ANDROID_SDK_ROOT, ANDROID_HOME, or %LOCALAPPDATA%\\Android\\Sdk.'
    }

    throw 'Android SDK variables were found but none pointed to a valid SDK with adb.exe and emulator.exe.'
}

function Get-ToolPaths {
    $sdkRoot = Get-SdkRoot
    $adb = Join-Path $sdkRoot 'platform-tools\adb.exe'
    $emulator = Join-Path $sdkRoot 'emulator\emulator.exe'

    if (-not (Test-Path $adb)) {
        throw "adb.exe not found at: $adb"
    }
    if (-not (Test-Path $emulator)) {
        throw "emulator.exe not found at: $emulator"
    }

    return @{
        SdkRoot = $sdkRoot
        Adb = $adb
        Emulator = $emulator
    }
}

function Ensure-ToolPathsInUserEnvironment {
    param(
        [string]$SdkRoot
    )

    $pt = Join-Path $SdkRoot 'platform-tools'
    $emu = Join-Path $SdkRoot 'emulator'
    $required = @($CmdRoot, $pt, $emu)

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }

    $updated = $userPath
    $added = @()
    foreach ($segment in $required) {
        $next = Add-PathSegment -BasePath $updated -Segment $segment
        if ($next -ne $updated) { $added += $segment }
        $updated = $next
    }

    if ($updated -ne $userPath) {
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    }

    foreach ($segment in $required) {
        if ($env:Path -notlike "*$segment*") {
            $env:Path = Add-PathSegment -BasePath $env:Path -Segment $segment
        }
    }

    if (-not (Test-Path $PROFILE)) {
        New-Item -ItemType File -Path $PROFILE -Force | Out-Null
    }

    $profileText = Get-Content $PROFILE -Raw
    if ($profileText -notmatch [Regex]::Escape($ProfileMarker)) {
        $snippet = @"
$ProfileMarker
$toolPaths = @(
            '$CmdRoot',
    '$pt',
    '$emu'
)
foreach (`$p in `$toolPaths) {
    if (`$env:Path -notlike "*`$p*") { `$env:Path += ";`$p" }
}
"@
        Add-Content -Path $PROFILE -Value "`n$snippet"
        Write-Output "Updated PowerShell profile: $PROFILE"
    }

    if ($added.Count -gt 0) {
        Write-Output 'Added to USER Path:'
        $added | ForEach-Object { Write-Output " - $_" }
    } else {
        Write-Output 'USER Path already contains required entries.'
    }
}

function Show-DoctorReport {
    param([hashtable]$Tools)

    $emuCmd = Get-Command emu -ErrorAction SilentlyContinue
    $adbCmd = Get-Command adb -ErrorAction SilentlyContinue
    $emuExeCmd = Get-Command emulator -ErrorAction SilentlyContinue

    Write-Output "SDK: $($Tools.SdkRoot)"
    Write-Output "adb path: $($Tools.Adb)"
    Write-Output "emulator path: $($Tools.Emulator)"
    Write-Output "emu command: $($(if ($emuCmd) { $emuCmd.Source } else { 'NOT FOUND' }))"
    Write-Output "adb command: $($(if ($adbCmd) { $adbCmd.Source } else { 'NOT FOUND' }))"
    Write-Output "emulator command: $($(if ($emuExeCmd) { $emuExeCmd.Source } else { 'NOT FOUND' }))"

    Start-Adb -AdbPath $Tools.Adb
    Show-Devices -AdbPath $Tools.Adb
}

function Get-AvdList {
    param([string]$EmulatorPath)

    $list = & $EmulatorPath -list-avds
    return @($list | Where-Object { $_ -and $_.Trim().Length -gt 0 })
}

function Resolve-AvdName {
    param(
        [string]$Preferred,
        [string[]]$AllAvds
    )

    if ($Preferred) {
        if ($AllAvds -contains $Preferred) {
            return $Preferred
        }
        throw "AVD '$Preferred' not found. Use 'emu list' to see valid names."
    }

    $priority = @('Medium_Phone_API_35','Pixel_9_Pro')
    foreach ($name in $priority) {
        if ($AllAvds -contains $name) {
            return $name
        }
    }

    if ($AllAvds.Count -gt 0) {
        return $AllAvds[0]
    }

    throw 'No AVDs found. Create one from Android Studio Device Manager first.'
}

function Start-Adb {
    param([string]$AdbPath)
    & $AdbPath start-server | Out-Null
}

function Show-Devices {
    param([string]$AdbPath)
    & $AdbPath devices -l
}

function Get-EmulatorSerials {
    param([string]$AdbPath)

    $lines = & $AdbPath devices
    $serials = @()

    foreach ($line in $lines) {
        if ($line -match '^(emulator-\d+)\s+(device|offline|unauthorized)$') {
            $serials += $matches[1]
        }
    }

    return $serials
}

function Stop-EmulatorsGracefully {
    param([string]$AdbPath)

    $serials = Get-EmulatorSerials -AdbPath $AdbPath
    if (-not $serials -or $serials.Count -eq 0) {
        Write-Output 'No running emulators detected to stop gracefully.'
        return
    }

    foreach ($serial in $serials) {
        try {
            & $AdbPath -s $serial emu kill | Out-Null
            Write-Output "Sent graceful shutdown to: $serial"
        }
        catch {
            Write-Output "Could not gracefully stop $serial via adb emu kill."
        }
    }

    Start-Sleep -Seconds 2
}

function Kill-EmulatorProcesses {
    Stop-Process -Name emulator -Force -ErrorAction SilentlyContinue
    Stop-Process -Name qemu-system-x86_64 -Force -ErrorAction SilentlyContinue
    Stop-Process -Name adb -Force -ErrorAction SilentlyContinue
}

function Start-Avd {
    param(
        [string]$EmulatorPath,
        [string]$Name,
        [bool]$UseColdBoot = $false
    )

    $args = @('-avd', $Name, '-netdelay', 'none', '-netspeed', 'full')
    if ($UseColdBoot) {
        $args += @('-no-snapshot-load', '-no-snapshot-save')
    }

    # Hide the launcher console window when possible; emulator UI still opens normally.
    Start-Process -FilePath $EmulatorPath -ArgumentList $args -WindowStyle Hidden | Out-Null
}

try {
    switch ($Action) {
        'init' {
            $tools = Get-ToolPaths
            Ensure-ToolPathsInUserEnvironment -SdkRoot $tools.SdkRoot
            Write-Output 'Initialization complete. Open a new terminal or run: . $PROFILE'
            Show-DoctorReport -Tools $tools
        }

        'doctor' {
            $tools = Get-ToolPaths
            Show-DoctorReport -Tools $tools
            Write-Output "If 'emu command' is NOT FOUND, run: emu init"
        }

        'list' {
            $tools = Get-ToolPaths
            $allAvds = Get-AvdList -EmulatorPath $tools.Emulator
            if ($allAvds.Count -eq 0) {
                Write-Output 'No AVDs found.'
            } else {
                $allAvds | ForEach-Object { Write-Output $_ }
            }
        }

        'status' {
            $tools = Get-ToolPaths
            Write-Output "SDK: $($tools.SdkRoot)"
            Start-Adb -AdbPath $tools.Adb
            Show-Devices -AdbPath $tools.Adb
        }

        'kill' {
            Kill-EmulatorProcesses
            Write-Output 'Stopped emulator/qemu/adb processes.'
        }

        'stop' {
            $tools = Get-ToolPaths
            Start-Adb -AdbPath $tools.Adb
            Stop-EmulatorsGracefully -AdbPath $tools.Adb
            Show-Devices -AdbPath $tools.Adb
        }

        'run' {
            $tools = Get-ToolPaths
            $allAvds = Get-AvdList -EmulatorPath $tools.Emulator
            $resolvedAvd = Resolve-AvdName -Preferred $AvdName -AllAvds $allAvds
            Start-Adb -AdbPath $tools.Adb

            if (-not $Fast) {
                # Default mode: full reset to avoid stale snapshot state.
                Stop-EmulatorsGracefully -AdbPath $tools.Adb
                Kill-EmulatorProcesses
                Start-Sleep -Seconds 2
                Start-Adb -AdbPath $tools.Adb

                $forceColdBoot = $true
                if ($PSBoundParameters.ContainsKey('ColdBoot')) {
                    $forceColdBoot = [bool]$ColdBoot
                }

                Start-Avd -EmulatorPath $tools.Emulator -Name $resolvedAvd -UseColdBoot:$forceColdBoot
                Start-Sleep -Seconds 8
                Show-Devices -AdbPath $tools.Adb
                Write-Output "Reset stack and started AVD: $resolvedAvd"
            }
            else {
                $fastColdBoot = $false
                if ($PSBoundParameters.ContainsKey('ColdBoot')) {
                    $fastColdBoot = [bool]$ColdBoot
                }

                $hasDevice = (& $tools.Adb devices | Select-String 'emulator-\d+\s+device')
                if ($hasDevice) {
                    Write-Output 'An emulator is already online. Use emu status to inspect.'
                } else {
                    Start-Avd -EmulatorPath $tools.Emulator -Name $resolvedAvd -UseColdBoot:$fastColdBoot
                    Start-Sleep -Seconds 7
                    Show-Devices -AdbPath $tools.Adb
                    Write-Output "Fast start AVD: $resolvedAvd"
                }
            }
        }

        'fix' {
            $tools = Get-ToolPaths
            $allAvds = Get-AvdList -EmulatorPath $tools.Emulator
            $resolvedAvd = Resolve-AvdName -Preferred $AvdName -AllAvds $allAvds
            Start-Adb -AdbPath $tools.Adb
            Stop-EmulatorsGracefully -AdbPath $tools.Adb
            Kill-EmulatorProcesses
            Start-Sleep -Seconds 2
            Start-Adb -AdbPath $tools.Adb
            Start-Avd -EmulatorPath $tools.Emulator -Name $resolvedAvd -UseColdBoot:$true
            Start-Sleep -Seconds 8
            Show-Devices -AdbPath $tools.Adb
            Write-Output "Reset stack and started AVD: $resolvedAvd"
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
