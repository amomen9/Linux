# Create an SSH reverse tunnel with `autossh` + systemd

This pattern keeps a reverse tunnel stable and exposes it via `socat` if needed.

Terminology:

- `Server R`: the **remote** machine behind NAT that initiates the tunnel.
- `Server P`: the **public** machine that receives the tunnel.

## 1) On Server R (tunnel initiator)

1. Install `autossh`.

   ```bash
   sudo apt update
   sudo apt install -y autossh
   ```

2. Create a dedicated key (no passphrase if fully automated).

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/tunnel_key -C ""
   ```

3. Copy the public key to Server P.

   ```bash
   ssh-copy-id -i ~/.ssh/tunnel_key.pub -p <server_p_ssh_port> user@server-p
   ```

4. Create a systemd service.

   ```bash
   sudo tee /etc/systemd/system/autossh-tunnel.service > /dev/null <<'EOF'
   [Unit]
   Description=AutoSSH Tunnel to Server P
   After=network.target

   [Service]
   User=<local_user>
   ExecStart=/usr/bin/autossh -M 0 -N \
     -o "ExitOnForwardFailure=yes" \
     -o "ServerAliveInterval=30" \
     -o "ServerAliveCountMax=3" \
     -R <server_p_socat_port>:localhost:<server_r_ssh_port> \
     -i /home/<local_user>/.ssh/tunnel_key \
     user@server-p -p <server_p_ssh_port>
   Restart=always
   RestartSec=3

   [Install]
   WantedBy=multi-user.target
   EOF
   ```

5. Enable.

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now autossh-tunnel
   sudo systemctl status autossh-tunnel --no-pager
   ```

## 2) On Server P (public receiver)

1. Allow the tunnel to be reachable externally (optional).

   Edit `/etc/ssh/sshd_config`:

   ```text
   GatewayPorts yes
   ```

   Validate and restart:

   ```bash
   sudo sshd -t
   sudo systemctl restart ssh || sudo systemctl restart sshd
   ```

2. Install `socat`.

   ```bash
   sudo apt update
   sudo apt install -y socat
   ```

3. Create a port-forwarding service that exposes the tunnel.

   ```bash
   sudo tee /etc/systemd/system/public-tunnel.service > /dev/null <<'EOF'
   [Unit]
   Description=Expose Tunnel on Public Port
   After=network.target

   [Service]
   ExecStart=/bin/sh -c "socat TCP-LISTEN:<public_port>,reuseaddr,fork TCP:localhost:<server_p_socat_port>"
   Restart=always
   RestartSec=3

   [Install]
   WantedBy=multi-user.target
   EOF
   sudo systemctl daemon-reload
   sudo systemctl enable --now public-tunnel
   ```

4. Firewall on Server P.

   Example (UFW):

   ```bash
   sudo ufw allow <public_port>/tcp
   sudo ufw status
   ```

## 3) Client usage

```bash
ssh -p <public_port> <server_r_user>@server-p
```
