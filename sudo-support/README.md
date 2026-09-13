# Glance sudo integration

`pam_glance.so` adds Glance face recognition before Apple's existing Touch ID,
smart-card, and password authentication modules. It never stores or types a
password for `sudo`.

The module accepts a response only from the root-owned executable at
`/Applications/Glance.app/Contents/MacOS/glance`. It verifies the Unix
socket peer's user and process path, requires a fresh 256-bit nonce in every
successful response, rejects remote PAM sessions, and treats every error as an
authentication failure so the system falls through to Apple's normal methods.

## Install

Glance must be installed at `/Applications/Glance.app`, owned by `root`, and
not writable by group or other users. Build and install the PAM module with:

```zsh
clang -Wall -Wextra -Werror -bundle \
  -o sudo-support/pam_glance.so sudo-support/pam_glance.c -lpam
sudo chown -R root:wheel /Applications/Glance.app
sudo chmod -R go-w /Applications/Glance.app
sudo sudo-support/install.sh
```

Then open **Glance Settings → Sudo** and enable **Authenticate sudo with
Glance**. The setting is off by default because installing the PAM module is a
separate privileged operation. Glance's protected session must already be
unlocked; the app does not create a surprise Touch ID prompt from a `sudo`
request. If the session is locked, macOS immediately continues to its normal
authentication methods.

Run `sudo sudo-support/uninstall.sh` to remove only the Glance PAM rule and
module. Apple's Touch ID and password configuration remains unchanged.
