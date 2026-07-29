# SSH server configuration (allow root, deny users, validate config)

This guide covers common `sshd` settings and safe validation.

## Steps

1. Edit the SSH server config.

   ```bash
   sudo nano /etc/ssh/sshd_config
   ```

2. Apply settings (examples).

   ```text
   # Allow or disallow root login
   PermitRootLogin yes

   # Deny one or multiple users
   DenyUsers alice
   DenyUsers user1 user2 user3
   ```

   Tip: Keep related rules grouped together and avoid duplicate directives.

3. Validate the configuration **before** restarting.

   ```bash
   sudo sshd -t
   ```

4. Restart the service.

   ```bash
   sudo systemctl restart sshd
   ```

5. If changes do not take effect (socket-activated SSH)

   Some systems use `ssh.socket`.

   ```bash
   sudo systemctl disable --now ssh.socket 2>/dev/null || true
   sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd
   ```

## Remote command pattern

```bash
ssh user@host 'command'
```

Connection info from within a session:

```bash
echo "$SSH_CLIENT"
echo "$SSH_CONNECTION"
```
