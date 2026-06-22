#!/usr/bin/env bash
# health-check.sh --role drone|ground
#
# Re-runnable and read-only. Prints PASS/FAIL per line; exits nonzero on any FAIL.
# Run it after a reboot to validate reboot-survival (gate #2): if it passes with only
# enabled units (no hand-run bring-up), the link is reproducible.
set -uo pipefail

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
case "$ROLE" in drone|ground) ;; *) die "must pass --role drone|ground" ;; esac

if [ "$ROLE" = "drone" ]; then SELF_IP="$DRONE_IP"; PEER_IP="$GROUND_IP"
else SELF_IP="$GROUND_IP"; PEER_IP="$DRONE_IP"; fi

fail=0
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  PASS  %s\n' "$desc"
  else printf '  FAIL  %s\n' "$desc"; fail=1; fi
}

echo "custos-network health-check (role=$ROLE, iface=$IFACE)"

# --- Shared ---
check "interface $IFACE is UP"            sh -c "ip link show $IFACE | grep -qw UP"
check "static IP $SELF_IP present"        sh -c "ip -4 addr show $IFACE | grep -qw $SELF_IP"
check "reg domain is $COUNTRY"            sh -c "iw reg get | grep -q 'country $COUNTRY'"
check "power_save is off"                 sh -c "iw dev $IFACE get power_save | grep -qw off"
check "rfkill not blocking wlan"          sh -c "! rfkill list 2>/dev/null | grep -i -A2 wireless | grep -qi 'blocked: yes'"
check "NetworkManager not managing $IFACE" sh -c "! command -v nmcli >/dev/null 2>&1 || ! nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -qE \"^$IFACE:(connected|connecting)\""

# --- Role-specific ---
if [ "$ROLE" = "drone" ]; then
  check "custos-hostapd.service active"   systemctl is-active --quiet custos-hostapd.service
  check "AP has >=1 associated station"   sh -c "iw dev $IFACE station dump | grep -q Station"
else
  check "wpa_supplicant@$IFACE active"    systemctl is-active --quiet "wpa_supplicant@${IFACE}.service"
  check "associated to an AP"             sh -c "iw dev $IFACE link | grep -qi 'Connected to'"
fi

check "ping peer $PEER_IP"                ping -c3 -W1 "$PEER_IP"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES PRESENT"; fi
exit "$fail"
