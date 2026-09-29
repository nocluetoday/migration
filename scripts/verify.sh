#!/bin/bash
# Post-update / post-reboot health check for the Pi-hole host.
# Run as root on the Pi-hole host:  PIHOLE_IP=<ip> bash verify.sh
# Prints a readable report. Exit 0 = all green, 1 = something needs a look.

fail=0
PIHOLE_IP=${PIHOLE_IP:?set PIHOLE_IP to the LAN address Pi-hole answers on}
ok()  { printf '  PASS  %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }
note(){ printf '  ----  %s\n' "$1"; }

echo "== host =="
note "kernel $(uname -r), booted $(uptime -s)"
newest=$(pacman -Ql linux-omarchy linux 2>/dev/null | grep -oE '/usr/lib/modules/[^/]+/' | sed 's#.*modules/##;s#/##' | sort -V | tail -1)
[[ -n $newest && $newest != "$(uname -r)" ]] && note "newest installed kernel is $newest — reboot pending" || ok "running the newest installed kernel"

echo "== systemd =="
f=$(systemctl --failed --no-pager --no-legend | wc -l)
(( f == 0 )) && ok "no failed units" || { bad "$f failed unit(s)"; systemctl --failed --no-pager --no-legend; }

echo "== packages =="
p=$(checkupdates 2>/dev/null | wc -l)
(( p == 0 )) && ok "no pending pacman updates" || bad "$p pending pacman updates"
orph=$(pacman -Qtdq 2>/dev/null | wc -l)
(( orph )) && note "$orph orphan package(s): $(pacman -Qtdq 2>/dev/null | tr '\n' ' ')"

echo "== omarchy user state =="
pend=$(runuser -u don -- env HOME=/home/don omarchy-migrate --pending 2>/dev/null | grep -c '\.sh')
(( pend == 0 )) && ok "no pending migrations" || bad "$pend pending migration(s)"
owned=$(find /home/don \( -user root -o -group root \) 2>/dev/null | wc -l)
(( owned == 0 )) && ok "no root-owned files in /home/don" || bad "$owned root-owned file(s) in /home/don"
[[ -f /home/don/.local/state/omarchy/reboot-required ]] && note "reboot-required flag is set" || ok "no stale reboot-required flag"

echo "== pi-hole =="
h=$(docker inspect pihole --format '{{.State.Health.Status}}' 2>/dev/null)
[[ $h == healthy ]] && ok "container healthy" || bad "container health: ${h:-not running}"
docker exec pihole pihole -v 2>/dev/null | sed 's/^/  ----  /'
g=$(docker exec pihole pihole-FTL sqlite3 /etc/pihole/gravity.db "select count(*) from gravity;" 2>/dev/null)
(( ${g:-0} > 10000 )) && ok "gravity has $g domains" || bad "gravity count looks wrong: ${g:-unreadable}"

echo "== dns on the LAN address =="
PIHOLE_IP=$PIHOLE_IP python3 - <<'PY' && ok "$PIHOLE_IP:53 answered" || bad "$PIHOLE_IP:53 did not answer"
import os, socket, struct, random, sys
q = b"".join(bytes([len(p)]) + p.encode() for p in "github.com".split(".")) + b"\x00\x00\x01\x00\x01"
pkt = struct.pack(">HHHHHH", random.randint(0, 65535), 0x0100, 1, 0, 0, 0) + q
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
try:
    s.sendto(pkt, (os.environ["PIHOLE_IP"], 53))
    d, _ = s.recvfrom(4096)
    sys.exit(0 if struct.unpack(">H", d[6:8])[0] > 0 else 1)
except Exception:
    sys.exit(1)
PY

echo
(( fail )) && { echo "VERIFY: something needs a look."; exit 1; }
echo "VERIFY: all green."
