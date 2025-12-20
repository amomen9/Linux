# Ubuntu: Configure a Static IP with `netplan` (Subiquity)

This guide configures a static IPv4 address using `netplan` (common on Ubuntu Server installs).

## Prerequisites

- You know your `interface` name (example: `ens33`).
- You know your `IP`, `prefix`, `gateway`, and `DNS` servers.

## Steps

1. Identify the interface name.

   ```bash
   ip -br link
   ip a
   ```

2. Edit your netplan file.

   Common locations:
   - `/etc/netplan/00-installer-config.yaml`
   - `/etc/netplan/50-cloud-init.yaml`

   ```bash
   sudo ls -la /etc/netplan/
   sudo nano /etc/netplan/00-installer-config.yaml
   ```

3. Apply a configuration similar to the following.

   ```yaml
   # This is the network config written by 'subiquity'
   network:
     version: 2
     ethernets:
       ens33:
         dhcp4: false
         addresses: [192.168.241.203/24]
         routes:
           - to: default  # 'default' works on newer Ubuntu; 0.0.0.0/0 also works.
             via: 192.168.241.2
             on-link: true
         nameservers:
           addresses: [8.8.8.8, 8.8.4.4]
           search: [Home.local]
   ```

   Notes:
   - Prefer `routes:` (newer syntax) instead of `gateway4:`.
   - Keep YAML indentation exact.

4. Validate and apply.

   ```bash
   sudo netplan generate
   sudo netplan apply
   ```

5. Verify.

   ```bash
   ip route
   resolvectl status 2>/dev/null || true
   ping -c 3 8.8.8.8
   ping -c 3 google.com
   ```

If DNS still fails (but IP ping works), see [Ubuntu: Fix DNS via resolvconf](ubuntu_fix_dns_resolvconf_instructions.md).
