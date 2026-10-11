#!/usr/bin/env bash
# rtl8812au-autofix.sh
# Builds several RTL8812AU driver candidates in parallel (with the kernel 7.x
# fixes we found applied automatically), test-loads each one against the real
# adapter, and installs the first one that produces a wireless interface.
#
# Usage:  bash rtl8812au-autofix.sh
# Needs:  internet in the VM (for the git clones), sudo, git, make, gcc,
#         linux-headers for the running kernel, adapter attached to the VM.

set -u

KVER=$(uname -r)
KSRC=/lib/modules/$KVER/build
WORK=${WORK:-$HOME/rtl8812au-autofix}
REPORT=$WORK/report.txt
CANDIDATES=(kali morrownr aircrack)   # test priority order

say()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mXX %s\033[0m\n' "$*"; exit 1; }

# ---------- preflight ----------
for c in git make gcc sudo; do command -v "$c" >/dev/null || die "missing tool: $c"; done
[ -d "$KSRC" ] || die "no headers for $KVER. Run: sudo apt install linux-headers-$KVER"
lsusb | grep -qi '0bda:8812' || warn "adapter 0bda:8812 not visible in lsusb; attach it from VirtualBox Devices > USB"
sudo -v || die "sudo needed"

mkdir -p "$WORK"
: > "$REPORT"
for n in "${CANDIDATES[@]}"; do rm -rf "${WORK:?}/$n"; done

# ---------- helpers ----------
wireless_ifaces() {
  local d
  for d in /sys/class/net/*; do
    { [ -d "$d/wireless" ] || [ -d "$d/phy80211" ]; } && basename "$d"
  done
}

reprobe_usb() {   # make the kernel re-bind the adapter to the newly loaded module
  local d
  for d in /sys/bus/usb/devices/*; do
    if [ "$(cat "$d/idVendor" 2>/dev/null)" = 0bda ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = 8812 ]; then
      basename "$d" | sudo tee /sys/bus/usb/drivers_probe >/dev/null
    fi
  done
}

patch_tree() {    # idempotent fixes for kernel 6.15+ / 7.x
  local dir=$1
  cat > "$dir/rtl_compat_timer.h" <<'EOF'
#ifndef RTL_COMPAT_TIMER_H
#define RTL_COMPAT_TIMER_H
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,15,0)
#ifndef del_timer_sync
#define del_timer_sync timer_delete_sync
#endif
#ifndef del_timer
#define del_timer timer_delete
#endif
#endif
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,16,0)
#ifndef from_timer
#define from_timer timer_container_of
#endif
#endif
#endif
EOF
  # EXTRA_CFLAGS is ignored by new kernels
  sed -i 's/EXTRA_CFLAGS/ccflags-y/g' "$dir/Makefile"
  # force-include the timer compat header in every file
  grep -q rtl_compat_timer "$dir/Makefile" ||
    sed -i "1i ccflags-y += -include $dir/rtl_compat_timer.h" "$dir/Makefile"
  # bridge-extension code uses PPPoE struct members hidden from kernel code
  sed -i 's/^CONFIG_BR_EXT *= *y/CONFIG_BR_EXT = n/' "$dir/Makefile"
  patch_cfg80211 "$dir"
}

# Kernel 7.x changed several cfg80211_ops callback signatures:
#  - key/station callbacks take struct wireless_dev * instead of struct net_device *
#  - set_wiphy_params / set_tx_power / get_tx_power gained an int radio_idx argument
# Instead of editing every function, add thin wrappers just before the ops table
# and #define the old names to the wrappers so the table picks them up.
patch_cfg80211() {
  local dir=$1 f wrap
  f=$(find "$dir" -name ioctl_cfg80211.c | head -1)
  [ -n "$f" ] || return 0
  grep -q RTW_KERNEL7_CFG_WRAP "$f" && return 0
  grep -q '^static struct cfg80211_ops rtw_cfg80211_ops = {' "$f" || return 0
  wrap=$(mktemp)
  cat > "$wrap" <<'EOF'
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7,0,0)
/* RTW_KERNEL7_CFG_WRAP */
static int rtw7_add_key(struct wiphy *wiphy, struct wireless_dev *wdev, int link_id,
	u8 key_index, bool pairwise, const u8 *mac_addr, struct key_params *params)
{
	if (!wdev->netdev) return -ENODEV;
	return cfg80211_rtw_add_key(wiphy, wdev->netdev, link_id, key_index, pairwise, mac_addr, params);
}
static int rtw7_get_key(struct wiphy *wiphy, struct wireless_dev *wdev, int link_id,
	u8 key_index, bool pairwise, const u8 *mac_addr, void *cookie,
	void (*callback)(void *cookie, struct key_params *))
{
	if (!wdev->netdev) return -ENODEV;
	return cfg80211_rtw_get_key(wiphy, wdev->netdev, link_id, key_index, pairwise, mac_addr, cookie, callback);
}
static int rtw7_del_key(struct wiphy *wiphy, struct wireless_dev *wdev, int link_id,
	u8 key_index, bool pairwise, const u8 *mac_addr)
{
	if (!wdev->netdev) return -ENODEV;
	return cfg80211_rtw_del_key(wiphy, wdev->netdev, link_id, key_index, pairwise, mac_addr);
}
static int rtw7_set_default_mgmt_key(struct wiphy *wiphy, struct wireless_dev *wdev,
	int link_id, u8 key_index)
{
	if (!wdev->netdev) return -ENODEV;
	return cfg80211_rtw_set_default_mgmt_key(wiphy, wdev->netdev, link_id, key_index);
}
static int rtw7_get_station(struct wiphy *wiphy, struct wireless_dev *wdev,
	const u8 *mac, struct station_info *sinfo)
{
	if (!wdev->netdev) return -ENODEV;
	return cfg80211_rtw_get_station(wiphy, wdev->netdev, mac, sinfo);
}
#ifdef CONFIG_AP_MODE
static int rtw7_add_station(struct wiphy *wiphy, struct wireless_dev *wdev,
	const u8 *mac, struct station_parameters *params)
{
	if (!wdev->netdev) return -ENODEV;
	return cfg80211_rtw_add_station(wiphy, wdev->netdev, mac, params);
}
static int rtw7_change_station(struct wiphy *wiphy, struct wireless_dev *wdev,
	const u8 *mac, struct station_parameters *params)
{
	if (!wdev->netdev) return -ENODEV;
	return cfg80211_rtw_change_station(wiphy, wdev->netdev, mac, params);
}
static int rtw7_del_station(struct wiphy *wiphy, struct wireless_dev *wdev,
	struct station_del_parameters *params)
{
	if (!wdev->netdev) return -ENODEV;
	return cfg80211_rtw_del_station(wiphy, wdev->netdev, params);
}
#define cfg80211_rtw_add_station rtw7_add_station
#define cfg80211_rtw_change_station rtw7_change_station
#define cfg80211_rtw_del_station rtw7_del_station
#endif
#define cfg80211_rtw_add_key rtw7_add_key
#define cfg80211_rtw_get_key rtw7_get_key
#define cfg80211_rtw_del_key rtw7_del_key
#define cfg80211_rtw_set_default_mgmt_key rtw7_set_default_mgmt_key
#define cfg80211_rtw_get_station rtw7_get_station
#endif

EOF
  # radio_idx wrappers, only for sources that don't already handle radio_idx (morrownr does)
  if ! grep -q radio_idx "$f"; then
    cat >> "$wrap" <<'EOF'
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7,0,0)
static int rtw7_set_wiphy_params(struct wiphy *wiphy, int radio_idx, u32 changed)
{
	return cfg80211_rtw_set_wiphy_params(wiphy, changed);
}
static int rtw7_set_txpower(struct wiphy *wiphy, struct wireless_dev *wdev, int radio_idx,
	enum nl80211_tx_power_setting type, int mbm)
{
	return cfg80211_rtw_set_txpower(wiphy, wdev, type, mbm);
}
static int rtw7_get_txpower(struct wiphy *wiphy, struct wireless_dev *wdev, int radio_idx,
	unsigned int link_id, int *dbm)
{
	return cfg80211_rtw_get_txpower(wiphy, wdev, link_id, dbm);
}
#define cfg80211_rtw_set_wiphy_params rtw7_set_wiphy_params
#define cfg80211_rtw_set_txpower rtw7_set_txpower
#define cfg80211_rtw_get_txpower rtw7_get_txpower
#endif

EOF
  fi
  # dump_station: take the function name from the ops table instead of guessing it
  local dn
  dn=$(sed -n 's/.*\.dump_station *= *\([A-Za-z0-9_]*\).*/\1/p' "$f" | head -1)
  if [ -n "$dn" ]; then
    cat >> "$wrap" <<EOF
#if LINUX_VERSION_CODE >= KERNEL_VERSION(7,0,0)
static int rtw7_dump_station(struct wiphy *wiphy, struct wireless_dev *wdev, int idx,
	u8 *mac, struct station_info *sinfo)
{
	if (!wdev->netdev) return -ENODEV;
	return $dn(wiphy, wdev->netdev, idx, mac, sinfo);
}
#define $dn rtw7_dump_station
#endif

EOF
  fi
  # cfg80211_new_sta / cfg80211_del_sta now take a wireless_dev: convert at the call sites
  if ! grep -q RTW_KERNEL7_STA_MACROS "$f"; then
    sed -i '0,/^#include <drv_types.h>/s//&\n\n\/* RTW_KERNEL7_STA_MACROS *\/\n#include <linux\/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(7,0,0)\n#define cfg80211_new_sta(d, ...) cfg80211_new_sta((d)->ieee80211_ptr, __VA_ARGS__)\n#define cfg80211_del_sta(d, ...) cfg80211_del_sta((d)->ieee80211_ptr, __VA_ARGS__)\n#endif/' "$f"
  fi
  awk -v w="$wrap" '/^static struct cfg80211_ops rtw_cfg80211_ops = \{/ && !done { while ((getline l < w) > 0) print l; done=1 } { print }' "$f" > "$f.new" && mv "$f.new" "$f"
  rm -f "$wrap"
}

# ---------- 1. collect sources ----------
say "Fetching candidate sources"
kdir=$(ls -d /usr/src/realtek-rtl88xxau-* 2>/dev/null | head -1)
[ -n "$kdir" ] && cp -r "$kdir" "$WORK/kali" || warn "Kali package source not found, skipping 'kali'"

git clone -q --depth 1 https://github.com/morrownr/8812au-20210820.git "$WORK/morrownr" 2>"$WORK/morrownr.clone.log" &
git clone -q --depth 1 https://github.com/aircrack-ng/rtl8812au.git    "$WORK/aircrack" 2>"$WORK/aircrack.clone.log" &
wait

READY=()
for n in "${CANDIDATES[@]}"; do
  if [ -f "$WORK/$n/Makefile" ]; then READY+=("$n"); else warn "$n unavailable (see $WORK/$n.clone.log)"; fi
done
[ "${#READY[@]}" -gt 0 ] || die "no candidate sources available"

# ---------- 2. build everything in parallel ----------
say "Building ${READY[*]} in parallel for $KVER (a few minutes)"
for n in "${READY[@]}"; do
  patch_tree "$WORK/$n"
  ( cd "$WORK/$n" && make -k -j2 KVER="$KVER" KSRC="$KSRC" CONFIG_BR_EXT=n >"$WORK/$n.build.log" 2>&1 ) &
done
wait

# ---------- 3. test each build against the real adapter ----------
sudo modprobe cfg80211 2>/dev/null
WINNER=""

for n in "${READY[@]}"; do
  say "Testing: $n"
  ko=$(find "$WORK/$n" -name '*.ko' | head -1)
  errs=$(grep -c 'error:' "$WORK/$n.build.log" || true)

  if [ -z "$ko" ]; then
    echo "$n: BUILD FAILED ($errs errors)" | tee -a "$REPORT"
    grep 'error:' "$WORK/$n.build.log" | sed 's|^.*/||' | sort -u | head -8 | tee -a "$REPORT"
    continue
  fi

  modname=$(modinfo -F name "$ko")
  sudo rmmod "$modname" 2>/dev/null
  before=$(wireless_ifaces | sort)

  if ! sudo insmod "$ko" 2>"$WORK/$n.insmod.log"; then
    echo "$n: built OK but insmod failed: $(cat "$WORK/$n.insmod.log")" | tee -a "$REPORT"
    sudo dmesg | tail -5 | tee -a "$REPORT"
    continue
  fi

  reprobe_usb
  new=""
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 1
    new=$(comm -13 <(echo "$before") <(wireless_ifaces | sort))
    [ -n "$new" ] && break
  done

  if [ -n "$new" ]; then
    echo "$n: WORKS, new interface: $new" | tee -a "$REPORT"
    sudo install -D -m644 "$ko" "/lib/modules/$KVER/updates/$modname.ko"
    sudo depmod -a
    WINNER=$n
    echo "$n" > "$WORK/WINNER"
    break
  else
    echo "$n: built and loaded but no wireless interface appeared" | tee -a "$REPORT"
    sudo dmesg | tail -8 | tee -a "$REPORT"
    sudo rmmod "$modname" 2>/dev/null
  fi
done

# ---------- 4. verdict ----------
say "Result"
if [ -n "$WINNER" ]; then
  echo "Kept: $WINNER (installed to /lib/modules/$KVER/updates/, loads automatically on plug-in)"
  ip -br link
  echo "Note: it is tied to kernel $KVER. After a kernel upgrade, run this script again."
else
  echo "No candidate worked. Full report: $REPORT"
  echo "Send me that file (and $WORK/*.build.log if needed) and I'll tell you what to patch."
  echo "Fallback: boot an older kernel. Available:"
  apt list 'linux-image-*-amd64' 2>/dev/null | grep -v dbg | head
fi