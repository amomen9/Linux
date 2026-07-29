# Install Ookla Speedtest CLI (`speedtest`) on Linux

This guide installs the official Ookla Speedtest CLI.

## Ubuntu/Debian (recommended: official repo script)

1. Install prerequisites.

   ```bash
   sudo apt update
   sudo apt install -y curl
   ```

2. Add the repository and install.

   ```bash
   curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
   sudo apt install -y speedtest
   ```

## RHEL/Rocky (official repo script)

```bash
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | sudo bash
sudo dnf install -y speedtest || sudo yum install -y speedtest
```

## Usage

```bash
speedtest

# List servers and filter
speedtest --servers | head

# If you are using the legacy `speedtest-cli` python tool, the flags differ.
```

## Sample download files for testing

```bash
wget http://ipv4.download.thinkbroadband.com/200MB.zip
```
