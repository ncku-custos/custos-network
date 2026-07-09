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
| flight-iface IP | `192.168.4.1/24` | `192.168.4.2/24` |
| role | hostapd | wpa_supplicant (pinned BSSID, `bgscan=""`) |
| daemon | `custos-hostapd.service` | `wpa_supplicant@<iface>.service` (distro template) |

Subnet `192.168.4.0/24`, SSID `custos-link`, **channel 149** (5745 MHz), country **TW**,
power-save **off** both ends. The flight interface defaults to `wlan0` and is settable per host
(`custos_network_flight_iface`). See "Radio channel" below.

## Where configuration lives

Tracked files are **never edited** to deploy this repo:

- **`ansible/host_vars/<host>.yml`** (git-ignored; copy from the committed `*.yml.example`) —
  everything machine-specific: mgmt IP, SSH user/key, flight + uplink NICs, the drone's real BSSID.
- **`ansible/group_vars/custos/main.yml`** (tracked) — deployment-wide, committable toggles:
  `custos_network_env: prod`, `custos_network_enable_nat: true`.
- **`ansible/group_vars/custos/vault.yml`** (encrypted) + **`ansible/.vault-pass`** (git-ignored) —
  the real PSK. See the next section.
- **`ansible/roles/custos_network/defaults/main.yml`** — every knob with its default; override in
  host_vars/group_vars, not in place.

## ⚠️ The dev PSK is not a secret

The role's templates ship a development passphrase (`custos-dev-changeme`). **Rotate it before any
real deployment**:

```bash
cd ansible
ansible-vault create group_vars/custos/vault.yml   # add one line: vault_wifi_psk: "<real key>"
ansible-playbook site.yml                          # flagless — ansible.cfg wires vault-pass.sh
```

No `--ask-vault-pass` needed: `ansible.cfg` points at `vault-pass.sh`, which reads the git-ignored
`ansible/.vault-pass` and **mints a random one on first use** — so `ansible-vault create` and
every later run just work. **Back `.vault-pass` up**; on a second control machine, copy it over
**before** the first run there (or pre-seed it with a team-shared password — whatever `.vault-pass`
holds when the vault is created is the vault's password).

The encrypted `vault.yml` is safe to commit. The role **refuses to run with the dev PSK** unless
`custos_network_env` is `dev` (the default) — uncomment `custos_network_env: prod` in
`group_vars/custos/main.yml` to arm the gate. PSK-bearing configs land as root-only (`0600`) and
are excluded from `--diff` output, so the real key never prints.

## Provision (Ansible)

The role templates the configs, hands the flight interface to systemd-networkd (unmanaging
NetworkManager), installs the units, and enables everything — idempotently. Only the flight NIC
is **reconfigured**, but two actions are inherently machine-wide, so know their edges:

- On NetworkManager systems the shared `wpa_supplicant.service` — which carries **every** NM
  WiFi connection, uplink/hotspot included — is left running; the flight NIC is kept away from
  NM by an `unmanaged-devices` conf instead. On **NM-less** boxes that unit is stopped and
  masked: if mgmt WiFi there rides it, it will be cut — use wired mgmt or a
  `wpa_supplicant@<mgmt-iface>` instance instead.
- The regulatory domain (`iw reg set`) is machine-global — see the field-setup notes.

⚠️ **Run from a control node over a management path — never over the flight interface.** The role
restarts it; a control connection riding it would be cut mid-run. Set each host's `ansible_host`
to a **management IP** — the ground's ethernet/cellular uplink, or a **wired bench Ethernet** on
the drone during provisioning — **never `192.168.4.1/.2`**. The role asserts this: it refuses to
run when `ansible_host` is an address on the flight interface (override with
`custos_network_allow_flight_mgmt=true` if you accept the mid-run drop; a hostname resolving to a
flight IP is *not* caught — use IPs).

```bash
cd ansible
# One-time: copy the overlays and fill in real values (all identity lives here,
# git-ignored — never edit inventory.ini):
cp host_vars/drone-01.yml.example  host_vars/drone-01.yml    # mgmt IP, ssh user/key
cp host_vars/ground-01.yml.example host_vars/ground-01.yml   # + the drone's flight-iface MAC
#   (custos_network_ap_bssid — read it on the drone: `ip link show wlan0`; for the very
#    first association you may blank the bssid, connect by SSID, then pin it)

ansible-playbook site.yml --check --diff  # dry-run first (see note below)
ansible-playbook site.yml                 # provisions both groups
ansible-playbook site.yml --limit drone   # or one group at a time
```

**Dry-run note:** `--check --diff` is the habit before every real run on an already-provisioned
host. On a **first-ever** run it can fail on `systemd:` tasks for units the role hasn't installed
yet — expected, not a bug.

**Serial-only box (no management NIC):** run the role locally on the box instead —
`ansible-playbook -i 'localhost,' -c local site.yml -e custos_network_target=all -e custos_network_role=ap`
(needs `ansible` on the box; for the STA side also pass `-e custos_network_ap_bssid=<mac>`). The role apt-installs
`hostapd`/`wpasupplicant`/`iw`/`rfkill` on Debian-family hosts; pre-stage them on offline or
non-Debian boards.

## Field setup (laptop ground station + phone uplink)

The ground station is often just the operator's laptop: built-in WiFi + a USB WiFi adapter +
a phone for internet. Everything lives in the git-ignored `host_vars/ground-01.yml`:

```yaml
ansible_connection: local              # the laptop provisions itself — no SSH (add -K for sudo)
custos_network_flight_iface: wlx0013ef1a2b3c   # USB WiFi adapter = flight STA (`ip link`)
custos_network_uplink_iface: usb0              # phone USB tether (Android: usb0/rndis0; iPhone: enx*/eth*)
# custos_network_uplink_iface: wlp0s20f3       # …or the built-in WiFi joined to the phone's hotspot
```

Then uncomment `custos_network_enable_nat: true` in `group_vars/custos/main.yml` (arms both
groups) and run `ansible-playbook site.yml -K --limit ground` (then `--limit drone` over its bench
link). Notes:

- **Tethering must be up before the run** — the uplink NIC has to exist for the nft rules to bind
  names at load; the connection can drop and return afterwards.
- **Safe to run from the laptop itself**: with NetworkManager present the role never stops the
  shared `wpa_supplicant.service` (which carries the built-in-WiFi/hotspot uplink) — the flight
  NIC is excluded via `unmanaged-devices` instead — and a preflight assert refuses to run at all
  if `ansible_host` sits on the flight interface.
- **MSS clamping is on by default** (`custos_network_clamp_mss`) — phone/cellular uplinks have
  small MTUs; without the clamp, TCP through the NAT stalls.
- **Regulatory domain is machine-global**: `iw reg set` reshapes the allowed channels of the
  **uplink radio too**, and can knock it off a channel that is illegal under the new country.
  Set `custos_network_country` for your jurisdiction *before* field use (the tuning oneshot
  skips the set when the domain already matches, so boots and re-runs don't churn it).

## Verify

```bash
sudo ./scripts/health-check.sh --role drone    # or --role ground
```

The script reads `/etc/custos-network.env` (written by the role), so it checks the right
interface and country automatically. Commands below show the `wlan0` default; substitute your
flight interface.

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
`custos_network_enable_nat` (**one line in `group_vars/custos/main.yml`** arms both groups, or
`-e custos_network_enable_nat=true`) adds:

- **Ground (STA):** IPv4 forwarding + masquerade of `192.168.4.0/24` out
  `custos_network_uplink_iface` (default `eth0`; override in host_vars — see "Field setup" for
  phone tethering). Rules live in a dedicated nftables table (`custos_nat`) loaded by its own
  `custos-nat.service` — by nftables semantics our accepts can never override another firewall's
  drops, and no other table is touched. Forwarding is scoped: drone→internet out the uplink, only
  `established,related` back in, everything else touching the flight interface dropped. Forwarded
  TCP is MSS-clamped both ways (`custos_network_clamp_mss`, default on).
- **Drone (AP):** default route via `192.168.4.2` + DNS in the flight `.network` file
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
  e.g. `ufw route allow in on <flight-iface> out on <uplink-iface>`.
- **Never enable the distro `nftables.service`** on these hosts — stock `/etc/nftables.conf`
  begins with `flush ruleset`, which would destroy every table on the box (ours, ufw's,
  Docker's). `custos-nat.service` is deliberately independent of it.
- **Bench provisioning:** the drone's metric-0 `Gateway=` beats a DHCP default route on bench
  Ethernet, so with NAT on, the drone's internet rides the flight link even on the bench.
- **`ip_forward=1` is machine-global:** with no other firewall the ground box will also forward
  between its *other* interfaces (Docker/LXD hosts already run this way) — the custos nft table
  only guards traffic touching the flight net.
- `health-check.sh` has no NAT checks yet (its gates are link-layer); verify NAT manually as
  above for now.
- The role is additive: turning the flag back off skips the tasks but removes nothing — see
  uninstall below.

## To uninstall

The role copies files into `/etc` (it does not symlink). To revert a box (substitute your flight
interface for `wlan0`):
`sudo systemctl disable --now custos-hostapd.service custos-wifi-tune@wlan0.service` (drone) /
`wpa_supplicant@wlan0.service` (ground); `sudo systemctl unmask hostapd.service wpa_supplicant.service`;
remove `/etc/hostapd/hostapd.conf`, `/etc/systemd/network/10-custos-flight.network`,
`/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` (ground), `/etc/custos-network.env`,
`/etc/systemd/system/custos-{hostapd,wifi-tune@}.service`, `/usr/local/sbin/custos-wifi-tune`, and
`/etc/NetworkManager/conf.d/99-custos-unmanaged.conf`; then `sudo systemctl daemon-reload`.

If NAT was enabled, additionally (ground): `sudo systemctl disable --now custos-nat.service`
(its `ExecStop` deletes the nft table); remove `/etc/systemd/system/custos-nat.service`,
`/etc/custos-nat.nft`, and `/etc/sysctl.d/90-custos-nat.conf`; `sudo sysctl -w net.ipv4.ip_forward=0`
if nothing else needs forwarding.

**Changing `custos_network_flight_iface` on a provisioned host** strands the old iface's pieces —
the role only manages the current one. Disable/remove the old `wpa_supplicant@<old>.service` /
`custos-wifi-tune@<old>.service` and `/etc/wpa_supplicant/wpa_supplicant-<old>.conf` by hand.

## Radio channel

`docs/` originally specified **ch36**. ch36 is U-NII-1 (5150–5250 MHz), which is typically
**indoor-only** under TW NCC rules — wrong for an outdoor patrol drone. We use **ch149**
(U-NII-3, 5745 MHz): also non-DFS (the original reason for ch36) **and** outdoor-legal. A quick
NCC double-check before flight is still wise. `custos_network_channel`/`_freq`/`_vht_seg0` move
together — the valid triples are listed in the role defaults, and the role asserts channel↔freq
consistency.

## Gotchas

- **NetworkManager vs networkd** — where NM is present, the `unmanaged-devices` conf is what
  keeps NM (and its supplicant) off the flight interface — without it, hostapd/wpa_supplicant
  hit "Device or resource busy". The shared `wpa_supplicant.service` is **left running** there:
  it carries every NM WiFi connection, and stopping it once cut a field laptop's uplink. It is
  stopped+masked only on NM-less boxes. Recovering a box hit by the old unconditional mask:
  `sudo systemctl unmask wpa_supplicant.service && sudo systemctl start wpa_supplicant.service`,
  then reconnect WiFi.
- **Don't reconfigure networkd over the mgmt link** — the role uses
  `networkctl reconfigure <flight-iface>` (not a full `systemctl restart systemd-networkd`, which
  re-applies every interface and could drop the control node's SSH).
- **hostapd↔networkd boot race (AP)** — solved by `ConfigureWithoutCarrier=yes` on the AP
  `.network` plus `BindsTo` the flight-interface device on the hostapd unit.
- **MT7922 AP mode** — AX/HE160 are flaky and left off. Check firmware with `dmesg | grep mt7921`.
- **VHT80 ↔ RTL8822BU black hole** — with an `mt7921e` AP and an RTL8822BU USB adapter
  (`rtw88_8822bu`) as the ground STA, AP→STA frames larger than **~900 bytes** are mostly lost
  once a TCP connection has carried data: ping and the SSH banner work, then the session hangs at
  `SSH2_MSG_KEXINIT sent` (the server's KEXINIT is ~1040 B). The loss is intermittent, and SSH
  compounds it — measured **1/6** SSH sessions at VHT80 vs **6/6** at HT40. The AP's TX counters
  increment with zero errors and the STA reports no drops; the frames simply never arrive. Not an
  MTU or DSCP issue, and not SSH-specific — any >900 B reply after a client write reproduces it.
  The fault is the STA's receive path: the same AP at VHT80 passes 20/20 probes to an mt7922
  (mt76) STA at 780 Mbit/s. Set `custos_network_vht: false` (defaults commented in
  `group_vars/custos/main.yml`, or per-AP in its `host_vars` overlay) for HT40 only; peak PHY
  drops ~867 → ~270 Mbit/s, still far above what the flight link needs. Leave it `true` when the
  ground STA is an mt76-class radio.
- **Regulatory** — wrong regdomain → ch149 refused. Belt-and-suspenders: the oneshot runs
  `iw reg set` (country from `/etc/custos-network.env`), hostapd sets `country_code`, and
  `ieee80211d=1` advertises it to the STA.
- **Interface naming** — set `custos_network_flight_iface` per host (in its git-ignored
  host_vars overlay) if the NIC isn't `wlan0`. No dashes in the name (systemd unit-name
  escaping); real NIC names never have them.

## Next steps

- **Vault the PSK before leaving dev** — the guard and procedure are in place (see "The dev PSK
  is not a secret" above); creating the actual vault is the remaining deployment-time action.
- **Fill real identity values** — copy the `host_vars/*.yml.example` overlays (mgmt IPs, the
  drone's flight-iface MAC) and run the three gate tests on hardware.
- **health-check `--nat` mode** — once the NAT uplink is used in anger.
