#!/usr/bin/env bash
# shellcheck disable=SC2034  # constants are consumed by the script sourcing this file
# Constants + a helper shared by the custos-network diagnostic scripts (scripts/health-check.sh).
# Sourced, not executed. Values come from /etc/custos-network.env, written by the Ansible
# role on provisioned hosts; the fallbacks below match the role defaults.

# shellcheck disable=SC1091
[ -r /etc/custos-network.env ] && . /etc/custos-network.env

IFACE="${CUSTOS_FLIGHT_IFACE:-wlan0}"
DRONE_IP="${CUSTOS_DRONE_IP:-192.168.4.1}"
GROUND_IP="${CUSTOS_GROUND_IP:-192.168.4.2}"
COUNTRY="${CUSTOS_COUNTRY:-TW}"
FLIGHT_SUBNET="${CUSTOS_FLIGHT_SUBNET:-192.168.4.0/24}"
UPLINK_IFACE="${CUSTOS_UPLINK_IFACE:-eth0}"
NAT_ENABLED="${CUSTOS_NAT:-false}"

die() { printf '[custos-net] ERROR: %s\n' "$*" >&2; exit 1; }
