# Make DNS configuration static by replacing `/etc/resolv.conf`

NetworkManager/systemd-resolved can overwrite DNS servers. One workaround is to replace the `/etc/resolv.conf` symlink with a static file.

## Steps

1. Check what `/etc/resolv.conf` is.

   ```bash
   ls -la /etc/resolv.conf
   ```

2. If it is a symlink, back it up and replace it.

   ```bash
   sudo cp -a /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
   sudo rm -f /etc/resolv.conf
   ```

3. Create a new static file.

   ```bash
   sudo tee /etc/resolv.conf >/dev/null <<'EOF'
   nameserver 10.30.20.1
   nameserver 1.1.1.1
   nameserver 8.8.8.8
   EOF
   ```

4. Verify.

   ```bash
   cat /etc/resolv.conf
   ping -c 2 google.com
   ```

Note: This trades “dynamic DNS” for “static DNS”. If you use VPNs, split DNS, or changing networks, this may not be desirable.
