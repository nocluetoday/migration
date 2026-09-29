# OptiPlex 7070 Micro migration

You are Claude Code running on a newly installed home server. This file is the plan. You have no other context from the conversation that produced it, so read all of it before doing anything.

## Goal

Make this machine the always-on Linux box for the house. It replaces an old Intel MacBook running Omarchy. Order of work: Omarchy (done by Don before you start), Claude Code (done), then hardening, unattended boot, Pi-hole, then other services. The old box stays running until the new one has run a week without problems.

## This repo is public

Nothing private gets committed. That includes:

- IP addresses, MAC addresses, hostnames of other machines, tailnet names
- Passwords, API keys, Tailscale auth keys, LUKS passphrases or recovery keys
- Pi-hole Teleporter exports (they contain local DNS records and client lists)
- Compose files with secrets inline. Put secrets in `.env` and make sure `.env` is in `.gitignore` before the first commit.

Machine-specific values go in `local/` (gitignored) or you ask Don. Placeholders used below: `<NEW_IP>`, `<OLD_BOX>`, `<OLD_PIHOLE_IP>`.

## Hardware

- Dell OptiPlex 7070 Micro, i5-9500T (6 cores, 35W), 16GB RAM, 256GB NVMe
- No PCIe slot, no Thunderbolt. Front USB-C is data only.
- Video: two DisplayPort on the rear
- Wired Ethernet to a UniFi gateway

## Network context

- UniFi gateway handles DHCP. This box should have a DHCP reservation (Don sets it).
- There is an IoT VLAN with its own filtering rules. **Do not change anything about it, including its DNS setting, without Don's explicit confirmation in the current session.**
- Pi-hole already runs somewhere on the network. Location unknown to this doc: it may be on the old Omarchy MacBook. Find out (ask Don if needed) before Phase 4.
- Don uses Tailscale.
- Don's main machine is an M5 Max MacBook Pro named Gus. It handles local LLM inference. This box does not need a GPU and is not for inference.

## How to work

- Keep a checklist in `STATUS.md` (safe for a public repo: no IPs or secrets) and update it as you finish items.
- `sudo` needs a password you can't type. For commands needing root, either ask Don to run `sudo -v` first so the credential is cached, or give him the exact commands to run and wait.
- Before changing a config file, copy it to `<file>.bak` in the same directory.
- If what you find on the machine contradicts this doc, stop and tell Don what differs.

## Ask first

Stop and get Don's explicit yes before:

- Anything touching disk encryption, the initramfs (`mkinitcpio`), or the bootloader. A mistake here makes the box unbootable.
- Any change to the UniFi config, including the DNS cutover
- Anything on the IoT VLAN
- Stopping, reconfiguring, or wiping the old box or the existing Pi-hole
- Deleting files outside this repo
- Opening firewall ports beyond those listed in this doc

## Phase 0 and 1: done by Don before you start

Verify these rather than assuming them:

- BIOS updated, SATA mode set to AHCI, Secure Boot off, AC Recovery = Power On
- Omarchy installed from the ISO with full-disk LUKS encryption
- Wired Ethernet with a DHCP reservation
- Claude Code installed and logged in

Checks you can run: `lsblk -f` (expect a `crypto_LUKS` partition on the NVMe), `ip -4 addr`, `sudo dmidecode -s bios-version`.

## Phase 2: base setup

1. Install and enable SSH: `openssh`, `sshd.service`. Key-only auth; turn off password auth in `/etc/ssh/sshd_config`. Confirm Don can SSH in from Gus before turning off password auth.
2. Install Tailscale and enable `tailscaled`. Don runs `tailscale up` himself (browser login).
3. Stop the machine from ever suspending. Check hypridle config (`~/.config/hypr/hypridle.conf`) and `systemd-logind` settings. Screen lock and display off are fine; suspend and hibernate are not.
4. Check ufw: `sudo ufw status verbose`. Record the defaults in `STATUS.md`.
5. Install Docker if it isn't there (`docker --version`). Enable `docker.service`. Add Don's user to the `docker` group.
6. Migrate Claude Code config from the old box: copy `~/.claude/skills/`, `~/.claude/CLAUDE.md`, and `~/.claude/settings.json` from `<OLD_BOX>`. Do not copy the credentials file. Don has a `unifi-management` skill that should come across.

Done when: Don can SSH in from Gus by key, `systemctl is-enabled sshd tailscaled docker` all return enabled, and there is no suspend path left in the config.

## Phase 3: unattended boot

The problem: Omarchy asks for the LUKS passphrase at every boot. After a power outage, DNS for the whole house stays down until someone types it. This has to be solved before Pi-hole moves here.

Investigate first and report back, with no changes yet:

- `grep ^HOOKS /etc/mkinitcpio.conf`: does it use `sd-encrypt` (systemd) or `encrypt` (busybox)?
- Which bootloader (expect Limine) and where the kernel command line is set
- `systemd-cryptenroll /dev/<luks-partition>` to list current keyslots
- Whether a TPM is visible: `ls /dev/tpm*`. Don turned the TPM off in the BIOS for install, so it may need to be re-enabled first.

Then present the options to Don and let him choose:

1. **TPM2 auto-unlock** with `systemd-cryptenroll --tpm2-device=auto`. Requires the `sd-encrypt` hook. Protects against someone pulling the drive, not against someone taking the whole box.
2. **SSH unlock from initramfs** (mkinitcpio-dropbear or similar). Still needs someone to act after each reboot, but from any LAN machine.
3. **Reinstall without encryption.** Don's call only.

Whatever is chosen:

- Never remove the existing passphrase keyslot.
- Generate a recovery key (`systemd-cryptenroll --recovery-key`) and hand it to Don to store in his password manager. It never touches this repo or any file on disk.

Done when: the box boots to a working network with no keyboard input after a full power cut (pull the plug, wait, plug back in). Don does the physical test.

## Phase 4: Pi-hole

As far as we know, Pi-hole's native installer doesn't support Arch. Run it in Docker using the official image and the compose example from https://docs.pi-hole.net/docker/.

1. Find the current Pi-hole and its version. On it, export settings via Settings > Teleporter. Store the file in `local/` (gitignored).
2. Check what holds port 53: `sudo ss -tulpn | grep :53`. If systemd-resolved's stub listener has it, set `DNSStubListener=no` in `/etc/systemd/resolved.conf` and restart resolved. Make sure the host itself still resolves afterward.
3. Compose file in this repo at `pihole/compose.yaml`. Admin password comes from `.env`. Persist `/etc/pihole` to a volume. Set `restart: unless-stopped`. Set `FTLCONF_dns_listeningMode: 'all'` if using bridge networking.
4. Firewall: allow 53/tcp and 53/udp and the web UI port from the LAN only. Docker-published ports can bypass ufw rules because Docker writes its own iptables rules. Check whether that is happening here and report it.
5. Import the Teleporter file.

Done when:

- `dig @127.0.0.1 example.com` resolves
- `dig @127.0.0.1 doubleclick.net` returns a blocked answer (0.0.0.0 or NXDOMAIN, depending on config)
- The same two queries work from Gus against `<NEW_IP>`
- The gravity domain count roughly matches the old instance
- The container is back up after a reboot with no manual step

**Cutover (ask first):** Don changes the default LAN's DHCP DNS server in UniFi to `<NEW_IP>`, or you do it via the unifi-management skill with his yes. The IoT VLAN is a separate decision. The old Pi-hole keeps running as a rollback for at least a week.

## Phase 5: later

Not part of the first session. Listed so the setup leaves room for them:

- Home Assistant in Docker (Home Assistant Container). Don is looking at converting an older ADT panel to DIY monitoring. He believes it's a Safewatch Pro 3000.
- Backups of the Pi-hole volume, Home Assistant config, and `~/.claude/` to Gus over Tailscale (rsync on a timer)
- Inventory everything running on the old box (`systemctl list-units --type=service --state=running`, `docker ps`, `crontab -l`, user systemd units) so nothing gets lost when it's wiped
- Wipe the old box once the new one has run a week without problems (ask first)

## Report

At the end of each session, update `STATUS.md` and tell Don:

- What changed
- What you verified and how
- What's still open
- What you assumed
