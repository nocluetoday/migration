# OptiPlex 7070 Micro migration

You are Claude Code running on a newly installed home server. This file is the plan. You have no other context from the conversation that produced it, so read all of it before doing anything.

## Goal

Make this machine the always-on Linux box for the house. It replaces an old Intel MacBook running Omarchy (the "old box"), which runs the household Pi-hole today.

**The current Pi-hole setup works very well. The job is to copy it exactly, not to redesign it.** Where this doc and the old box disagree, the old box wins: copy what it does, and note the difference in `STATUS.md`.

Don wants this done **agentically, in one evening, with as little input from him as possible.** Work through the phases without stopping, except at the points marked **STOP** below. When you need him, give him one short message with the exact action and why.

## This repo is public

Nothing private gets committed. That includes:

- IP addresses, MAC addresses, hostnames of other machines, tailnet names
- Passwords, API keys, Tailscale auth keys, LUKS passphrases, keyfiles, or recovery keys
- Pi-hole Teleporter exports or volume copies (they contain local DNS records and client lists)
- Compose files with secrets inline. Put secrets and machine-specific values in `.env`. `.env` and `local/` are already in `.gitignore`.

Machine-specific values go in `local/` or `.env`. Run `git status` before every commit and check that no such file is staged. Placeholders used below: `<NEW_IP>` (this box's current LAN address), `<PIHOLE_IP>` (the LAN address the old box serves DNS on), `<OLD_BOX>` (the old box's Tailscale IP).

## Hardware

- Dell OptiPlex 7070 Micro, i5-9500T (6 cores, 35W), 16GB RAM, 256GB NVMe
- No PCIe slot, no Thunderbolt. Front USB-C is data only.
- Video: two DisplayPort on the rear
- Wired Ethernet to a UniFi gateway
- Has a TPM 2.0 chip (the old box has none)

## Network context

- UniFi gateway handles DHCP. This box has a DHCP reservation at `<NEW_IP>`.
- Every client on the network, probably including the IoT VLAN, uses `<PIHOLE_IP>` for DNS. **The cutover moves `<PIHOLE_IP>` from the old box to this box.** No DNS setting changes anywhere. Don chose this on 2026-09-29.
- There is an IoT VLAN with its own filtering rules. **Do not change anything about it.** The IP swap is designed so that it needs no change.
- Don uses Tailscale. The Tailnet DNS settings may point at the old box's Tailscale IP. Check this (Phase 3) because the IP swap does not cover it.
- Don's main machine is an M5 Max MacBook Pro named Gus. It runs local LLM inference and has the UniFi MCP server. This box does not need a GPU and is not for inference.

## What Don does before you start

Verify each of these. If one is missing, tell Don the exact command and wait.

- BIOS updated, SATA mode set to AHCI, Secure Boot off, AC Recovery = Power On, TPM enabled
- Omarchy installed from the ISO with full-disk LUKS encryption
- Wired Ethernet with a DHCP reservation
- Claude Code installed and logged in
- `tailscale up --ssh` done, and `tailscale ssh root@<OLD_BOX> true` works from this box. This is your path to the old box. Don gives you the `<OLD_BOX>` IP; store it in `local/hosts.env`.
- **Temporary passwordless sudo**, so you can work without asking him for each root command:

      echo 'don ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/99-migration-temp && sudo chmod 440 /etc/sudoers.d/99-migration-temp

  You remove this file in the final phase. Never leave it in place.

Checks you can run: `lsblk -f` (expect a `crypto_LUKS` partition on the NVMe), `ip -4 addr`, `sudo dmidecode -s bios-version`, `ls /dev/tpm*`, `sudo -n true`.

## How to work

- Keep a checklist in `STATUS.md` (safe for a public repo: no IPs or secrets) and update it as you finish items. Commit and push it at the end of each phase.
- Before changing a config file, copy it to `<file>.bak` in the same directory.
- If what you find on either machine contradicts this doc, and the difference changes what you would do, stop and tell Don.
- The old box is live household DNS. **On the old box you only read, except in the cutover.** Reading includes `docker inspect`, `cat`, `systemctl status`, and making a copy of the Pi-hole volume. Never stop, restart, or reconfigure its Pi-hole, Docker, network, or timers before the cutover.
- Tools on the old box: `dig` is not installed on the host (use `docker exec pihole dig ...`). `sqlite3` is not in the container (use `pihole-FTL sqlite3`). For `tailscale ssh` with redirected stdin, use the IP, not the MagicDNS name.
- Long steps: notify Don when a phase finishes or when you are blocked. He may not be watching.

## Ask first (STOP points)

Get Don's explicit yes in the current session before:

- The first change to disk encryption, the initramfs (`mkinitcpio`), or the bootloader. Present the plan from Phase 4 once; one yes covers that phase.
- The cutover (Phase 6). One yes covers the whole runbook, including the rollback if needed.
- Anything on the IoT VLAN
- Wiping the old box
- Deleting files outside this repo
- Opening firewall ports beyond those listed in this doc

You do not need to ask before reboots of **this** box before the cutover. Nothing depends on it yet.

## Phase 1: base setup

1. Install and enable SSH: `openssh`, `sshd.service`. Key-only auth; turn off password auth in `/etc/ssh/sshd_config`. Copy the authorized key(s) from the old box's `~/.ssh/authorized_keys` so Gus can log in. Check that `ssh don@<NEW_IP>` from Gus works before you turn off password auth. If you cannot test it, leave password auth on and list it as open.
2. Tailscale: already up (see above). Make sure `tailscaled` is enabled.
3. Stop the machine from ever suspending. Check hypridle config (`~/.config/hypr/hypridle.conf`) and `systemd-logind` settings. Screen lock and display off are fine; suspend and hibernate are not. Copy what the old box does if it already solved this.
4. Check ufw: `sudo ufw status verbose`. Record the defaults in `STATUS.md`. Compare with the old box's ufw rules and record the differences.
5. Install Docker if it isn't there (`docker --version`). Enable `docker.service`. Add Don's user to the `docker` group.
6. Migrate Claude Code config from the old box: copy `~/.claude/skills/`, `~/.claude/CLAUDE.md`, and `~/.claude/settings.json`. Do not copy the credentials file. Don has a `unifi-management` skill that should come across.

Done when: `systemctl is-enabled sshd tailscaled docker` all return enabled, and there is no suspend path left in the config.

## Phase 2: inventory the old box (read only)

Record everything the old box does, so nothing is lost. Save the raw output in `local/old-box/` (gitignored). Put a summary without addresses or secrets in `STATUS.md`.

1. Services: `systemctl list-units --type=service --state=running`, `systemctl list-timers --all`, user units (`systemctl --user list-units` as `don`), `crontab -l` for root and `don`, `docker ps -a`.
2. Pi-hole container, in full: `docker inspect pihole`. Record image, env vars, port bindings (which host IP and ports), network mode, volumes, restart policy, DNS options, capabilities, health check.
3. How the container is started: look for a compose file, a `docker run` in `/usr/local/bin/pihole-*`, and systemd units. Known pieces to copy:
   - `/usr/local/bin/pihole-autoupdate.sh` with `pihole-autoupdate.service` and `pihole-autoupdate.timer` (weekly; pulls a new image, health-checks it, rolls back if unhealthy)
   - `pihole-ensure.service` and `pihole-ensure.timer` (every 5 minutes; relaunches the container if it is missing)
   - Any `/usr/local/bin/pihole-*` script, and the sudoers entries in `/etc/sudoers.d/` that reference them
4. Host DNS: `/etc/systemd/resolved.conf` and `resolved.conf.d/`, what holds port 53 (`ss -tulpn | grep :53`), `/etc/resolv.conf`.
5. Network: how the old box gets `<PIHOLE_IP>`. Is it a DHCP reservation, or a static address in NetworkManager / systemd-networkd / iwd? This decides the cutover steps.
6. Unattended boot: `/etc/mkinitcpio.conf` (HOOKS and FILES), `/etc/mkinitcpio.conf.d/`, `/etc/default/limine`, `/etc/crypttab`, and whether `/etc/cryptsetup-keys.d/root.key` exists. **Never copy the keyfile itself.** You make a new one here.
7. Firewall: `ufw status verbose`, and `iptables -S | grep -i docker` to see whether Docker bypasses ufw.
8. Pi-hole state for later comparison: `docker exec pihole pihole -v`, gravity count (`pihole-FTL sqlite3 /etc/pihole/gravity.db "select count(*) from gravity;"`), adlists, local DNS records count, groups, clients count.

Done when: `STATUS.md` has a table of everything the old box runs, and each item is marked *copy*, *not needed*, or *ask Don*.

## Phase 3: Tailscale DNS check (read only)

Run `tailscale dns status` on this box. If the tailnet's global nameserver is the old box's Tailscale IP, Don must change it in the Tailscale admin console after the cutover. Add that to the cutover list. Do not change it yourself.

## Phase 4: unattended boot

The problem: Omarchy asks for the LUKS passphrase at every boot. After a power outage, DNS for the whole house stays down until someone types it. This must work before Pi-hole moves here.

**The old box already solves this**, and the method is tested: a keyfile at `/etc/cryptsetup-keys.d/root.key`, added to the LUKS header as an extra keyslot, embedded in the UKI through `FILES` in mkinitcpio, and referenced by `cryptkey=` on the kernel command line in `/etc/default/limine`. It uses the `encrypt` hook with `cryptdevice=`.

Investigate first, with no changes:

- `grep ^HOOKS /etc/mkinitcpio.conf`: `sd-encrypt` (systemd) or `encrypt` (busybox)?
- Bootloader (expect Limine and UKIs under `/boot/EFI/Linux/`) and where the kernel command line is set
- `sudo systemd-cryptenroll /dev/<luks-partition>` to list current keyslots
- `ls /dev/tpm*`

**STOP.** Present the plan to Don in five lines or fewer and get a yes. Default recommendation:

1. **Keyfile in the UKI, same as the old box** (recommended). Proven on this hardware family and this OS. If this box uses `sd-encrypt`, the syntax differs (`rd.luks.key=` instead of `cryptkey=`); say so.
2. **TPM2 auto-unlock** (`systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7`). Needs `sd-encrypt`. More secure against a stolen drive, but it is new on Don's machines and a firmware update can break the unlock.

Rules for either option:

- Never remove the existing passphrase keyslot.
- Generate a recovery key (`systemd-cryptenroll --recovery-key`). Show it to Don once so he can put it in his password manager. It never goes into this repo or any file on disk.
- Keep a fallback boot entry. `BOOT_ORDER` in `/etc/default/limine` must include `*fallback` and `Snapshots`, as on the old box.

After the change, run `sudo bash scripts/preflight-reboot.sh` (it is written for the keyfile method; adapt it if you chose TPM). Then reboot this box with `sudo systemctl reboot`. Claude Code will stop. Before you reboot, write in `STATUS.md` exactly where to resume. When the box is back, Don restarts Claude Code; confirm that the box reached the network without input (check `journalctl -b` for the unlock and `uptime`).

Done when: the box reboots to a working network with no keyboard input. Don does the full power-cut test (pull the plug, wait, plug back in) later; it is not a blocker for tonight.

## Phase 5: Pi-hole, as a copy of the old one

Build Pi-hole here so that it matches the old box. Test it on `<NEW_IP>`. The old box keeps serving the house the whole time.

1. **Port 53 on the host.** Check what holds it: `sudo ss -tulpn | grep :53`. Do what the old box does. If systemd-resolved's stub listener conflicts, set `DNSStubListener=no` in `/etc/systemd/resolved.conf` and restart resolved. Make sure the host itself still resolves afterward.
2. **Container config.** Write `pihole/compose.yaml` to match the old container from Phase 2: same image tag, same env vars, same ports, same volume path (`/etc/pihole`), `restart: unless-stopped`. Secrets and the admin password go in `.env`. **Bind the published ports to `${PIHOLE_BIND_IP}` from `.env`**, the same way the old box binds to its LAN IP. Set it to `<NEW_IP>` now; the cutover changes it to `<PIHOLE_IP>`. If the old box used `docker run` instead of compose, use compose here anyway, and keep the settings the same. Record any setting that you could not copy.
3. **Data.** Copy the old box's Pi-hole volume with the container still running. Example (adjust volume name from Phase 2):

       tailscale ssh root@<OLD_BOX> 'docker run --rm -v pihole_etc:/v:ro alpine tar -C /v -czf - .' > local/pihole_etc.tgz

   Restore it into this box's volume before the first start. Then check the databases: `pihole-FTL sqlite3 /etc/pihole/gravity.db "PRAGMA integrity_check;"`. If `gravity.db` fails, run `pihole -g` to rebuild it. Also export a Teleporter file from the old box as a second backup in `local/`.
4. **Helper scripts and timers.** Copy `pihole-autoupdate.sh`, `pihole-ensure`, their units and timers, and their sudoers entries. Edit them only where a path or name must change (for example, compose instead of `docker run`). Enable the timers.
5. **Firewall.** Allow 53/tcp, 53/udp, and the web UI port from the LAN only, the same as the old box. Docker-published ports can bypass ufw because Docker writes its own iptables rules. Check whether that is happening here, compare with the old box, and report it.
6. **Test** on `<NEW_IP>`:
   - `dig @<NEW_IP> example.com` resolves (from this box, and from the old box: `tailscale ssh root@<OLD_BOX> 'docker exec pihole dig @<NEW_IP> example.com'`)
   - `dig @<NEW_IP> doubleclick.net` returns the same blocked answer as the old box gives
   - Gravity count, adlist count, local DNS record count, groups, and clients match the old box
   - Upstream DNS servers and DNSSEC settings match
   - Admin web UI loads and the password from `.env` works
   - `sudo PIHOLE_IP=<NEW_IP> bash scripts/verify.sh` is all green except for items that only make sense after the cutover
7. **Reboot test.** Reboot this box once more. Pi-hole must come back with no manual step. Re-run the tests.

Done when every test passes. Write the results in `STATUS.md`, including every difference from the old box.

## Phase 6: cutover by IP swap

**STOP.** Tell Don Pi-hole is ready, show the test results, and ask for the yes. After the yes, run all steps without stopping, unless a check fails.

Expected DNS outage: one to three minutes. Clients retry, so most people will not notice. Do it when nobody is on a video call.

The goal: this box answers on `<PIHOLE_IP>`; the old box moves to a different address and stays on as a rollback.

**Who changes UniFi:** you do not have the UniFi MCP on this box. If Phase 2 showed the addresses come from DHCP reservations, the UniFi part is done by Claude on Gus (it has the `unifi-management` skill) or by Don in the UniFi app. Write the exact change for them: which reservation moves to which address. If the old box uses a static address set on the host, you can do the whole swap yourself over Tailscale SSH with no UniFi change, and update the UniFi reservations afterward only to match.

Steps (DHCP reservation case):

1. Pre-checks: the new Pi-hole passes all Phase 5 tests right now. The old box is reachable by `tailscale ssh`. Tailscale does not depend on the LAN address, so you keep access to both boxes through the swap.
2. **Safety net on the old box.** Before you change it, schedule an automatic revert that you cancel after success. For example, a `systemd-run --on-active=15min` unit that restores the old network config and restarts Pi-hole. Record the unit name.
3. UniFi: move the old box's reservation to a free address, and move this box's reservation to `<PIHOLE_IP>`. (Done by Claude on Gus or Don. Wait for confirmation.)
4. Old box: renew DHCP so it leaves `<PIHOLE_IP>`. Confirm with `ip -br addr`. Its Pi-hole stops answering on the LAN here; that is expected. Do not stop the container.
5. This box: renew DHCP so it takes `<PIHOLE_IP>`. Confirm with `ip -br addr`. Send a gratuitous ARP (`arping -U -I <iface> <PIHOLE_IP>`) so clients update their ARP caches.
6. Set `PIHOLE_BIND_IP=<PIHOLE_IP>` in `.env` and run `docker compose up -d` in `pihole/`.
7. Test: `dig @<PIHOLE_IP>` for a normal and a blocked name, from this box and from the old box. `sudo PIHOLE_IP=<PIHOLE_IP> bash scripts/verify.sh`. Watch the Pi-hole query log for a minute: many clients should show up.
8. If all pass: cancel the revert timer on the old box. On the old box, stop the Pi-hole timers (`pihole-ensure.timer`, `pihole-autoupdate.timer`) so they do not fight its new address. Leave the container and the volume in place for rollback.
9. If Tailscale DNS pointed at the old box (Phase 3), ask Don to change it now.

**Rollback**, if any test in step 7 fails and you cannot fix it within 10 minutes: reverse steps 3 to 6 (reservations back, renew on both boxes, old box re-enables its timers, restart its container). Then tell Don what failed.

## Phase 7: finish

1. Remove `/etc/sudoers.d/99-migration-temp`. Confirm that `sudo -n true` now fails.
2. Update the `basement-server-update` skill in `~/.claude/skills/` on this box so that it describes this box: new Tailscale IP, TPM or keyfile, compose instead of `docker run`. Tell Don that the copy of this skill on Gus also needs the update; do not edit Gus from here.
3. Update `STATUS.md`, commit, push.

## Later (not tonight)

- Don's physical power-cut test.
- The old box stays on for at least a week as rollback. Wipe it only after that, and only with Don's yes.
- Home Assistant in Docker (Home Assistant Container). Don is looking at converting an older ADT panel to DIY monitoring. He believes it's a Safewatch Pro 3000.
- Backups of the Pi-hole volume, Home Assistant config, and `~/.claude/` to Gus over Tailscale (rsync on a timer).

## Report

At the end of each session, update `STATUS.md` and tell Don, in short tables:

- What changed
- What you verified and how
- What's still open
- What you assumed ("Choices I'm not confident of")
