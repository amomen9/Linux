# Boot into a specific systemd target (rescue, multi-user, graphical)

This is useful when you need to boot without a full GUI (or into rescue mode), then switch back.

## Temporary: boot once into `rescue.target`

1. At the GRUB boot menu, highlight your boot entry.
2. Press `e` to edit.
3. Find the line that begins with `linux` (or `linuxefi`).
4. Append one of these:

   - `systemd.unit=rescue.target`
   - `systemd.unit=multi-user.target`

5. Boot with `Ctrl+x`.

## After boot: start key services and switch target

```bash
sudo systemctl start sshd
sudo systemctl start NetworkManager

# Switch to multi-user (no GUI)
sudo systemctl isolate multi-user.target

# Check active targets
systemctl is-active graphical.target
systemctl list-units --type target --state active
```
