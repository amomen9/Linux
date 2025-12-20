# Install X2Go (server and client) on Ubuntu

X2Go provides remote desktop sessions over SSH.

## Steps

1. Enable the X2Go PPA.

   ```bash
   sudo apt update
   sudo apt install -y software-properties-common
   sudo apt-add-repository -y ppa:x2go/stable
   sudo apt update
   ```

2. Install X2Go server.

   ```bash
   sudo apt install -y x2goserver x2goserver-xsession

   # Desktop bindings (optional, pick your desktop)
   sudo apt install -y x2gomatebindings || true
   sudo apt install -y x2golxdebindings || true
   ```

3. Install X2Go client.

   ```bash
   sudo apt install -y x2goclient
   ```
