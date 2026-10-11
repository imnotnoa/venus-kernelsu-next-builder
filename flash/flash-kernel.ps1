<#
  ==========================================================================
  DISCLAIMER

  Your warranty is void. Let's be honest, it died the day you unlocked the
  bootloader.

  I am not responsible for bricked phones, bootloops, a phone that only boots
  on Tuesdays, you getting fired because your alarm didn't go off after
  flashing this, a dead battery on the way to the airport, or thermonuclear
  war.

  YOU are choosing to build and flash a custom kernel. If it goes wrong, the
  person to talk to is in the mirror. This script does a test boot first so
  you don't have to find things out the hard way. Read the README. Twice.
  ==========================================================================

.SYNOPSIS
    Puts a KernelSU Next kernel into your ROM's stock boot.img for the
    Xiaomi Mi 11 (venus), test-boots it, and flashes it only after you
    confirm the test boot worked.

.DESCRIPTION
    1. Checks the phone: venus, active slot, running kernel (uname -r).
    2. Checks the kernel Image: arm64, contains KernelSU, and has EXACTLY the
       same version as the running kernel. A mismatch is a hard stop.
    3. Checks the stock boot.img: unpatched ramdisk and the same kernel
       version. A mismatch is a hard stop.
    4. Builds boot-ksu.img on the phone with magiskboot (from the official
       Magisk APK, runs as the normal shell user; root is not needed).
    5. Test boot with "fastboot boot": nothing is flashed. You confirm that
       screen, touch, Wi-Fi and sound work and that KernelSU Next says
       "Working".
    6. Only then: flashes boot-ksu.img to the active slot.

    Files and a log go to .\work\<date-time>\ next to this script.

.PARAMETER Image
    The kernel from the workflow: "Image", "Image.gz", or the workflow
    artifact .zip.

.PARAMETER StockBoot
    The original boot.img of EXACTLY the ROM build you are running (from the
    ROM zip, extract payload.bin with payload-dumper-go if needed, or from your
    ROM's download page).

.PARAMETER PrepareOnly
    Only check everything and build boot-ksu.img. No reboot, no test boot,
    nothing flashed.

.PARAMETER AcceptDisclaimer
    Skip the "press Enter" after the disclaimer. You still accept it.

.PARAMETER Restore
    Emergency restore: flash this boot.img (for example your stock boot.img)
    to the active slot. Also works when the phone is already in fastboot.

.EXAMPLE
    .\flash-kernel.ps1 -Image .\Image -StockBoot .\boot.img
.EXAMPLE
    .\flash-kernel.ps1 -Image .\venus-kernel.zip -StockBoot .\boot.img -PrepareOnly
.EXAMPLE
    .\flash-kernel.ps1 -Restore .\boot.img
#>
[CmdletBinding()]
param(
    [string]$Image,
    [string]$StockBoot,
    [string]$ManagerApk,
    [string]$ManagerUrl = 'https://github.com/KernelSU-Next/KernelSU-Next/releases/download/v3.4.0/KernelSU_Next_v3.4.0_33294-release.apk',
    [string]$MagiskUrl = 'https://github.com/topjohnwu/Magisk/releases/download/v31.0/Magisk-v31.0.apk',
    [switch]$PrepareOnly,
    [string]$Restore,
    [switch]$AcceptDisclaimer
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with a progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Device      = 'venus'
$ManagerPkg  = 'com.rifsxd.ksunext'
$Remote      = '/data/local/tmp/ksu-flash'
$PlatformToolsUrl = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
$UsbDriverUrl = 'https://developer.android.com/studio/run/win-usb'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$CacheDir  = Join-Path $ScriptDir 'downloads'
$Session   = Join-Path $ScriptDir ('work\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $CacheDir, $Session | Out-Null

$script:AdbExe = $null
$script:FastbootExe = $null

# ---------------------------------------------------------------------------
# Output and prompts
# ---------------------------------------------------------------------------

function Write-Step([string]$Text) { Write-Host ''; Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Info([string]$Text) { Write-Host "    $Text" }
function Write-Ok([string]$Text)   { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Note([string]$Text) { Write-Host "    [!] $Text" -ForegroundColor Yellow }

function Confirm-Choice([string]$Question, [bool]$Default = $true) {
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "    $Question $hint").Trim().ToLower()
        if ($answer -eq '') { return $Default }
        if ($answer -in @('y', 'yes')) { return $true }
        if ($answer -in @('n', 'no')) { return $false }
    }
}

function Confirm-Danger([string]$Question) {
    Write-Host "    $Question" -ForegroundColor Yellow
    return ((Read-Host '    Type YES (capitals) to continue').Trim() -ceq 'YES')
}

function Show-Disclaimer {
    Write-Host ''
    Write-Host '  DISCLAIMER' -ForegroundColor Yellow
    Write-Host '  Your warranty is void (it died when you unlocked the bootloader). I am not' -ForegroundColor Yellow
    Write-Host '  responsible for bricked phones, bootloops, you getting fired because your' -ForegroundColor Yellow
    Write-Host '  alarm did not go off, or thermonuclear war. You chose to flash a custom' -ForegroundColor Yellow
    Write-Host '  kernel; if it goes wrong, the person to talk to is in the mirror.' -ForegroundColor Yellow
    Write-Host ''
    if (-not $AcceptDisclaimer) {
        [void](Read-Host '  Press Enter if you read that and accept it (Ctrl+C to quit)')
    }
}

# ---------------------------------------------------------------------------
# Native tools. Windows PowerShell 5.1 turns stderr output into an error when
# ErrorActionPreference is Stop, so switch it off while adb/fastboot run.
# ---------------------------------------------------------------------------

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [switch]$AllowFail)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $saved
    }
    $text = ($output -join "`n").Trim()
    if ($code -ne 0 -and -not $AllowFail) {
        throw "Command failed (exit code $code): $(Split-Path $Exe -Leaf) $($Arguments -join ' ')`n$text"
    }
    return [pscustomobject]@{ Code = $code; Text = $text }
}

function Adb      { (Invoke-Native -Exe $script:AdbExe -Arguments $args).Text }
function Adb-Try  { Invoke-Native -Exe $script:AdbExe -Arguments $args -AllowFail }
function Fastboot { Invoke-Native -Exe $script:FastbootExe -Arguments $args -AllowFail }

function Invoke-Shell([string]$Command, [switch]$AllowFail) {
    Invoke-Native -Exe $script:AdbExe -Arguments @('shell', $Command) -AllowFail:$AllowFail
}

function Get-Download([string]$Url, [string]$FileName) {
    $target = Join-Path $CacheDir $FileName
    if (-not (Test-Path $target)) {
        Write-Info "Downloading $Url"
        $partial = "$target.part"
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
        Move-Item -Force $partial $target
    }
    return $target
}

# ---------------------------------------------------------------------------
# Kernel images
# ---------------------------------------------------------------------------

function Get-LinuxBanner([byte[]]$Bytes) {
    # Latin-1 maps every byte to one character, so a regex works on binary data.
    $text = [Text.Encoding]::GetEncoding(28591).GetString($Bytes)
    $match = [regex]::Match($text, 'Linux version (\d+\.\d+\.\d+[^\s\x00]*) \([^\x00\n]+')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{
        Banner  = $match.Value.Trim()
        Release = $match.Groups[1].Value
        Ksu     = $text.Contains('KernelSU')
    }
}

function Test-Arm64Image([byte[]]$Bytes) {
    # arm64 Image header: magic "ARM\x64" at offset 0x38
    return ($Bytes.Length -gt 0x40 -and $Bytes[0x38] -eq 0x41 -and $Bytes[0x39] -eq 0x52 -and
            $Bytes[0x3A] -eq 0x4D -and $Bytes[0x3B] -eq 0x64)
}

function Expand-GzipBytes([byte[]]$Bytes) {
    $in = New-Object IO.MemoryStream(, $Bytes)
    $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream
    $gz.CopyTo($out)
    $gz.Dispose()
    return $out.ToArray()
}

function Read-ZipEntry([string]$Zip, [string[]]$Names) {
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($name in $Names) {
            $entry = $archive.Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($entry) {
                $stream = $entry.Open()
                $buffer = New-Object IO.MemoryStream
                $stream.CopyTo($buffer)
                $stream.Dispose()
                return [pscustomobject]@{ Name = $entry.FullName; Bytes = $buffer.ToArray() }
            }
        }
    } finally {
        $archive.Dispose()
    }
    return $null
}

# ---------------------------------------------------------------------------
# Waiting for the phone
# ---------------------------------------------------------------------------

function Wait-Adb([int]$TimeoutSec = 300) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $warned = $false
    while ((Get-Date) -lt $deadline) {
        if ((Adb-Try get-state).Text -eq 'device') { return $true }
        if (-not $warned -and (Adb-Try devices).Text -match 'unauthorized') {
            Write-Note 'Allow USB debugging on the phone (tick "Always allow from this computer").'
            $warned = $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Wait-BootCompleted([int]$TimeoutSec = 420) {
    if (-not (Wait-Adb $TimeoutSec)) { return $false }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if ((Adb-Try shell getprop sys.boot_completed).Text -eq '1') { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Wait-Fastboot([int]$TimeoutSec = 90) {
    while ($true) {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline) {
            if ((Fastboot devices).Text -match '\sfastboot') { return }
            Start-Sleep -Seconds 2
        }
        Write-Note 'No phone found in fastboot mode.'
        Write-Info 'Does the screen say FASTBOOT? Then Windows is probably missing the USB driver:'
        Write-Info "install the Google USB Driver ($UsbDriverUrl) and pick"
        Write-Info '"Android Bootloader Interface" in Device Manager for the device with the yellow mark.'
        if (-not (Confirm-Choice 'Try again?')) { throw 'Fastboot not reachable.' }
    }
}

function Enter-Fastboot {
    if ((Fastboot devices).Text -match '\sfastboot') { return }
    Write-Info 'Rebooting to the bootloader (fastboot)...'
    Adb reboot bootloader | Out-Null
    Wait-Fastboot
    $product = (Fastboot getvar product).Text
    if ($product -notmatch "product:\s*$Device") { throw "Fastboot reports a different device:`n$product" }
}

function Get-FastbootSlot {
    $raw = (Fastboot getvar current-slot).Text
    $match = [regex]::Match($raw, 'current-slot:\s*_?([ab])')
    if (-not $match.Success) { throw "Could not read the active slot:`n$raw" }
    return '_' + $match.Groups[1].Value
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

function Initialize-PlatformTools {
    Write-Step 'Android platform-tools (adb/fastboot)'
    $local = Join-Path $CacheDir 'platform-tools\adb.exe'
    if (-not (Test-Path $local)) {
        $zip = Get-Download $PlatformToolsUrl 'platform-tools-latest-windows.zip'
        Expand-Archive -Path $zip -DestinationPath $CacheDir -Force
    }
    $script:AdbExe = $local
    $script:FastbootExe = Join-Path $CacheDir 'platform-tools\fastboot.exe'
    Invoke-Native -Exe $script:AdbExe -Arguments @('start-server') -AllowFail | Out-Null
    Write-Ok ((Adb version) -split "`n")[0]
}

function Get-DeviceInfo {
    Write-Step 'Checking the phone'
    Write-Info 'Connect the Mi 11 over USB with USB debugging on (Settings > System > Developer options).'
    if (-not (Wait-Adb 180)) {
        $connected = @((Adb-Try devices).Text -split "`n" | Where-Object { $_ -match '\tdevice\s*$' })
        if ($connected.Count -gt 1) { throw 'More than one Android device is connected; unplug the others.' }
        throw 'No phone found over adb.'
    }
    $info = [ordered]@{
        Device  = Adb shell getprop ro.product.device
        Android = Adb shell getprop ro.build.version.release
        Build   = Adb shell getprop ro.build.display.id
        Slot    = Adb shell getprop ro.boot.slot_suffix
        Release = Adb shell uname -r
        Version = Adb shell cat /proc/version
    }
    Write-Info "Device:  $($info.Device)  (Android $($info.Android), slot $($info.Slot))"
    Write-Info "ROM:     $($info.Build)"
    Write-Info "Kernel:  $($info.Release)"
    if ($info.Device -ne $Device) { throw "This script is only for the Mi 11 ($Device); found: $($info.Device)." }
    if ($info.Slot -notmatch '^_[ab]$') { throw "Unexpected slot '$($info.Slot)'." }

    if ((Adb-Try shell pm list packages com.topjohnwu.magisk).Text -match 'package:com\.topjohnwu\.magisk\s*$') {
        Write-Note 'The Magisk app is installed. KernelSU would run your Magisk modules from /data/adb at boot.'
        Write-Note 'Uninstall Magisk first: Magisk app > Uninstall Magisk > Complete uninstall. Then run this again.'
        throw 'Stopped: Magisk is still installed. Nothing was changed.'
    }
    return [pscustomobject]$info
}

function Initialize-Remote {
    # magiskboot from the official Magisk APK runs as the normal shell user.
    Invoke-Shell "rm -rf $Remote 2>/dev/null; mkdir -p $Remote && touch $Remote/.w" | Out-Null
    $apk = Get-Download $MagiskUrl (Split-Path $MagiskUrl -Leaf)
    $archive = [IO.Compression.ZipFile]::OpenRead($apk)
    try {
        $entry = $archive.GetEntry('lib/arm64-v8a/libmagiskboot.so')
        if (-not $entry) { throw "No arm64 magiskboot in $apk" }
        $target = Join-Path $Session 'magiskboot'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
    } finally {
        $archive.Dispose()
    }
    Adb push $target "$Remote/magiskboot" | Out-Null
    Invoke-Shell "chmod 755 $Remote/magiskboot" | Out-Null
}

function Get-KsuKernel($Dev) {
    Write-Step 'Checking the KernelSU kernel'
    if (-not (Test-Path $Image)) { throw "File not found: $Image" }
    $source = (Resolve-Path $Image).Path
    $ext = [IO.Path]::GetExtension($source).ToLower()

    if ($ext -eq '.zip') {
        $entry = Read-ZipEntry $source @('Image', 'Image.gz')
        if (-not $entry) { throw "No 'Image' or 'Image.gz' in $source." }
        Write-Info "From zip: $($entry.Name)"
        $bytes = $entry.Bytes
        if ($entry.Name -like '*.gz') { $bytes = Expand-GzipBytes $bytes }
        $sum = Read-ZipEntry $source @('Image.sha256')
        if ($sum -and $entry.Name -notlike '*.gz') {
            $expected = (([Text.Encoding]::ASCII.GetString($sum.Bytes)).Trim() -split '\s+')[0].ToLower()
            $sha = [Security.Cryptography.SHA256]::Create()
            $actual = (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
            if ($expected -ne $actual) { throw "SHA256 of the Image does not match Image.sha256 (expected $expected, got $actual)." }
            Write-Ok 'SHA256 matches Image.sha256'
        }
    } else {
        $bytes = [IO.File]::ReadAllBytes($source)
        $sumFile = Join-Path (Split-Path $source) 'Image.sha256'
        if ((Split-Path $source -Leaf) -eq 'Image' -and (Test-Path $sumFile)) {
            $expected = ((Get-Content $sumFile -Raw).Trim() -split '\s+')[0].ToLower()
            $actual = (Get-FileHash $source -Algorithm SHA256).Hash.ToLower()
            if ($expected -ne $actual) { throw "SHA256 of the Image does not match Image.sha256 (expected $expected, got $actual)." }
            Write-Ok 'SHA256 matches Image.sha256'
        }
        if ($bytes.Length -gt 2 -and $bytes[0] -eq 0x1F -and $bytes[1] -eq 0x8B) { $bytes = Expand-GzipBytes $bytes }
    }

    if (-not (Test-Arm64Image $bytes)) { throw "$source is not an arm64 kernel Image." }
    $banner = Get-LinuxBanner $bytes
    if (-not $banner) { throw 'No "Linux version" string found in the kernel.' }
    Write-Info "Kernel:  $($banner.Release)"
    if (-not $banner.Ksu) { throw 'This kernel does not contain KernelSU.' }
    Write-Ok 'KernelSU is in the kernel'

    # Same source commit as the ROM, or the vendor modules (display, touch,
    # audio) will not load. This check cannot be overridden on purpose.
    if ($banner.Release -ne $Dev.Release) {
        Write-Note "This kernel ($($banner.Release)) is not the version your phone runs ($($Dev.Release))."
        Write-Note 'Build it again with kernel_version set to exactly your "adb shell uname -r".'
        throw 'Stopped: kernel version does not match your ROM. Nothing was changed.'
    }
    Write-Ok 'Kernel version matches your ROM exactly'

    $out = Join-Path $Session 'ksu-Image'
    [IO.File]::WriteAllBytes($out, $bytes)
    Adb push $out "$Remote/ksu-Image" | Out-Null
    return $banner
}

function Test-StockBoot($Dev) {
    Write-Step 'Checking the stock boot.img'
    if (-not (Test-Path $StockBoot)) { throw "File not found: $StockBoot" }
    Adb push (Resolve-Path $StockBoot).Path "$Remote/stock-boot.img" | Out-Null
    # "cpio test" returns a bit mask: (code & 3) == 0 means an unpatched ramdisk.
    $r = Invoke-Shell ("cd $Remote && rm -rf chk && mkdir chk && cd chk && " +
        "../magiskboot unpack ../stock-boot.img >/dev/null 2>&1; [ -f kernel ] || { echo NO_KERNEL; exit 0; }; " +
        "../magiskboot cpio ramdisk.cpio test >/dev/null 2>&1; [ `$((`$? & 3)) -eq 0 ] || { echo PATCHED; exit 0; }; " +
        "echo STOCK_OK") -AllowFail
    if ($r.Text -match 'NO_KERNEL') { throw 'That file is not a usable boot.img (no kernel inside).' }
    if ($r.Text -match 'PATCHED') { throw 'That boot.img is patched (Magisk or similar). Use the original boot.img from your ROM.' }
    if ($r.Text -notmatch 'STOCK_OK') { throw "Could not check the boot.img:`n$($r.Text)" }

    $kernel = Join-Path $Session 'stock-kernel'
    Adb pull "$Remote/chk/kernel" $kernel | Out-Null
    $banner = Get-LinuxBanner ([IO.File]::ReadAllBytes($kernel))
    if (-not $banner) { throw 'No "Linux version" string found in the stock kernel.' }
    if ($banner.Release -ne $Dev.Release) {
        Write-Note "The boot.img has kernel $($banner.Release), your phone runs $($Dev.Release)."
        throw 'Stopped: the boot.img is from a different ROM build. Use the one from exactly your build. Nothing was changed.'
    }
    Write-Ok 'Unpatched boot.img of exactly your build'
}

function New-KsuBoot {
    Write-Step 'Building boot-ksu.img (stock ramdisk + KernelSU kernel)'
    Invoke-Shell ("cd $Remote && rm -rf new && mkdir new && cd new && " +
        "../magiskboot unpack ../stock-boot.img >/dev/null 2>&1 && cp -f ../ksu-Image kernel && " +
        "../magiskboot repack ../stock-boot.img ../boot-ksu.img >/dev/null 2>&1") | Out-Null
    # Unpacking the result must give exactly our kernel and an unpatched ramdisk.
    $verify = Invoke-Shell ("cd $Remote && rm -rf vfy && mkdir vfy && cd vfy && " +
        "../magiskboot unpack ../boot-ksu.img >/dev/null 2>&1 && cmp -s kernel ../ksu-Image && " +
        "../magiskboot cpio ramdisk.cpio test >/dev/null 2>&1; [ `$((`$? & 3)) -eq 0 ] && echo VERIFIED") -AllowFail
    if ($verify.Text -notmatch 'VERIFIED') { throw "Verifying boot-ksu.img failed:`n$($verify.Text)" }
    $local = Join-Path $Session 'boot-ksu.img'
    Adb pull "$Remote/boot-ksu.img" $local | Out-Null
    Write-Ok 'boot-ksu.img built and verified'
    Write-Info "SHA256: $((Get-FileHash $local -Algorithm SHA256).Hash)"
    return $local
}

function Install-Manager {
    $apk = if ($ManagerApk) { (Resolve-Path $ManagerApk).Path } else { Get-Download $ManagerUrl (Split-Path $ManagerUrl -Leaf) }
    $install = Adb-Try install -r $apk
    if ($install.Text -match 'Success') { Write-Ok 'KernelSU Next manager installed' }
    else { Write-Note "Installing the manager failed:`n$($install.Text)" }
    Adb-Try shell monkey -p $ManagerPkg -c android.intent.category.LAUNCHER 1 | Out-Null
}

function Invoke-TestBoot([string]$BootImage, $Banner) {
    Write-Step 'Test boot (nothing is flashed)'
    Write-Info 'The phone boots once with the KernelSU kernel. A normal reboot brings back your current boot.'
    Enter-Fastboot
    $boot = Fastboot boot $BootImage
    if ($boot.Code -ne 0) {
        Write-Note "'fastboot boot' is not supported or failed:`n$($boot.Text)"
        Fastboot reboot | Out-Null
        if (-not (Wait-BootCompleted)) { throw 'The phone does not boot normally any more. Use -Restore with your stock boot.img.' }
        throw 'The test boot could not run. Without a test boot nothing gets flashed; nothing was changed.'
    }
    Write-Info 'Waiting for Android to finish booting (up to 7 minutes)...'
    if (-not (Wait-BootCompleted)) {
        Write-Note 'The test boot did not finish. Nothing was flashed.'
        Write-Info 'Hold the power button for ~15 seconds; the phone then starts with your current boot.'
        Write-Info 'If the screen stayed black or touch did not work, the kernel does not match your ROM.'
        Write-Info 'If it booted but KernelSU was not detected, check hook_mode (use kprobes).'
        throw 'Test boot failed.'
    }
    $version = Adb shell cat /proc/version
    $ok = $version.Trim() -eq $Banner.Banner.Trim()
    if ($ok) {
        Write-Ok 'Android is running the KernelSU kernel.'
        Install-Manager
        Write-Info 'Check the phone now. KernelSU Next should say "Working" at the top.'
        if (-not (Confirm-Choice 'Do screen, touch, Wi-Fi and sound work, and does KernelSU Next say "Working"?')) { $ok = $false }
    } else {
        Write-Note "Unexpected kernel after the test boot: $version"
    }
    Write-Info 'Rebooting back to your current boot...'
    Adb reboot | Out-Null
    if (-not (Wait-BootCompleted)) { throw 'The phone does not boot normally after the test boot. Use -Restore with your stock boot.img.' }
    if (-not $ok) { throw 'Test boot not approved; nothing was changed.' }
}

function Install-KsuBoot([string]$BootImage, [string]$Slot, $Banner) {
    Write-Step 'Flashing boot-ksu.img'
    Enter-Fastboot
    $fbSlot = Get-FastbootSlot
    if ($fbSlot -ne $Slot) { throw "Fastboot reports slot $fbSlot, Android reported $Slot. Stopped." }
    $flash = Fastboot flash "boot$Slot" $BootImage
    if ($flash.Code -ne 0) { throw "Flashing failed:`n$($flash.Text)" }
    Write-Ok "boot$Slot flashed"
    Fastboot reboot | Out-Null
    Write-Info 'Waiting for Android to boot (up to 7 minutes)...'
    if (-not (Wait-BootCompleted)) {
        Write-Note 'The phone does not boot.'
        Write-Info 'Put it in fastboot (power + volume down) and restore your stock boot.img with:'
        Write-Info "  .\Flash-Kernel.bat -Restore `"$((Resolve-Path $StockBoot).Path)`""
        throw 'Boot after flashing failed.'
    }
    $version = Adb shell cat /proc/version
    if ($version.Trim() -eq $Banner.Banner.Trim()) { Write-Ok 'The KernelSU kernel is running' }
    else { Write-Note "Unexpected kernel: $version" }
}

function Invoke-Restore([string]$BootImage) {
    Initialize-PlatformTools
    if (-not (Test-Path $BootImage)) { throw "File not found: $BootImage" }
    $BootImage = (Resolve-Path $BootImage).Path
    Write-Step "Emergency restore: flashing $BootImage"
    if ((Adb-Try get-state).Text -eq 'device') { Adb reboot bootloader | Out-Null }
    else { Write-Info 'Put the phone in fastboot: power off, then hold power + volume down.' }
    Wait-Fastboot 300
    $product = (Fastboot getvar product).Text
    if ($product -notmatch "product:\s*$Device") { throw "Fastboot reports a different device:`n$product" }
    $slot = Get-FastbootSlot
    if (-not (Confirm-Choice "Overwrite boot$slot with $(Split-Path $BootImage -Leaf)?")) { throw 'Stopped.' }
    $flash = Fastboot flash "boot$slot" $BootImage
    if ($flash.Code -ne 0) { throw "Flashing failed:`n$($flash.Text)" }
    Write-Ok "boot$slot restored"
    Fastboot reboot | Out-Null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Start-Transcript -Path (Join-Path $Session 'log.txt') | Out-Null
$exitCode = 0
try {
    Write-Host 'KernelSU Next kernel flasher for the Xiaomi Mi 11 (venus)' -ForegroundColor White
    Show-Disclaimer

    if ($Restore) {
        Invoke-Restore $Restore
        return
    }
    if (-not $Image -or -not $StockBoot) {
        throw 'Usage: Flash-Kernel.bat -Image <Image or artifact .zip> -StockBoot <stock boot.img> [-PrepareOnly]'
    }

    Initialize-PlatformTools
    $dev = Get-DeviceInfo
    Initialize-Remote
    $banner = Get-KsuKernel $dev
    Test-StockBoot $dev
    $bootImage = New-KsuBoot

    if ($PrepareOnly) {
        Write-Step 'Done (-PrepareOnly)'
        Write-Info "boot-ksu.img is in $Session. Nothing was rebooted or flashed."
        return
    }

    Invoke-TestBoot $bootImage $banner

    Write-Step 'Confirm'
    Write-Info "The test boot worked. Next: flash boot-ksu.img to boot$($dev.Slot)."
    Write-Info "Keep your stock boot.img; it is your way back ($((Resolve-Path $StockBoot).Path))."
    if (-not (Confirm-Danger 'Flash the KernelSU boot image now?')) { throw 'Stopped by you; nothing was changed.' }

    Install-KsuBoot $bootImage $dev.Slot $banner

    Write-Step 'Done'
    Write-Info '1. Open KernelSU Next; it should say "Working".'
    Write-Info '2. Install a metamodule (e.g. meta-overlayfs) before other modules, or modules are not mounted.'
    Write-Info '3. After a ROM update you lose root: build a kernel for the new uname -r and run this again.'
} catch {
    $exitCode = 1
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $Session" -ForegroundColor Red
} finally {
    # Remove the temporary files (up to ~400 MB) from the phone.
    if ($script:AdbExe -and (Adb-Try get-state).Text -eq 'device') { Invoke-Shell "rm -rf $Remote" -AllowFail | Out-Null }
    Stop-Transcript | Out-Null
}
exit $exitCode
