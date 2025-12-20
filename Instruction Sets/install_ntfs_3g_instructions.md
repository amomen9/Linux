# Install NTFS support (`ntfs-3g`) on Ubuntu/Debian

This enables read/write access to NTFS partitions.

```bash
sudo apt update
sudo apt install -y ntfs-3g libntfs-3g88
```

Verify:

```bash
ntfs-3g --version
```
