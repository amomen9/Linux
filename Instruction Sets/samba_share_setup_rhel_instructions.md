# RHEL/Rocky: Set up Samba (SMB) share for Windows + Linux clients

This guide configures a Samba server and shows how to access shares from Windows and from Linux.

## Server (RHEL/Rocky/Alma)

1. Install Samba.

   ```bash
   sudo dnf install -y samba
   ```

2. Create the shared directory.

   ```bash
   sudo mkdir -p /srv/shares/exampleShare
   sudo chown -R root:root /srv/shares
   sudo chmod -R 2770 /srv/shares/exampleShare
   ```

3. Configure `/etc/samba/smb.conf`.

   ```bash
   sudo cp -a /etc/samba/smb.conf /etc/samba/smb.conf.bak
   sudo vi /etc/samba/smb.conf
   ```

   Append a share definition:

   ```ini
   [exampleShare]
   path = /srv/shares/exampleShare
   browseable = yes
   writable = yes
   guest ok = no
   valid users = sambauser
   write list = sambauser
   ```

   Reference: `smb.conf(5)`
   - https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html

4. SELinux (common requirement on RHEL).

   ```bash
   sudo setsebool -P samba_enable_home_dirs on
   sudo getsebool samba_enable_home_dirs
   ```

   If you share a custom path (like `/srv/shares`), you may also need an SELinux label.

5. Create / enable a Samba user.

   ```bash
   sudo useradd -m sambauser 2>/dev/null || true
   sudo passwd sambauser
   sudo smbpasswd -a sambauser

   # List Samba users
   sudo pdbedit -L -v
   ```

6. Start and enable services.

   ```bash
   sudo systemctl enable --now smb
   sudo systemctl status smb --no-pager
   ```

7. Firewall.

   ```bash
   sudo firewall-cmd --add-service=samba --permanent
   sudo firewall-cmd --add-port={139/tcp,445/tcp} --permanent
   sudo firewall-cmd --reload
   ```

## Client (Linux)

1. Install client tools.

   ```bash
   sudo dnf install -y samba-client cifs-utils
   ```

2. List shares.

   ```bash
   smbclient -L //192.168.171.1/ -U sambauser
   ```

3. Mount a share.

   ```bash
   sudo mkdir -p /mnt/windows_share
   sudo mount -t cifs //192.168.171.1/exampleShare /mnt/windows_share \
     -o username=sambauser,uid=$UID
   ```

Unmount:

```bash
sudo umount /mnt/windows_share
```
