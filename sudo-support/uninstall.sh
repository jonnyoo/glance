#!/bin/zsh
set -euo pipefail

config="/etc/pam.d/sudo_local"
module="/usr/local/lib/pam/pam_glance.so"

if [[ -f "$config" ]]; then
  temporary="$(mktemp /tmp/glance-sudo-local.XXXXXX)"
  trap 'rm -f "$temporary"' EXIT
  grep -v 'pam_glance\.so' "$config" > "$temporary" || true
  install -o root -g wheel -m 644 "$temporary" "$config"
fi
rm -f "$module"
print "Glance face authentication was removed; Apple Touch ID and password remain unchanged."
