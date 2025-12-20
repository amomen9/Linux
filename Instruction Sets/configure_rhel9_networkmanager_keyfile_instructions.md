# RHEL 9: Configure networking by editing NetworkManager keyfiles

On RHEL 9, persistent NetworkManager connections are stored as keyfiles under:

- `/etc/NetworkManager/system-connections/`

## Steps

1. List existing connection profiles.

   ```bash
   sudo ls -la /etc/NetworkManager/system-connections/
   nmcli connection show
   ```

2. Edit the keyfile for your interface (example: `ens192.nmconnection`).

   ```bash
   sudo vi /etc/NetworkManager/system-connections/ens192.nmconnection
   ```

3. Example keyfile (static IPv4).

   ```ini
   [connection]
   id=ens192
   uuid=9a10039f-1b50-3558-b7ff-5ef56bc8772a
   type=ethernet
   interface-name=ens192

   [ipv4]
   address1=192.168.100.51/24,192.168.100.15
   dns=192.168.100.10;
   dns-search=Home.local;
   method=manual

   [ipv6]
   method=auto
   ```

4. Reload the connection profiles.

   ```bash
   sudo nmcli connection reload
   sudo nmcli connection down ens192 || true
   sudo nmcli connection up ens192
   ```

5. Verify.

   ```bash
   ip a
   ip route
   nmcli dev show ens192
   ```

Tip: You can also do everything with `nmcli` (recommended for less risk).
