# Install Browsh (terminal browser)

## Debian/Ubuntu

```bash
wget -O browsh.deb https://github.com/browsh-org/browsh/releases/download/v1.8.0/browsh_1.8.0_linux_amd64.deb
sudo apt update
sudo apt install -y ./browsh.deb
rm -f browsh.deb

browsh
```

## RHEL/Rocky

```bash
curl -L -o browsh.rpm https://github.com/browsh-org/browsh/releases/download/v1.8.0/browsh_1.8.0_linux_amd64.rpm
sudo rpm -Uvh ./browsh.rpm
rm -f browsh.rpm

browsh
```
