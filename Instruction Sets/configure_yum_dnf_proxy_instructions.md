# Configure a proxy for `yum`/`dnf` (RHEL/Rocky/CentOS)

Use this when your system must reach repositories through an HTTP or SOCKS proxy.

## Steps

1. Edit the config file:

   - `dnf`: `/etc/dnf/dnf.conf`
   - `yum`: `/etc/yum.conf`

   ```bash
   sudo vi /etc/dnf/dnf.conf
   ```

2. Add a `[main]` block (or extend the existing one).

   ```ini
   [main]
   proxy=http://<proxy-host>:<proxy-port>
   # OR: proxy=socks://<proxy-host>:<proxy-port>

   # Optional authentication
   proxy_username=<proxy-username>
   proxy_password=<proxy-password>
   ```

   Example:

   ```ini
   [main]
   proxy=http://192.168.171.15:10811
   proxy_username=your_user
   proxy_password=your_password
   ```

3. Test repo access.

   ```bash
   sudo dnf clean all
   sudo dnf repolist
   sudo dnf makecache
   ```

Tip: For one-off commands you can also use env vars:

```bash
export http_proxy=http://192.168.171.1:18444/
export https_proxy=http://192.168.171.1:18444/
```
