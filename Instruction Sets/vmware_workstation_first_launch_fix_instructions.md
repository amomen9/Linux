# Fix VMware Workstation “Kernel Module Updater” errors on first launch (Ubuntu)

Common errors:

- GCC not found
- “C header files matching your running kernel were not found”

## Steps

1. Install compiler toolchain.

   ```bash
   sudo apt update
   sudo apt install -y gcc make build-essential
   ```

2. Install kernel headers for the running kernel.

   ```bash
   sudo apt install -y linux-headers-$(uname -r)
   ```

   WSL note: `uname -r` may not match Ubuntu header package names (example: `6.6.87.1-microsoft-standard-WSL2`).
   In that case you must install a compatible `linux-headers-<version>-generic` package (or update to a kernel that has headers available).

3. Retry VMware.

If VMware asks for a specific GCC path, a common one is:

```text
/usr/bin/gcc
```
