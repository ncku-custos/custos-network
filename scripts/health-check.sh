#!/usr/bin/env bash
# health-check.sh --role drone|ground
#
# Re-runnable and read-only. Prints PASS/FAIL per line; exits nonzero on any FAIL.
# Run it after a reboot to validate reboot survival (acceptance check #2): if it passes
# with only enabled units (no hand-run bring-up), the link is reproducible.
# NAT checks run automatically when the role provisioned the host with the NAT uplink
# enabled (CUSTOS_NAT in /etc/custos-network.env); they need root (`nft list`).
# Uplink-environment checks (tether present, internet reachable) WARN instead of FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

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

warn=0
check_warn() { # check_warn <description> <command...> — uplink-environment, never fails the run
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then printf '  PASS  %s\n' "$desc"
  else printf '  WARN  %s\n' "$desc"; warn=1; fi
}

case "$NAT_ENABLED" in true) ;; *) NAT_ENABLED=false ;; esac

echo "custos-network health-check (role=$ROLE, iface=$IFACE, nat=$NAT_ENABLED)"

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

# --- NAT uplink (auto-detected from CUSTOS_NAT; provisioned state FAILs, uplink environment WARNs) ---
if [ "$NAT_ENABLED" = true ]; then
  if [ "$ROLE" = "ground" ]; then
    check "net.ipv4.ip_forward is 1"        sh -c "[ \"\$(cat /proc/sys/net/ipv4/ip_forward)\" = 1 ]"
    check "custos-nat.service active"       systemctl is-active --quiet custos-nat.service
    check "nft table custos_nat loaded"     nft list table ip custos_nat
    check "masquerade $FLIGHT_SUBNET out $UPLINK_IFACE" \
      sh -c "nft list chain ip custos_nat postrouting | grep -F 'ip saddr $FLIGHT_SUBNET' | grep -F 'oifname \"$UPLINK_IFACE\"' | grep -q masquerade"
    check_warn "uplink $UPLINK_IFACE is UP" sh -c "ip link show $UPLINK_IFACE | grep -qw UP"
    check_warn "internet route exits via $UPLINK_IFACE" \
      sh -c "ip -4 route get 1.1.1.1 | grep -qw 'dev $UPLINK_IFACE'"
  else
    check "default route via $GROUND_IP on $IFACE" \
      sh -c "ip -4 route get 1.1.1.1 | grep -w 'via $GROUND_IP' | grep -qw 'dev $IFACE'"
    check "DNS servers configured on $IFACE (systemd-resolved)" \
      sh -c "resolvectl dns $IFACE | grep -qE '[0-9]'"
    check_warn "internet reachable (ping 1.1.1.1)"  ping -c3 -W2 1.1.1.1
    check_warn "DNS resolves (one.one.one.one)"     getent hosts one.one.one.one
  fi
fi

if [ "$fail" -eq 0 ] && [ "$warn" -eq 0 ]; then echo "ALL PASS"
elif [ "$fail" -eq 0 ]; then echo "PASS (warnings are uplink-environment checks)"
else echo "FAILURES PRESENT"; fi
exit "$fail"
