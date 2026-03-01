# iCloud Activation Lock Bypass

Remove iCloud Activation Lock from 4 iPhones where the company Gmail / Apple ID password is lost.

## Your Devices

| # | Device | Chip | Exploit | Method |
|---|--------|------|---------|--------|
| 1 | iPhone 5 | A6 | checkm8 via ipwndfu | SSH ramdisk → patch filesystem |
| 2 | iPhone 6 | A8 | checkm8 via checkra1n | Jailbreak → SSH → patch filesystem |
| 3 | iPhone 6 | A8 | checkm8 via checkra1n | Jailbreak → SSH → patch filesystem |
| 4 | iPhone 6 Plus | A8 | checkm8 via checkra1n | Jailbreak → SSH → patch filesystem |

All 4 devices have checkm8-vulnerable chips. All can be bypassed for free with open-source tools.

## How It Works

The checkm8 exploit (CVE-2019-8900) is an unpatchable hardware bug in Apple's BootROM — the very first code that runs when an iPhone powers on. It's burned into the silicon at manufacturing; Apple cannot fix it with software updates.

The exploit targets a use-after-free vulnerability in the USB DFU stack. By sending malformed USB requests while the device is in DFU mode, we overflow a callback pointer and execute unsigned code at the BootROM level, bypassing Apple's entire secure boot chain.

Once we have code execution, we jailbreak the device (or boot an SSH ramdisk for iPhone 5), SSH into the filesystem, and:

1. Remove `Setup.app` (the activation lock screen UI)
2. Kill `mobileactivationd` (the daemon that phones home to Apple's activation servers)
3. Clear cached activation records
4. Write `ActivationState: Activated` to the lockdown plist
5. Mark the setup wizard as complete

The device then boots straight to the home screen.

**iPhone 5 vs iPhone 6/6 Plus difference:** checkra1n (the jailbreak tool built on checkm8) supports A8-class devices here. The iPhone 5's A6 chip requires the raw `ipwndfu` exploit followed by booting an SSH ramdisk (SSHRD_Script) to get filesystem access. Same end result, slightly different path.

## Requirements

- **Mac** (Intel or Apple Silicon)
- **USB-A to Lightning cable** (USB-C to Lightning is unreliable for exploit delivery)
- **~30 min per device**

## Quick Start

```bash
# 1. Install dependencies (one time)
bash setup.sh

  # 2. Plug in first device, run:
bash unlock.sh

  #    Optional: force model when starting from power-off/black screen
bash unlock.sh --model i6p

  #    Useful on stubborn i6/i6p units: let checkra1n guide DFU timing
bash unlock.sh --model i6p --checkra1n-mode tui

#    Optional: choose flow for that device (or ask per run)
bash unlock.sh --workflow reset

# 3. Or do all 4 back-to-back:
bash batch.sh

#    Optional controlled batch flow:
bash batch.sh --count 4 --models i6p,i6,i6,i5 --auto

#    Optional workflow for whole batch (all unlock / all reset)
bash batch.sh --count 4 --workflow reset

#    Unified/interactive controller (productivity dashboard):
bash manage.sh

#    Optional workflow defaults in manage
bash manage.sh --mode batch --workflow ask
bash manage.sh --mode queue
bash manage.sh --mode queue --queue-models i6p,i6,i6,i5 --queue-workflows unlock,reset,ask,reset
bash manage.sh --mode unlock --workflow reset
```

If setup fails with an Xcode license message, run once on the machine and rerun setup:

```bash
sudo xcodebuild -license accept
```

If setup still shows `checkra1n MISSING`:

```bash
brew install --cask checkra1n
softwareupdate --install-rosetta --agree-to-license  # on Apple Silicon, if needed
```

`manage.sh` now exposes an interactive controller with:

- quick status snapshot (`status`)
- session-wide defaults for batch count/models/workflow/auto-continue
- persisted session defaults (`~/.config/icloud-unlock/session-defaults.conf`)
- guided per-device workflow prompts (unlock or full factory reset)
- compact recent-run panel sourced from `unlock.log` in the dashboard
- fast presets for guided or full batch runs
- 4-device queue mode for preloaded runs (models + per-slot workflow)

`manage.sh` is designed as a lightweight productivity dashboard:

- defaults are retained between launches
- queue plans are shown in one place before execution
- recent run status is pulled from `unlock.log` so you can resume with context

## Factory Reset Mode

For devices that are not currently showing Activation Lock, or when a clean restore is preferred, use `reset` workflow.

- `bash unlock.sh --workflow reset` handles one device.
- `bash batch.sh --count 4 --models i6p,i6,i6,i5 --workflow reset` handles all devices with same reset mode.
- `bash manage.sh --mode batch --workflow reset` keeps one consistent mode across batch flows.

In reset mode, the script skips bypass tooling and instructs you to send the
device into Recovery/Restore and complete a normal Finder/iTunes erase flow.

## Files

```
icloud-bypass/
├── setup.sh       # Install deps (homebrew, libimobiledevice, checkra1n, ipwndfu, sshrd)
├── unlock.sh      # Main: detect → DFU → exploit → jailbreak → SSH → bypass → reboot
├── batch.sh       # Run unlock.sh for all 4 devices sequentially (model-aware sequencing)
├── manage.sh      # Interactive controller for setup/unlock/batch/reboot
├── reboot.sh      # Re-exploit a bypassed device that powered off
├── ipwndfu/       # (cloned by setup) iPhone 5 BootROM exploit
└── sshrd/         # (cloned by setup) SSH ramdisk for iPhone 5 filesystem access
```

## After Unlock

**What works:** Wi-Fi, Safari, App Store (sign in with your Apple ID), Camera, Bluetooth, all apps

**What may not work:** Cellular calls/SMS (varies), iMessage/FaceTime activation, Find My iPhone, Apple Pay

**Tethered limitation:** checkm8 runs from RAM. If the phone fully powers off, plug it back in and run `bash reboot.sh`. The bypass patches persist on the filesystem — you just need to re-exploit to boot past the lock. Keep the phones charged and this isn't an issue day-to-day.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Black screen before device detection | A black screen is expected in DFU prep. Keep the device connected and ensure a USB-A Lightning cable, then wait until script shows `DFU detected!` or `Using forced model...` if passed `--model`. |
| No device detected | Different cable (USB-A), different port, no hub |
| Goes to Recovery (instead of DFU) repeatedly on iPhone 6 / 6 Plus | Put the phone on **OFF/black screen first**. Then do: **POWER 3s, then POWER+HOME 10s, release POWER, keep HOME 5s** and release HOME only when the screen stays black. If it lands on Recovery again, pause 10s, start over from OFF. |
| checkra1n fails | Re-enter DFU, try `checkra1n -c -v --force-revert` |
| ipwndfu fails (iPhone 5) | USB-A cable required, retry multiple times, try `python2` |
| SSH won't connect | On device: open checkra1n → install Cydia → install OpenSSH |
| Still see Activation Lock after bypass | Re-enter DFU → `bash reboot.sh` |
| `mount: read-only filesystem` | Try `mount -uw /` or the SSHRD mount paths |
