# Change GRUB boot timeout (RHEL family)

## Steps

1. Edit the default GRUB config.

   ```bash
   sudo vi /etc/default/grub
   ```

   Set:

   ```text
   GRUB_TIMEOUT=5
   ```

2. Regenerate the GRUB config.

   ```bash
   sudo grub2-mkconfig -o /boot/grub2/grub.cfg
   ```

3. Reboot to test.

   ```bash
   sudo reboot
   ```
