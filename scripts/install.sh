#!/usr/bin/env bash
# install.sh --role drone|ground
#
# Symlinks the Phase 1 network config into /etc and enables the systemd units.
# Idempotent (safe to re-run). Symlink-based: edit a file in the repo, then
# `systemctl restart <unit>` to reapply — no re-copy.
#
# Run over the SERIAL CONSOLE (or a wired iface), never over the Wi-Fi you are
# reconfiguring — bringing wlan0 up as AP/STA will drop any SSH riding that link.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../common/scripts/lib.sh
. "$REPO_ROOT/common/scripts/lib.sh"

ROLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --role=*) ROLE="${1#*=}"; shift ;;
    -h|--help) echo "usage: $0 --role drone|ground"; exit 0 ;;
    *) die "unknown arg: $1 (usage: $0 --role drone|ground)" ;;
  esac
done
case "$ROLE" in
  drone|ground) ;;
  *) die "must pass --role drone|ground" ;;
esac

require_root

# --- Common: neutralize competing managers on wlan0 ---
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager; then
  log "NetworkManager active: unmanaging $IFACE"
  install -d /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/99-custos-unmanaged.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:$IFACE
EOF
  nmcli device set "$IFACE" managed no 2>/dev/null || true
  systemctl reload NetworkManager 2>/dev/null || true
fi

# The non-instanced wpa_supplicant.service can also grab wlan0 — mask it.
# (We use hostapd on the drone and the wpa_supplicant@wlan0 instance on the ground.)
if systemctl list-unit-files wpa_supplicant.service >/dev/null 2>&1; then
  log "masking non-instanced wpa_supplicant.service"
  systemctl mask wpa_supplicant.service 2>/dev/null || true
fi

# --- Common: package presence (warn only; do not auto-install in Phase 1) ---
for spec in hostapd:hostapd wpasupplicant:wpa_supplicant iw:iw rfkill:rfkill; do
  bin="${spec#*:}"; pkg="${spec%%:*}"
  command -v "$bin" >/dev/null 2>&1 || warn "missing '$bin' — apt install $pkg"
done

# --- Common: oneshot unit + tuning script ---
link_into_etc "$REPO_ROOT/common/etc/systemd/system/custos-wifi-tune@.service" \
              /etc/systemd/system/custos-wifi-tune@.service
link_into_etc "$REPO_ROOT/common/scripts/custos-wifi-tune" /usr/local/sbin/custos-wifi-tune

# --- Role-specific ---
if [ "$ROLE" = "drone" ]; then
  systemctl mask hostapd.service 2>/dev/null || true   # neutralize the packaged single-instance unit
  link_into_etc "$REPO_ROOT/drone/etc/hostapd/hostapd.conf" /etc/hostapd/hostapd.conf
  link_into_etc "$REPO_ROOT/drone/etc/systemd/network/10-wlan0-ap.network" \
                /etc/systemd/network/10-wlan0-ap.network
  link_into_etc "$REPO_ROOT/drone/etc/systemd/system/custos-hostapd.service" \
                /etc/systemd/system/custos-hostapd.service
  ENABLE_UNITS="custos-wifi-tune@${IFACE}.service custos-hostapd.service"
else
  link_into_etc "$REPO_ROOT/ground/etc/wpa_supplicant/wpa_supplicant-wlan0.conf" \
                /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
  link_into_etc "$REPO_ROOT/ground/etc/systemd/network/10-wlan0-sta.network" \
                /etc/systemd/network/10-wlan0-sta.network
  ENABLE_UNITS="custos-wifi-tune@${IFACE}.service wpa_supplicant@${IFACE}.service"
fi

systemctl daemon-reload
systemctl enable --now systemd-networkd
# shellcheck disable=SC2086  # intentional word-splitting of the unit list
systemctl enable $ENABLE_UNITS

log "role=$ROLE installed. Reboot to validate reboot-survival, then:"
log "  sudo $REPO_ROOT/scripts/health-check.sh --role $ROLE"
