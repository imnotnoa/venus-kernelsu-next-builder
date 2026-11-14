# venus-kernelsu-next-builder

> [!IMPORTANT]
> **Evolution X 12.4 and newer: you don't need to build a kernel.**
>
> Starting with Evolution X 12.4 (November 2026), the Evolution X kernel for venus has **KernelSU Next built in** (latest `legacy` branch, manual hooks). Future Evolution X builds will most likely keep it that way.
>
> - Just install the ROM update as it is and keep its own boot.img. Don't build or flash a custom kernel.
> - After the reboot, KernelSU Next says **Working** and your modules are still there.
> - If you run the workflow anyway, it notices the built-in KernelSU and stops right away with **"KernelSU is already built in"**.
>
> You only need this repository for ROM builds **without** built-in KernelSU: Evolution X 12.3 and older, or other ROMs (LineageOS, crDroid, ...). More in [ROMs with KernelSU built in](#roms-with-kernelsu-built-in).

Build your own KernelSU Next kernel for the **Xiaomi Mi 11 (venus)**, from your ROM's own kernel source, on GitHub Actions. Then flash it safely with a test boot first.

No prebuilt kernels here. You build the one that matches your phone.

> [!WARNING]
> **Disclaimer**
>
> Your warranty is void. Let's be honest, it died the day you unlocked the bootloader.
>
> I am not responsible for bricked phones, bootloops, a phone that only boots on Tuesdays, you getting fired because your alarm didn't go off after flashing this, a dead battery on the way to the airport, or thermonuclear war.
>
> **You** are choosing to build and flash a custom kernel. If it goes wrong, the person to talk to is in the mirror. The flash script does a test boot first so you don't have to find things out the hard way. Read this README. Twice.

## Why you have to build it yourself

- The Mi 11 runs a **non-GKI 5.4 kernel** (`5.4.302-qgki-...`). KernelSU's GKI images and LKM patching don't work on it. KernelSU has to be compiled into the kernel.
- The display, touch and audio drivers are prebuilt modules in your ROM's `vendor_boot`. They only load on a kernel built from **exactly the same source commit**. Take a kernel from another ROM or another build, and you get a black screen, no touch, or a bootloop.
- That commit is in your `uname -r`, for example `5.4.302-qgki-g082d73c24f7a` = commit `082d73c24f7a`. The workflow builds exactly that commit and refuses to finish if the result doesn't have exactly your version string.

So a kernel someone else built is only safe for their exact ROM build. That's why this repo shares the recipe, not the kernel.

## What has been tested

| | |
|---|---|
| ROM | Evolution X 12.3, Android 17 (12.4 and newer have KernelSU Next built in: nothing to build) |
| Kernel | `5.4.302-qgki-g082d73c24f7a` |
| KernelSU Next | `v3.4.0-legacy`, manager v3.4.0 |
| Hook | `kprobes` works. `syscall_table` boots, but KernelSU isn't detected (this kernel uses CFI). |
| Flash scripts | `-PrepareOnly` on Windows (PowerShell) and Git Bash: the boot image is bit-for-bit identical to the one running on the test phone. |

Other ROMs (LineageOS, crDroid, ...) use the same kernel tree layout and should work, but are **untested**. The version check and the test boot are your safety net.

## What you need

- Xiaomi Mi 11 (venus) with an **unlocked bootloader**.
- A GitHub account (free) to run the build.
- A PC with Windows, Linux or macOS, and a USB cable.
- **adb and fastboot** with working drivers (see step 0).
- The **original boot.img of exactly the ROM build you are running** (see step 3).
- Battery above 50%.

## Step 0: platform-tools and drivers

### Windows

1. **platform-tools (adb + fastboot)**: the Windows flash script downloads Google's platform-tools into `flash\downloads\` by itself. If you want them yourself: download [SDK Platform-Tools for Windows](https://developer.android.com/tools/releases/platform-tools), unzip to e.g. `C:\platform-tools`.
2. **USB driver for adb and fastboot**: download the [Google USB Driver](https://developer.android.com/studio/run/win-usb) and unzip it.
3. Phone: Settings > About phone > tap the build number 7 times. Then Settings > System > Developer options > **USB debugging** on.
4. Connect the phone and allow USB debugging on the phone (tick "Always allow from this computer").
5. **Fastboot driver**: put the phone in fastboot (power off, then hold **power + volume down**). Windows often shows it as an unknown device. Then:
   - Open **Device Manager**, right-click the device with the yellow mark (often "Android" or "MI 11") > **Update driver**.
   - **Browse my computer for drivers** > **Let me pick from a list** > **Have Disk...** > select `android_winusb.inf` from the Google USB Driver folder.
   - Pick **Android Bootloader Interface** and confirm the warning.
6. Check in a terminal in the platform-tools folder:
   ```
   adb devices
   fastboot devices
   ```
   The first one (phone booted) and the second one (phone in fastboot) must each list your phone.

### Linux

```bash
# Debian / Ubuntu
sudo apt install adb fastboot android-sdk-platform-tools-common
# Fedora
sudo dnf install android-tools
# Arch
sudo pacman -S android-tools android-udev
```

The `*-common` / `android-udev` packages add the udev rules, so you don't need root for adb and fastboot. Log out and in again (or replug the phone) after installing. Check with `adb devices` and `fastboot devices`.

The flash script also needs `curl` and `unzip` (almost always installed already).

### macOS

```bash
brew install --cask android-platform-tools
```

macOS needs no drivers. Check with `adb devices` and `fastboot devices`.

## Step 1: find your kernel version and kernel source

With the phone connected and booted:

```bash
adb shell uname -r
```

Write down the exact output, for example `5.4.302-qgki-g082d73c24f7a`.

Then find your ROM's kernel source. It's usually linked in the ROM's XDA thread or in its device manifest. Known venus sources:

| ROM | `kernel_repo` | `kernel_branch` | Status |
|---|---|---|---|
| Evolution X (Android 17) | `Evolution-X-Devices/kernel_xiaomi_venus` | `cnb` | Tested up to 12.3. 12.4 and newer: KernelSU built in, no build needed |
| LineageOS 23.2 | `LineageOS/android_kernel_xiaomi_sm8350` | `lineage-23.2` | Untested |
| crDroid (Android 17) | `crdroidandroid/android_kernel_xiaomi_sm8350` | `17.0` | Untested |

If your commit isn't in the repo you picked, the build stops right away and tells you. That means: wrong source for your ROM.

## Step 2: build the kernel on GitHub

1. **Fork** this repository (button at the top right).
2. In your fork, open the **Actions** tab. GitHub disables workflows in forks: click **"I understand my workflows, go ahead and enable them"**.
3. Pick **Build venus kernel with KernelSU Next** > **Run workflow**.
4. Paste your `uname -r` into **kernel_version**. Change `kernel_repo` and `kernel_branch` if you don't run Evolution X. Leave the rest alone unless you know why.
5. **Run workflow**. A build takes about 30 to 60 minutes.
6. When it's green, your fork has a new **Release** with `Image`, `Image.sha256`, `Module.symvers`, `kernel.config` and `build-info.txt`. Download `Image` and `Image.sha256` into the same folder.

| Input | Default | What it is |
|---|---|---|
| `kernel_version` | (required) | Your exact `adb shell uname -r`. |
| `kernel_repo` | `Evolution-X-Devices/kernel_xiaomi_venus` | Your ROM's kernel source on GitHub. |
| `kernel_branch` | `cnb` | Branch that contains your commit. |
| `ksu_ref` | `v3.4.0-legacy` | KernelSU Next version. Must be a `-legacy` tag (non-GKI). |
| `hook_mode` | `kprobes` | How KernelSU hooks into the kernel. Keep `kprobes`. |
| `defconfig` | `vendor/lahaina-qgki_defconfig` + venus fragments | Defconfig, then config fragments. Same as the LineageOS-based device trees. |
| `clang_version` / `clang_ref` | `clang-r563880c` / `android-17.0.0_r1` | The compiler your ROM uses. |
| `vendor_boot_url` | empty | Optional direct link to your build's `vendor_boot.img`. The build then checks that your vendor modules fit the new kernel. |
| `publish` | `release` | `release`, `artifact` only, or `none` (test build, nothing to download). |

> Your fork is public, so its releases are too. That's fine: the kernel only fits your exact build anyway. Pick `artifact` if you'd rather not have a release.

## Step 3: get your stock boot.img

You need the original `boot.img` of **exactly** the build you are running (same `uname -r`). The flash script checks this and stops if it doesn't match.

- **Evolution X**: the download page for venus has `boot.img` for the latest build.
- **Other ROMs**: many offer `boot.img` as a separate download. Otherwise, extract it from the ROM zip: if the zip contains `payload.bin`, use [payload-dumper-go](https://github.com/ssut/payload-dumper-go): `payload-dumper-go -p boot payload.bin`.

Keep this file. It is also your way back.

> **Coming from Magisk?** Uninstall Magisk first: Magisk app > **Uninstall Magisk** > **Complete uninstall**. KernelSU uses the same `/data/adb/modules` folder and would run your Magisk modules. The flash script stops if the Magisk app is still installed.

## Step 4: test boot and flash

Download this repository (Code > Download ZIP) or clone it. Connect the phone, booted, with USB debugging on.

**Windows** (double-click works too, but then you can't pass the files):

```bat
cd flash
Flash-Kernel.bat -Image C:\path\to\Image -StockBoot C:\path\to\boot.img
```

**Linux / macOS**:

```bash
cd flash
chmod +x flash-kernel.sh
./flash-kernel.sh --image /path/to/Image --stock-boot /path/to/boot.img
```

The script:

1. checks that this is a venus, and reads the active slot and your `uname -r`;
2. checks the Image: arm64, contains KernelSU, SHA256 matches `Image.sha256`, and **exactly** your kernel version. If not, it stops;
3. checks the boot.img: original (not patched) and **exactly** your kernel version. If not, it stops;
4. builds `boot-ksu.img` on the phone: your ROM's ramdisk with the new kernel. It uses `magiskboot` from the official Magisk APK only as a tool to unpack and repack the boot image. Magisk itself is not installed, and root isn't needed for this;
5. **test boot** with `fastboot boot`: nothing is flashed. It installs the KernelSU Next manager, and you check that screen, touch, Wi-Fi and sound work and that KernelSU Next says **Working**. A normal reboot brings back your current boot;
6. only after you say yes and type `YES`: flashes `boot-ksu.img` to the active slot and checks that the new kernel is running.

Only want to check everything and build the image, without rebooting? Add `-PrepareOnly` (Windows) or `--prepare-only` (Linux/macOS).

## After flashing

- Open **KernelSU Next**. It should say **Working**.
- **Don't update the manager** past the version that matches your kernel (`v3.4.0-legacy` = manager **v3.4.0**). A newer manager says "Kernel update required". Using another `ksu_ref`? Pass the matching manager with `-ManagerUrl` / `--manager-url`.
- Install a **metamodule** (for example [meta-overlayfs](https://modules.kernelsu.org/module/meta-overlayfs)) before other modules. KernelSU Next v3.4 doesn't mount modules without one.
- Zygisk modules need **Zygisk Next** or **ReZygisk**.

## ROM updates

An OTA installs a new stock boot.img, so you lose root. If `uname -r` changed, build again with the new version, get the new stock boot.img, and run the flash script again.

### ROMs with KernelSU built in

Some ROMs now compile KernelSU Next into their own kernel. Evolution X does since 12.4 (kernel commit `b49845e1d267` and later): its source has `drivers/kernelsu`, manual hooks in `fs/` and `CONFIG_KSU=y` in `lahaina-qgki_defconfig`. For those builds:

- **Don't build or flash a kernel.** The ROM's own boot.img already gives you root, and your modules in `/data/adb` stay.
- The workflow stops right after cloning with **"KernelSU is already built in"**. Adding a second KernelSU on top can't work anyway: the ROM's hooks call functions of exactly its own KernelSU version, so the link fails with errors like `undefined symbol: ksu_init_rc_hook` or `ksu_handle_newfstat_ret`.
- Coming from a kernel built here: just install the update. After the reboot KernelSU Next should say **Working**. Keep a manager version that fits the kernel's KernelSU; if it says "Kernel update required", install the matching manager.

## Troubleshooting

| What you see | What it means | What to do |
|---|---|---|
| Build stops: commit not in repo | Wrong kernel source for your ROM | Find your ROM's real kernel source and branch. |
| Build stops: KernelSU is already built in | Your ROM's kernel has KernelSU Next itself | Nothing to build. Keep the ROM's own boot.img. |
| Link error `undefined symbol: ksu_init_rc_hook` / `ksu_handle_newfstat_ret` | Older workflow on a ROM with built-in KernelSU | Update your fork; you don't need a custom kernel. |
| Build stops: built kernel is X, your phone runs Y | Same source, but config or version string differ | Check `defconfig` and the branch. Do not flash. |
| Test boot: black screen or no touch | Kernel doesn't match your vendor modules | Hold power ~15 s to get back. Nothing was flashed. Check kernel_version and source. |
| Test boot works, KernelSU "Not integrated" | Hook doesn't work on this kernel | Use `hook_mode = kprobes`. |
| Manager says "Kernel update required" | Manager is newer than the kernel | Install the manager version that matches `ksu_ref`. |
| `fastboot devices` shows nothing | Driver (Windows) or udev rules (Linux) | See step 0. |

## Emergency restore

Phone doesn't boot after flashing? Put it in fastboot (power off, then hold **power + volume down**) and flash your stock boot.img back:

```bat
Flash-Kernel.bat -Restore C:\path\to\boot.img
```

```bash
./flash-kernel.sh --restore /path/to/boot.img
```

Or by hand: `fastboot flash boot_a boot.img` (or `boot_b`, whichever slot is active: `fastboot getvar current-slot`).

## Optional: check the module ABI yourself

The release contains `Module.symvers`. With Python 3 and your build's `vendor_boot.img`:

```bash
python3 tools/check_modversions.py --symvers Module.symvers --vendor-boot vendor_boot.img
```

`OK: all module CRCs match` means your vendor modules will load on this kernel. The test boot remains the real check.

## Credits

- [KernelSU Next](https://github.com/KernelSU-Next/KernelSU-Next)
- [Magisk](https://github.com/topjohnwu/Magisk), for `magiskboot`
- [Evolution X](https://github.com/Evolution-X-Devices/kernel_xiaomi_venus), [LineageOS](https://github.com/LineageOS/android_kernel_xiaomi_sm8350) and [crDroid](https://github.com/crdroidandroid/android_kernel_xiaomi_sm8350) for the kernel sources

## License

MIT, see [LICENSE](LICENSE). The kernel you build is GPL-2.0, like the Linux kernel and KernelSU Next.
