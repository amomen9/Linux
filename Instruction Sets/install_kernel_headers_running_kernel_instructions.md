# Install kernel headers for the running kernel

This is needed for building kernel modules (e.g., VMware tools, DKMS modules).

## RHEL/Rocky/Alma

```bash
sudo dnf install -y kernel-devel
ls -la /usr/src/kernels/
```

## Ubuntu/Debian

```bash
sudo apt update
sudo apt install -y linux-headers-$(uname -r)
```
