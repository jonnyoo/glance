# Face-for-sudo PAM module

Built automatically by the Glance Xcode target (`Embed pam_glance` build phase).

Manual build:

```bash
make -C pam_glance
```

## Cascade

1. Face (Glance running, session unlocked)  
2. Touch ID (`pam_tid.so`)  
3. Password  

## Enable

1. Unlock the Glance session (menu bar).  
2. Settings → General → **Face for sudo**.  
3. Approve the admin prompt to install the PAM module into `/usr/local/lib/pam` and `/etc/pam.d/sudo_local`.

If the in-app installer cannot write `sudo_local` (macOS restriction), from a Terminal with this repo:

```bash
make -C pam_glance
sudo ./pam_glance/install.sh install ./pam_glance/pam_glance.so
```

## Test

With Glance unlocked and Face for sudo on:

```bash
ls /tmp/com.jonathan.glance.sudoauth.*
sudo -k && sudo -v
```
