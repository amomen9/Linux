# Ubuntu: Fix DNS when you get “Temporary failure in name resolution”

This is a common symptom when DNS servers are missing or being overwritten.

## Quick checks

```bash
# Works? If yes, networking is fine and DNS is the problem.
ping -c 2 8.8.8.8

# Fails? Then it is not just DNS.
ip route
```

## Option A (preferred): Configure DNS in `netplan`

1. Add `nameservers:` inside your interface block in the netplan YAML.
2. Apply:

   ```bash
   sudo netplan generate
   sudo netplan apply
   ```

See [Ubuntu: Configure a Static IP with netplan](ubuntu_netplan_static_ip_instructions.md).

## Option B: Use `resolvconf` to manage `/etc/resolv.conf`

1. Install and enable `resolvconf`.

   ```bash
   sudo apt update
   sudo apt install resolvconf -y
   sudo systemctl enable --now resolvconf
   ```

2. Edit the `head` template and add your DNS servers.

   ```bash
   sudo nano /etc/resolvconf/resolv.conf.d/head
   ```

   Example:

   ```text
   nameserver 8.8.8.8
   nameserver 8.8.4.4

   nameserver 192.168.100.10
   search Home.local
   ```

3. Restart and regenerate `resolv.conf`.

   ```bash
   sudo systemctl restart resolvconf.service
   sudo systemctl restart systemd-resolved.service
   sudo resolvconf --enable-updates
   sudo resolvconf -u
   ```

4. Verify.

   ```bash
   cat /etc/resolv.conf
   ping -c 2 google.com
   ```

## If `/etc/resolv.conf` is immutable

```bash
lsattr /etc/resolv.conf
sudo chattr -i /etc/resolv.conf
```
