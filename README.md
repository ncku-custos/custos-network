# custos-network

Config-as-code for the Custos drone's **Phase 1 bare IP link**: a static-IP 5 GHz Wi-Fi link
between the drone (access point) and the ground station (station). This is the foundation every
later traffic plane (MAVLink, video, ROS 2 over Zenoh) rides on. See `docs/intro.md` for the
full architecture and `docs/rationale.md` for why it's shaped this way.

The mechanism is **systemd-networkd** (static IP) + **hostapd** (drone AP) + **wpa_supplicant**
(ground STA) + one **oneshot** for regulatory domain and Wi-Fi power-save. No NetworkManager,
no DHCP, no roaming — loss is made a non-event by removing state, not by adding recovery code.

> **Status:** Phase 1 (the bare link). The ground→internet NAT/uplink and an Ansible role are
> deliberately deferred — see "Next steps".

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

## ⚠️ Before you start — the serial-console lifeline

Reconfiguring `wlan0` will **drop any SSH session riding that same Wi-Fi**. Do all bring-up over
the **serial console** or a **separate wired interface** — never over the link you're
reconfiguring. The drone-AP side is the dangerous one (you become the AP; you can't also be a
client of yourself to get back in).

## ⚠️ The dev PSK is not a secret

`hostapd.conf` / `wpa_supplicant-wlan0.conf` ship a development passphrase
(`custos-dev-changeme`) committed on purpose for bring-up. **Rotate it before any real
deployment** (and, at that point, move it out of git).

## Install

On each machine, over serial/wired (see lifeline warning):

```bash
sudo ./scripts/install.sh --role drone     # on the drone companion
sudo ./scripts/install.sh --role ground    # on the ground station
```

The installer is idempotent and symlink-based (edit a file in the repo, then
`systemctl restart <unit>` to reapply). Clone the repo to a **fixed path** (e.g.
`/opt/custos-network`) so the `/etc` symlinks survive across sessions.

Before the ground can pin the AP, read the drone's `wlan0` MAC (`ip link show wlan0` on the
drone) and put it in `ground/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` (`bssid=`). For the
very first association you can comment out `bssid=` and connect by SSID, then pin it.

Requires `hostapd`, `wpasupplicant`, `iw`, `rfkill` (the installer warns if any are missing).

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

## To uninstall

Remove the symlinks under `/etc` that point into this repo, then
`sudo systemctl disable --now custos-hostapd.service custos-wifi-tune@wlan0.service`
(drone) / `wpa_supplicant@wlan0.service` (ground), and
`sudo systemctl unmask hostapd.service wpa_supplicant.service`. Delete
`/etc/NetworkManager/conf.d/99-custos-unmanaged.conf` to hand `wlan0` back to NetworkManager.

## Radio channel

`docs/` (intro/topology) originally specified **ch36**. ch36 is U-NII-1 (5150–5250 MHz), which is
typically **indoor-only** under TW NCC rules — wrong for an outdoor patrol drone. We use **ch149**
(U-NII-3, 5745 MHz): also non-DFS (the original reason for ch36) **and** outdoor-legal. A quick
NCC double-check before flight is still wise. *TODO: refresh `docs/intro.md` + `docs/topology.d2`
(and regenerate `topology.svg`) to say ch149.*

## Gotchas

- **NetworkManager vs networkd** — NM is present on these MediaTek boards; the installer drops an
  `unmanaged-devices` conf for `wlan0` and masks the non-instanced `wpa_supplicant.service`.
  Without this, hostapd/wpa_supplicant hit "Device or resource busy" and the IP flaps.
- **hostapd↔networkd boot race (AP)** — solved by `ConfigureWithoutCarrier=yes` on the AP
  `.network` plus `BindsTo` the `wlan0` device on the hostapd unit.
- **MT7922 AP mode** — VHT80 is solid; AX/HE160 are flaky and left off. Fallback is HT40
  (`vht_oper_chwidth=0`). Check firmware with `dmesg | grep mt7921`.
- **Regulatory** — wrong regdomain → ch149 refused. Belt-and-suspenders: the oneshot runs
  `iw reg set TW`, hostapd sets `country_code=TW`, and `ieee80211d=1` advertises it to the STA.
- **Interface naming** — assumes `wlan0`; if the MT7922 enumerates as `wlp*`, pin a `.link`
  rename or sweep the real name through the configs.

## Next steps

- **Ansible role** — the `/etc`-mirrored layout (`drone/etc/**`, `ground/etc/**`, `common/etc/**`)
  maps 1:1 onto a `copy`/`template` role; `common/scripts/lib.sh` constants become `host_vars`.
- **Ground→internet NAT/uplink** — a separate `eth0`/cellular interface with masquerade, off the
  flight link. Deliberately out of the Phase 1 gate.
