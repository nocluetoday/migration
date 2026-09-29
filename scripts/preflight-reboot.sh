#!/bin/bash
# Pre-reboot safety check for the Pi-hole host.
# Run as root on the Pi-hole host:  bash preflight-reboot.sh
#
# Root is LUKS-encrypted on hardware with no TPM. It boots unattended only because a
# keyfile is embedded in the UKI and referenced by cryptkey= on the kernel cmdline.
# A kernel update rebuilds the UKI, so both facts must be re-verified every time.
# Exit 0 = safe to reboot. Any other exit = do not reboot, report to Don.

fail=0
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
note() { printf '  ----  %s\n' "$1"; }

echo "== LUKS keyfile =="
keyfile=/etc/cryptsetup-keys.d/root.key
cryptdev=$(sed -n 's/.*cryptdevice=\([^:]*\):.*/\1/p' /proc/cmdline)
if [[ ! -r $keyfile ]]; then
  bad "keyfile $keyfile missing"
elif [[ -z $cryptdev ]]; then
  bad "could not parse cryptdevice= from /proc/cmdline"
elif cryptsetup open --test-passphrase --key-file "$keyfile" "/dev/disk/by-partuuid/${cryptdev#PARTUUID=}" 2>/dev/null; then
  ok "keyfile unlocks $cryptdev"
else
  bad "keyfile does NOT unlock $cryptdev"
fi

echo "== keyfile embedded in every UKI =="
shopt -s nullglob
ukis=(/boot/EFI/Linux/*.efi)
(( ${#ukis[@]} )) || bad "no UKIs found under /boot/EFI/Linux"
for uki in "${ukis[@]}"; do
  if lsinitcpio "$uki" 2>/dev/null | grep -q 'cryptsetup-keys.d/root.key'; then
    ok "$(basename "$uki")"
  else
    bad "$(basename "$uki") has no embedded keyfile"
  fi
done

echo "== cryptkey= on auto-bootable kernel entries =="
# /boot/limine.conf nests Snapper snapshot entries deeper than the real kernel
# entries. Only the shallow ones can be reached by BOOT_ORDER without a human at
# the console, so only those have to carry the keyfile reference.
mapfile -t primary < <(grep -E '^  cmdline:' /boot/limine.conf 2>/dev/null)
(( ${#primary[@]} )) || bad "no primary kernel entries in /boot/limine.conf"
for line in "${primary[@]}"; do
  [[ $line == *cryptkey=* ]] && ok "primary entry carries cryptkey=" || bad "primary entry MISSING cryptkey="
done
snapmiss=$(grep -E '^ {3,}cmdline:' /boot/limine.conf 2>/dev/null | grep -vc 'cryptkey=')
(( snapmiss )) && note "$snapmiss old snapshot entry/entries predate the keyfile and would ask for the passphrase if booted by hand — not a blocker"

echo "== boot order keeps a fallback =="
bo=$(grep -h '^BOOT_ORDER' /etc/default/limine 2>/dev/null)
[[ $bo == *fallback* && $bo == *Snapshots* ]] && ok "$bo" || bad "BOOT_ORDER lacks fallback/Snapshots: $bo"
kernels=$(pacman -Qq 2>/dev/null | grep -cE '^linux(-omarchy|-lts|-t2)?$')
(( kernels >= 2 )) && ok "$kernels kernels installed" || bad "only $kernels kernel installed — no escape hatch"

echo "== services enabled at boot =="
for u in tailscaled docker pihole-ensure.timer pihole-autoupdate.timer; do
  [[ $(systemctl is-enabled "$u" 2>/dev/null) == enabled ]] && ok "$u" || bad "$u not enabled"
done

echo
if (( fail )); then
  echo "PREFLIGHT FAILED — do not reboot."
  exit 1
fi
echo "PREFLIGHT OK — safe to reboot."
