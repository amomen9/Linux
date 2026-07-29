# Install Midori browser (Snap or Flatpak)

## Option A: Snap (Ubuntu)

```bash
sudo snap install midori
sudo snap refresh midori
```

## Option B: Flatpak

```bash
sudo apt update
sudo apt install -y flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

# Install
flatpak install flathub org.midori_browser.Midori

# Update
flatpak update
```

## RHEL note (Snap)

Snap support on RHEL often requires extra setup. Follow the official instructions:

- https://snapcraft.io/install/midori/rhel
