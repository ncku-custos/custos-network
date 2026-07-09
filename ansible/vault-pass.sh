#!/bin/sh
# Vault password source (wired via ansible.cfg vault_password_file). Prints
# ansible/.vault-pass, minting a random one on first use so `ansible-vault create`
# and flagless playbook runs both just work. Joining an existing deployment?
# Copy its .vault-pass here BEFORE the first run instead.
set -eu
d="$(dirname "$0")"
if [ ! -f "$d/.vault-pass" ]; then
  if [ -e "$d/group_vars/custos/vault.yml" ]; then
    echo "vault-pass.sh: vault.yml exists but ansible/.vault-pass is missing —" \
      "copy the password file from wherever the vault was created (see README)" >&2
    exit 1
  fi
  umask 077
  head -c 32 /dev/urandom | base64 | tr -d '\n=+/' > "$d/.vault-pass"
  echo "vault-pass.sh: minted a new ansible/.vault-pass (git-ignored) — back it up" >&2
fi
cat "$d/.vault-pass"
