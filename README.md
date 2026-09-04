boot one of 5 distros like a boss katchaw
# Ventoy Distro USB

Sets up a Ventoy multi-boot USB with 5 minimal Linux ISOs: Arch, Void, Artix, antiX, Alpine.

## Usage

```bash
chmod +x setup-ventoy-distros.sh
./setup-ventoy-distros.sh
```

You'll be asked to confirm your USB device path (e.g. `/dev/sdb`) before anything is written — nothing is touched automatically. Run `lsblk` first if you're unsure which device is your USB.

Re-running the script skips steps already done (Ventoy install, already-downloaded ISOs).
