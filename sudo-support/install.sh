#!/bin/zsh
set -euo pipefail

module_source="${0:A:h}/pam_glance.so"
module_target="/usr/local/lib/pam/pam_glance.so"
config="/etc/pam.d/sudo_local"
line="auth       sufficient     ${module_target}"

[[ -f "$module_source" ]] || { print -u2 "Missing built PAM module: $module_source"; exit 1; }
grep -Eq '^auth[[:space:]]+include[[:space:]]+sudo_local' /etc/pam.d/sudo || {
  print -u2 "macOS sudo does not include sudo_local; refusing to edit the system PAM file."
  exit 1
}

mkdir -p /usr/local/lib/pam
install -o root -g wheel -m 755 "$module_source" "$module_target"

backup=""
if [[ -f "$config" ]]; then
  backup="${config}.glance-backup.$(date +%Y%m%d%H%M%S)"
  cp -p "$config" "$backup"
fi

temporary="$(mktemp /tmp/glance-sudo-local.XXXXXX)"
trap 'rm -f "$temporary"' EXIT
if [[ -f "$config" ]]; then
  grep -v 'pam_glance\.so' "$config" > "$temporary" || true
fi
{
  print -r -- "$line"
  cat "$temporary"
} > "$config"
chown root:wheel "$config"
chmod 644 "$config"

grep -Fq "$line" "$config" || {
  [[ -n "$backup" ]] && cp -p "$backup" "$config"
  rm -f "$module_target"
  print -u2 "Validation failed; restored previous configuration."
  exit 1
}

print "Glance face authentication was added before Touch ID and password fallback."
