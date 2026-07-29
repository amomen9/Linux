# Install Chrome Remote Desktop on Ubuntu

Chrome Remote Desktop relies on X components that are sometimes missing on minimal installs.

## Steps

1. Download the package.

   ```bash
   wget -O chrome-remote-desktop.deb \
     https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb
   ```

2. Install dependencies (common missing ones).

   ```bash
   sudo apt update
   sudo apt install -y xvfb xserver-xorg-video-dummy xbase-clients python3-packaging python3-psutil
   ```

3. Install the `.deb`.

   ```bash
   sudo apt install -y ./chrome-remote-desktop.deb
   rm -f chrome-remote-desktop.deb
   ```

If installation reports broken deps, run:

```bash
sudo apt-get -f install -y
```
