# Install GUI + XRDP (Ubuntu and Rocky/RHEL)

This sets up Remote Desktop Protocol access.

## Ubuntu

1. Install a desktop environment.

   ```bash
   sudo apt update
   sudo apt install -y ubuntu-desktop-minimal
   ```

   If you need to avoid prompts (common on minimal/cloud installs), you can use noninteractive upgrades:

   ```bash
   sudo DEBIAN_FRONTEND=noninteractive apt update -y
   sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
   ```

2. Install and start XRDP.

   ```bash
   sudo apt install -y xrdp
   sudo systemctl enable --now xrdp
   sudo systemctl status xrdp --no-pager
   ```

3. Optional: create groups and add your user.

   ```bash
   sudo addgroup tsusers || true
   sudo addgroup tsadmins || true
   sudo usermod -aG tsusers "$USER"
   sudo systemctl restart xrdp
   ```

4. Allow RDP in UFW.

   ```bash
   sudo ufw allow 3389/tcp
   sudo ufw reload
   sudo ufw status
   ```

5. Reboot, then connect using Windows “Remote Desktop Connection”.

## Rocky/RHEL

1. Install EPEL (often required) and GUI group.

   ```bash
   sudo dnf install -y epel-release || true
   sudo dnf groupinstall -y "Server with GUI"
   ```

2. Install XRDP.

   ```bash
   sudo dnf install -y xrdp
   ```

3. (If required) disable SELinux (only if you accept the security tradeoff).

   ```bash
   sudo vi /etc/selinux/config
   # set: SELINUX=disabled
   sudo reboot
   ```

4. Choose a session.

   ```bash
   echo gnome-session >> ~/.xsession
   # KDE example (requires KDE packages):
   # echo kde-session > ~/.xsession
   ```

5. Enable XRDP.

   ```bash
   sudo systemctl enable --now xrdp
   ```
