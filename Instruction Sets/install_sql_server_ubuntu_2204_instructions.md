# Install Microsoft SQL Server on Ubuntu 22.04

This installs SQL Server 2022 via Microsoft’s apt repository.

## Steps

1. Add Microsoft key and repo.

   ```bash
   curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg || true

   # If the above fails, use the legacy trusted key placement:
   curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc >/dev/null

   curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list \
     | sudo tee /etc/apt/sources.list.d/mssql-server-2022.list >/dev/null
   ```

2. Install and run setup.

   ```bash
   sudo apt-get update
   sudo apt-get install -y mssql-server
   sudo /opt/mssql/bin/mssql-conf setup
   ```

3. Verify service.

   ```bash
   systemctl status mssql-server --no-pager
   ```

4. Enable SQL Agent (optional).

   ```bash
   sudo /opt/mssql/bin/mssql-conf set sqlagent.enabled true
   sudo systemctl restart mssql-server
   ```

5. Change TCP port (optional).

   ```bash
   sudo /opt/mssql/bin/mssql-conf set network.tcpport 33333
   sudo systemctl restart mssql-server
   ```

## Useful paths

- Config: `/var/opt/mssql/mssql.conf`
- Logs: `/var/opt/mssql/log/`
- Binaries: `/opt/mssql/bin/sqlservr`, `/opt/mssql/bin/mssql-conf`
