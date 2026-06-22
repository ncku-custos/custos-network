#!/usr/bin/env bash
# Constants + a helper shared by the custos-network diagnostic scripts (scripts/health-check.sh).
# Sourced, not executed. The canonical values now live in the Ansible role
# (ansible/roles/custos_network/defaults + ansible/group_vars); keep these in sync if you change them.

# shellcheck disable=SC2034  # consumed by the script that sources this file
IFACE="wlan0"
DRONE_IP="192.168.4.1"
GROUND_IP="192.168.4.2"
COUNTRY="TW"

die() { printf '[custos-net] ERROR: %s\n' "$*" >&2; exit 1; }
