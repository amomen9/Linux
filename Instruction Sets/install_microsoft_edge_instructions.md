# Install Microsoft Edge on Linux (Ubuntu and RHEL)

## Ubuntu

1. Add Microsoft signing key and repo.

   ```bash
   sudo apt update
   sudo apt install -y wget gpg

   wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
     | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/microsoft.gpg

   echo "deb [arch=amd64] https://packages.microsoft.com/repos/edge stable main" \
     | sudo tee /etc/apt/sources.list.d/microsoft-edge.list >/dev/null
   ```

2. Install.

   ```bash
   sudo apt update
   sudo apt install -y microsoft-edge-stable
   ```

3. Run.

   ```bash
   microsoft-edge 2>/dev/null &
   ```

## RHEL/Rocky

```bash
sudo dnf install -y wget || sudo yum install -y wget
sudo wget -O packages-microsoft-prod.rpm https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm
sudo rpm -Uvh packages-microsoft-prod.rpm
sudo rm -f packages-microsoft-prod.rpm

sudo dnf install -y microsoft-edge-stable || sudo yum install -y microsoft-edge-stable
```

## If you are on SSH and need X11

If you see `cannot open display`, ensure X11 forwarding is enabled on your SSH client/server.

Quick checks:

```bash
echo "$DISPLAY"
command -v xauth && xauth list || true
```
