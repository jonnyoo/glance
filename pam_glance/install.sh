#!/bin/bash
# Install or remove pam_glance for sudo Face auth.
# Usage:
#   install.sh install /path/to/pam_glance.so
#   install.sh uninstall
set -euo pipefail

ACTION="${1:-}"
MODULE_SRC="${2:-}"
MODULE_DST="/usr/local/lib/pam/pam_glance.so"
SUDO_LOCAL="/etc/pam.d/sudo_local"
GLANCE_LINE="auth       sufficient     pam_glance.so"
TID_LINE="auth       sufficient     pam_tid.so"

ensure_sudo_local() {
  if [[ -f "$SUDO_LOCAL" ]]; then
    return
  fi
  if [[ -f /etc/pam.d/sudo_local.template ]]; then
    sed -e 's/^#auth/auth/' /etc/pam.d/sudo_local.template > "$SUDO_LOCAL"
  else
    printf '%s\n' "# sudo_local: local config for sudo" "$TID_LINE" > "$SUDO_LOCAL"
  fi
  chmod 644 "$SUDO_LOCAL"
}

install_module() {
  if [[ -z "$MODULE_SRC" || ! -f "$MODULE_SRC" ]]; then
    echo "missing pam_glance.so source" >&2
    exit 1
  fi
  mkdir -p /usr/local/lib/pam
  cp "$MODULE_SRC" "$MODULE_DST"
  chmod 755 "$MODULE_DST"

  ensure_sudo_local

  TMP="$(mktemp)"
  # Drop any existing pam_glance lines.
  grep -v 'pam_glance\.so' "$SUDO_LOCAL" > "$TMP" || true

  # Ensure an uncommented pam_tid line exists.
  if ! grep -Eq '^[[:space:]]*auth[[:space:]].*pam_tid\.so' "$TMP"; then
    if grep -Eq '^[[:space:]]*#auth[[:space:]].*pam_tid\.so' "$TMP"; then
      sed -i '' 's/^[[:space:]]*#auth\(.*pam_tid\.so\)/auth\1/' "$TMP"
    else
      printf '%s\n' "$TID_LINE" >> "$TMP"
    fi
  fi

  # Insert pam_glance before the first auth line.
  # Write via a file in /tmp then cp (mv from mktemp can hit SIP/TCC denies on /etc/pam.d).
  TMP2="/tmp/sudo_local.glance.$$"
  INSERTED=0
  : > "$TMP2"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ $INSERTED -eq 0 && "$line" =~ ^[[:space:]]*auth ]]; then
      printf '%s\n' "$GLANCE_LINE" >> "$TMP2"
      INSERTED=1
    fi
    printf '%s\n' "$line" >> "$TMP2"
  done < "$TMP"
  if [[ $INSERTED -eq 0 ]]; then
    printf '%s\n' "$GLANCE_LINE" >> "$TMP2"
  fi
  cp "$TMP2" "$SUDO_LOCAL"
  chmod 644 "$SUDO_LOCAL"
  rm -f "$TMP" "$TMP2"
  echo "installed"
}

uninstall_module() {
  if [[ -f "$SUDO_LOCAL" ]]; then
    TMP="$(mktemp)"
    grep -v 'pam_glance\.so' "$SUDO_LOCAL" > "$TMP" || true
    mv "$TMP" "$SUDO_LOCAL"
    chmod 644 "$SUDO_LOCAL"
  fi
  echo "uninstalled"
}

case "$ACTION" in
  install) install_module ;;
  uninstall) uninstall_module ;;
  *)
    echo "usage: $0 install <pam_glance.so> | uninstall" >&2
    exit 1
    ;;
esac
