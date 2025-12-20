# Disable cloud-init network configuration (keep netplan persistent)

Some cloud images regenerate netplan on reboot. To stop cloud-init from managing networking:

## Steps

1. Create the disable file.

   ```bash
   sudo mkdir -p /etc/cloud/cloud.cfg.d
   sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null <<'EOF'
   network: {config: disabled}
   EOF
   ```

2. Check your current netplan file (often `/etc/netplan/50-cloud-init.yaml`).

   ```bash
   sudo ls -la /etc/netplan/
   ```

3. Put your desired netplan config in a separate file (recommended), then apply:

   ```bash
   sudo netplan generate
   sudo netplan apply
   ```

4. Reboot to confirm it persists.

   ```bash
   sudo reboot
   ```
