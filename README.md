# custos-network

Config-as-code for the Custos drone's **Phase 1 bare IP link**: a static-IP 5 GHz Wi-Fi link
between the drone (access point) and the ground station (station). This is the foundation every
later traffic plane (MAVLink, video, ROS 2 over Zenoh) rides on. See `docs/intro.md` for the
full architecture and `docs/rationale.md` for why it's shaped this way.

The mechanism is **systemd-networkd** (static IP) + **hostapd** (drone AP) + **wpa_supplicant**
(ground STA) + one **oneshot** for regulatory domain and Wi-Fi power-save. No NetworkManager,
no DHCP, no roaming — loss is made a non-event by removing state, not by adding recovery code.
Provisioning is an **Ansible role** (`ansible/roles/custos_network`).

> **Status:** Phase 1 (the bare link), provisioned by Ansible. The ground→internet NAT/uplink is
> implemented as an optional, off-by-default block — see "NAT uplink (optional)".

## The gate (definition of done)

1. **Ping both ways** over the Wi-Fi link.
2. **Survives a reboot** of both machines — comes up automatically, no hand-run scripts.
3. **Forced disconnect recovers on its own** — re-associates and traffic resumes with no
   manual intervention.

## Network facts

| | Drone (AP) | Ground (STA) |
|---|---|---|
| `wlan0` IP | `192.168.4.1/24` | `192.168.4.2/24` |
| role | hostapd | wpa_supplicant (pinned BSSID, `bgscan=""`) |
| daemon | `custos-hostapd.service` | `wpa_supplicant@wlan0.service` (distro template) |

Subnet `192.168.4.0/24`, SSID `custos-link`, **channel 149** (5745 MHz), country **TW**,
power-save **off** both ends. See "Radio channel" below.

## ⚠️ The dev PSK is not a secret

The role's templates ship a development passphrase (`custos-dev-changeme`). **Rotate it before any
real deployment**:

```bash
cd ansible
ansible-vault create group_vars/custos/vault.yml   # add one line: vault_wifi_psk: "<real key>"
ansible-playbook site.yml --ask-vault-pass          # or --vault-password-file .vault-pass (git-ignored)
```

The encrypted `vault.yml` is safe to commit. The role **refuses to run with the dev PSK** unless
`custos_network_env` is `dev` (the default) — set `custos_network_env: prod` in a real inventory
to arm the gate. PSK-bearing configs land as root-only (`0600`) and are excluded from `--diff`
output, so the real key never prints.

## Provision (Ansible)

The role templates the configs, hands `wlan0` to systemd-networkd (unmanaging NetworkManager),
installs the units, and enables everything — idempotently.

⚠️ **Run from a control node over a management path — never over the flight `wlan0`.** The role
restarts `wlan0`; a control connection riding it would be cut mid-run. Set each host's
`ansible_host` (in `ansible/inventory.ini`) to a **management IP** — the ground's `eth0`/cellular
uplink, or a **wired bench Ethernet** on the drone during provisioning — **never `192.168.4.1/.2`**.

Real identity values (mgmt IPs, the drone's wlan0 MAC) live in **git-ignored `host_vars/`
overlays**, which outrank the committed placeholders in `inventory.ini`/`group_vars` — real
BSSIDs and addresses never enter git:

```bash
cd ansible
# 1. copy host_vars/drone-01.yml.example -> host_vars/drone-01.yml; set the mgmt IP.
#    Same for ground-01: mgmt IP + the drone's wlan0 MAC (custos_network_ap_bssid —
#    read it on the drone: `ip link show wlan0`; for the very first association you may
#    blank the bssid, connect by SSID, then pin it)
# 2. edit inventory.ini: set ansible_user
ansible-playbook site.yml                 # provisions both groups
ansible-playbook site.yml --limit drone   # or one group at a time
```

**Serial-only box (no management NIC):** run the role locally on the box instead —
`ansible-playbook -i 'localhost,' -c local site.yml -e custos_network_role=ap` (needs `ansible` on
the box). The role apt-installs `hostapd`/`wpasupplicant`/`iw`/`rfkill` on Debian-family hosts;
pre-stage them on offline or non-Debian boards.

## Verify

```bash
sudo ./scripts/health-check.sh --role drone    # or --role ground
```

- **Gate #1 (ping):** health-check pings the peer; or manually, drone `iw dev wlan0 station dump`
  + `ping -c3 192.168.4.2`, ground `iw dev wlan0 link` + `ping -c3 192.168.4.1`.
- **Gate #2 (reboot):** `sudo systemctl reboot` both, then re-run health-check — it must pass
  with only enabled units, no hand-run bring-up.
- **Gate #3 (recovery):** on the ground,
  `sudo iw dev wlan0 disconnect` then
  `watch -n0.5 'iw dev wlan0 link; ip -4 addr show wlan0'` — confirm it reassociates to the
  pinned BSSID and ping resumes on its own, with the **static IP unchanged throughout** (proves
  `IgnoreCarrierLoss`). The truer RF-loss test is AP-side `hostapd_cli deauthenticate <mac>`.

## NAT uplink (optional)

Off by default; a plain Phase 1 run is byte-identical with the flag unset. Enabling
`custos_network_enable_nat` (for **both** groups — uncomment it in `group_vars/*.yml`, or
`-e custos_network_enable_nat=true`) adds:

- **Ground (STA):** IPv4 forwarding + masquerade of `192.168.4.0/24` out
  `custos_network_uplink_iface` (default `eth0`; override in host_vars for cellular). Rules live
  in a dedicated nftables table (`custos_nat`) loaded by its own `custos-nat.service` — by
  nftables semantics our accepts can never override another firewall's drops, and no other
  table is touched. Forwarding is scoped: drone→internet out the uplink, only
  `established,related` back in, everything else touching `wlan0` dropped.
- **Drone (AP):** default route via `192.168.4.2` + DNS in the wlan0 `.network` file
  (needs systemd-resolved for `DNS=`).

```bash
ansible-playbook site.yml -e custos_network_enable_nat=true              # full run
ansible-playbook site.yml -e custos_network_enable_nat=true --tags nat   # NAT delta only
                                          # (--tags nat assumes a previously provisioned host)
```

Verify: ground `nft list table ip custos_nat`, drone `ping -c3 1.1.1.1` (then a hostname to
check DNS). Gotchas:

- **ufw/Docker on the ground box:** their FORWARD drop policies still apply — our rules
  deliberately don't override them (that deference is the point). Allow the path there too,
  e.g. `ufw route allow in on wlan0 out on eth0`.
- **Never enable the distro `nftables.service`** on these hosts — stock `/etc/nftables.conf`
  begins with `flush ruleset`, which would destroy every table on the box (ours, ufw's,
  Docker's). `custos-nat.service` is deliberately independent of it.
- **Bench provisioning:** the drone's metric-0 `Gateway=` beats a DHCP default route on bench
  Ethernet, so with NAT on, the drone's internet rides the flight link even on the bench.
- Cellular uplinks with small MTUs: uncomment the MSS-clamp line in `custos-nat.nft.j2`.
- `health-check.sh` has no NAT checks yet (its gates are link-layer); verify NAT manually as
  above for now.
- The role is additive: turning the flag back off skips the tasks but removes nothing — see
  uninstall below.

## To uninstall

The role copies files into `/etc` (it does not symlink). To revert a box:
`sudo systemctl disable --now custos-hostapd.service custos-wifi-tune@wlan0.service` (drone) /
`wpa_supplicant@wlan0.service` (ground); `sudo systemctl unmask hostapd.service wpa_supplicant.service`;
remove `/etc/hostapd/hostapd.conf`, `/etc/systemd/network/10-wlan0-*.network`,
`/etc/systemd/system/custos-{hostapd,wifi-tune@}.service`, `/usr/local/sbin/custos-wifi-tune`, and
`/etc/NetworkManager/conf.d/99-custos-unmanaged.conf`; then `sudo systemctl daemon-reload`.

If NAT was enabled, additionally (ground): `sudo systemctl disable --now custos-nat.service`
(its `ExecStop` deletes the nft table); remove `/etc/systemd/system/custos-nat.service`,
`/etc/custos-nat.nft`, and `/etc/sysctl.d/90-custos-nat.conf`; `sudo sysctl -w net.ipv4.ip_forward=0`
if nothing else needs forwarding.

## Radio channel

`docs/` originally specified **ch36**. ch36 is U-NII-1 (5150–5250 MHz), which is typically
**indoor-only** under TW NCC rules — wrong for an outdoor patrol drone. We use **ch149**
(U-NII-3, 5745 MHz): also non-DFS (the original reason for ch36) **and** outdoor-legal. A quick
NCC double-check before flight is still wise.

## Gotchas

- **NetworkManager vs networkd** — NM is present on these MediaTek boards; the role drops an
  `unmanaged-devices` conf for `wlan0` (when NM is present) and masks the non-instanced
  `wpa_supplicant.service`. Without this, hostapd/wpa_supplicant hit "Device or resource busy".
- **Don't reconfigure networkd over the mgmt link** — the role uses `networkctl reconfigure wlan0`
  (not a full `systemctl restart systemd-networkd`, which re-applies every interface and could
  drop the control node's SSH).
- **hostapd↔networkd boot race (AP)** — solved by `ConfigureWithoutCarrier=yes` on the AP
  `.network` plus `BindsTo` the `wlan0` device on the hostapd unit.
- **MT7922 AP mode** — VHT80 is solid; AX/HE160 are flaky and left off. Fallback is HT40
  (`vht_oper_chwidth=0`). Check firmware with `dmesg | grep mt7921`.
- **Regulatory** — wrong regdomain → ch149 refused. Belt-and-suspenders: the oneshot runs
  `iw reg set TW`, hostapd sets `country_code=TW`, and `ieee80211d=1` advertises it to the STA.
- **Interface naming** — the role hardcodes `wlan0`; if the MT7922 enumerates as `wlp*`, rename it
  to `wlan0` (a systemd `.link` rule) rather than threading the name through the role.

## Next steps

- **Vault the PSK before leaving dev** — the guard and procedure are in place (see "The dev PSK
  is not a secret" above); creating the actual vault is the remaining deployment-time action.
- **Fill real identity values** — copy the `host_vars/*.yml.example` overlays (mgmt IPs, the
  drone's wlan0 MAC) and run the three gate tests on hardware.
- **health-check `--nat` mode** — once the NAT uplink is used in anger.
