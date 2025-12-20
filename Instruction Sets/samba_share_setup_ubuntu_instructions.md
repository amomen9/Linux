# Ubuntu: Set up Samba (SMB) share for Windows + Linux clients

## Server (Ubuntu)

1. Install Samba.

   ```bash
   sudo apt update
   sudo apt install -y samba samba-common samba-common-bin
   ```

2. Verify binaries.

   ```bash
   whereis samba
   ```

3. Create a shared directory.

   ```bash
   mkdir -p /home/$USER/sambashare
   chmod 2770 /home/$USER/sambashare
   ```

4. Configure `/etc/samba/smb.conf`.

   ```bash
   sudo cp -a /etc/samba/smb.conf /etc/samba/smb.conf.bak
   sudo nano /etc/samba/smb.conf
   ```

   Add a share definition:

   ```ini
   [exampleShare]
   path = /home/your_username/sambashare
   browseable = yes
   writable = yes
   guest ok = no
   valid users = your_username
   ```

5. Set a Samba password for your user.

   ```bash
   sudo smbpasswd -a "$USER"
   ```

6. Start and enable Samba.

   ```bash
   sudo systemctl enable --now smbd
   sudo systemctl status smbd --no-pager
   ```

## Client (Ubuntu/Linux)

1. Install client packages.

   ```bash
   sudo apt update
   sudo apt install -y samba-client cifs-utils
   ```

2. List shares.

   ```bash
   smbclient -L //192.168.171.1/ -U your_username
   ```

3. Mount a share (interactive password prompt).

   ```bash
   sudo mkdir -p /mnt/windows_share
   sudo mount -t cifs -o username=your_username //WINDOWS_IP/SHARE_NAME /mnt/windows_share
   ```

4. Make it persistent (safer method with a credentials file).

   Create `/etc/samba/creds_exampleShare`:

   ```bash
   sudo tee /etc/samba/creds_exampleShare >/dev/null <<'EOF'
   username=your_username
   password=your_password
   EOF
   sudo chmod 600 /etc/samba/creds_exampleShare
   ```

   Then add to `/etc/fstab`:

   ```fstab
   //WINDOWS_IP/SHARE_NAME /mnt/windows_share cifs credentials=/etc/samba/creds_exampleShare,_netdev,uid=1000,gid=1000 0 0
   ```

   Test:

   ```bash
   sudo mount -a
   ```

Unmount if busy:

```bash
sudo lsof /mnt/windows_share || true
sudo umount /mnt/windows_share
```
