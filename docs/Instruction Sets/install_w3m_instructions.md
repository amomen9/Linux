# Install `w3m` (terminal web browser)

## RHEL/Rocky/Alma

1. Ensure EPEL is enabled.

   See [Install EPEL on RHEL 9](install_epel_rhel9_instructions.md).

2. Install `w3m`.

   ```bash
   sudo dnf install -y w3m || sudo yum install -y w3m
   ```

## Ubuntu/Debian

```bash
sudo apt update
sudo apt install -y w3m
```

## Usage

```bash
w3m https://example.com
```
