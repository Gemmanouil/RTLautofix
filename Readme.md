# rtl8812au-autofix

A single bash script that gets an **RTL8812AU** USB Wi-Fi adapter (`0bda:8812`) working on a Kali VM running a very new kernel (developed against `7.1.5+kali-amd64` in VirtualBox).

The Kali `realtek-rtl88xxau-dkms` package is too old for recent kernels and fails to build. This script builds several driver sources in parallel, applies the kernel-compatibility fixes automatically, test-loads each one against the real adapter, and installs the first one that produces a wireless interface.

## Why the stock driver fails

These are the problems the script patches around:

| Symptom | Cause | Fix applied |
|---|---|---|
| `dkms status` shows `added`, never `installed` | `BUILD_EXCLUSIVE` in `dkms.conf` rejects the kernel | The script builds directly with `make`, bypassing DKMS |
| `drv_types.h: No such file or directory` | New kernels ignore `EXTRA_CFLAGS` | Replaced with `ccflags-y` |
| `from_timer` / `del_timer_sync` undeclared | Renamed in kernel 6.15/6.16 | Compat header maps them to `timer_container_of` / `timer_delete_sync` |
| `struct pppoe_hdr has no member named 'tag'` | PPPoE struct members are hidden from kernel code | `CONFIG_BR_EXT = n` (bridge extension, not needed for monitor mode or injection) |
| `ioctl_cfg80211.c: initialization ... from incompatible pointer type` | Kernel 7.x changed `cfg80211_ops` callback signatures (`wireless_dev` instead of `net_device`, new `radio_idx` argument) | Thin wrapper functions inserted before the ops table; the old names are `#define`d to the wrappers (applies on kernel 7.0+) |

## Requirements

- Kali (or Debian-based) VM with the adapter attached (VirtualBox: *Devices → USB*)
- Internet access inside the VM (for the git clones)
- `git`, `make`, `gcc`, `sudo`
- Headers for the running kernel:
  ```bash
  sudo apt install linux-headers-$(uname -r)
  ```

## Usage

```bash
bash rtl8812au-autofix.sh
```

Optional: change the working directory (default `~/rtl8812au-autofix`):

```bash
WORK=/tmp/rtl bash rtl8812au-autofix.sh
```

## What it does

1. **Preflight:** checks for tools, kernel headers, and the adapter in `lsusb`.
2. **Collects candidates:**
   - `kali`: the installed Kali package source in `/usr/src/realtek-rtl88xxau-*`
   - `morrownr`: `morrownr/8812au-20210820` (latest)
   - `aircrack`: `aircrack-ng/rtl8812au` (latest)
3. **Patches** each copy with the fixes above (safe to re-run; nothing is applied twice).
4. **Builds** all candidates in parallel with `make -k`, so every candidate reports all of its errors.
5. **Tests** each successful build in priority order: loads it with `insmod`, re-binds the adapter, and waits for a new wireless interface.
6. **Keeps the first working one:** installs it to `/lib/modules/<kernel>/updates/` and runs `depmod`, so it loads automatically when the adapter is plugged in. Candidates that fail are unloaded and nothing from them is installed.

## Output

| File | Contents |
|---|---|
| `~/rtl8812au-autofix/report.txt` | Summary of each candidate: build failure, load failure, or success |
| `~/rtl8812au-autofix/<name>.build.log` | Full compiler output per candidate |
| `~/rtl8812au-autofix/<name>.insmod.log` | Error from loading the module, if any |
| `~/rtl8812au-autofix/WINNER` | Name of the candidate that was installed |

## After it works

```bash
ip -br link          # should list a wlan0 / wlx... interface
sudo ip link set wlan0 down
sudo iw dev wlan0 set type monitor
sudo ip link set wlan0 up
```

Replace `wlan0` with the interface name shown by `ip -br link`.

## Limitations

- **Kernel-specific install.** The module is built for one kernel. After a kernel upgrade, run the script again.
- **It only automates known fixes.** If a candidate fails on a different kernel API change, it is reported as failed. Check `report.txt` and the build log for the first `error:` lines.
- **Upstream may not support your kernel yet.** If every candidate fails, boot an older kernel from GRUB's *Advanced options* (the script lists available `linux-image` packages), or run Kali on the host or a live USB.
- **Module signing / Secure Boot.** If `insmod` fails with a "Key was rejected" message, the kernel enforces module signatures. Disable Secure Boot in the VM, or sign the module.
- **VirtualBox only.** USB passthrough must already work: `lsusb` in the VM must show `0bda:8812`. The Extension Pack and a USB 3.0 (xHCI) controller are usually required.

## Troubleshooting

| Problem | Try |
|---|---|
| `no headers for <kernel>` | `sudo apt update && sudo apt full-upgrade`, reboot, retry |
| Adapter not in `lsusb` | Reattach from *Devices → USB*; unplug and replug; use a direct port |
| Built and loaded, but no interface | `sudo dmesg \| tail -30`; check that another driver (such as `8821au`) is not claiming the adapter |
| Clone fails | Check VM networking: `ping github.com` |

## Cleanup

To remove the installed module:

```bash
sudo rm /lib/modules/$(uname -r)/updates/88XXau.ko   # use the name in $WORK/WINNER's build
sudo depmod -a
rm -rf ~/rtl8812au-autofix
```

The module filename depends on the winning candidate. Check with `ls /lib/modules/$(uname -r)/updates/`.