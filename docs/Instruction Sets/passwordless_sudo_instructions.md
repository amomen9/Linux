# Set up passwordless sudo (carefully)

Passwordless sudo increases risk. Prefer limiting it to specific commands.

## Recommended: Use `/etc/sudoers.d/`

1. Create a drop-in file using `visudo` (safer validation).

   ```bash
   sudo visudo -f /etc/sudoers.d/99-nopasswd
   ```

2. Add one of the following.

   Full passwordless sudo (broad):

   ```text
   username ALL=(ALL) NOPASSWD: ALL
   ```

   Or restrict to specific commands:

   ```text
   username ALL=(ALL) NOPASSWD: /usr/sbin/ip addr add, /usr/sbin/ip addr del
   ```

3. Validate quickly.

   ```bash
   sudo -l
   ```

## Why `sudo echo >> /etc/sudoers` is wrong

Because `>>` is handled by your shell **before** `sudo` is applied.

If you must append from a command, use `tee`:

```bash
echo 'username ALL=(ALL) NOPASSWD: ALL' | sudo tee -a /etc/sudoers.d/99-nopasswd > /dev/null
```
