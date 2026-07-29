# Change mount options and remount (no reboot)

Example use-case: remove `noexec` from `/tmp`.

## Steps

1. Edit `/etc/fstab`.

   ```bash
   sudo vi /etc/fstab
   ```

2. Find the mount entry and adjust options.

   Example line:

   ```fstab
   UUID=<uuid> /tmp tmpfs defaults,noexec,nosuid,nodev 0 0
   ```

   If you want to allow execution, remove `noexec`:

   ```fstab
   UUID=<uuid> /tmp tmpfs defaults,nosuid,nodev 0 0
   ```

3. Remount the target.

   ```bash
   sudo mount -o remount /tmp
   mount | grep ' /tmp '
   ```
