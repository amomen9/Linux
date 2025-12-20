# Install Firefox via Snap and fix common X11 permission issues

## Install

```bash
sudo snap install firefox
```

## If Firefox fails with X11 errors

Example errors:

- `MoTTY X11 proxy: No authorisation provided`
- `Error: cannot open display: localhost:11.0`

1. Connect the required snap interfaces.

   ```bash
   sudo snap connect firefox:x11
   sudo snap connect firefox:desktop
   sudo snap connect firefox:desktop-legacy
   ```

2. Ensure X authority file is set.

   ```bash
   export XAUTHORITY=$HOME/.Xauthority
   ```

3. Run.

   ```bash
   firefox
   ```
