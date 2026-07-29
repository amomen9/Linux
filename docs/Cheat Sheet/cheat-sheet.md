# Linux Cheat Sheet (Commands & Examples)

This document consolidates the **command-style** content (examples, flags, and quick snippets) from the original cheat sheet.

If you are looking for **step-by-step setup guides**, see the instruction docs under [`Instruction Sets/`](../Instruction%20Sets/) (linked throughout this page).

---

## Contents

- [System info](#system-info)
- [Files, paths, and permissions](#files-paths-and-permissions)
- [Search and text processing](#search-and-text-processing)
- [Archives and compression](#archives-and-compression)
- [Package managers](#package-managers)
- [Time and date](#time-and-date)
- [Users and groups](#users-and-groups)
- [Networking](#networking)
- [SSH and file transfer](#ssh-and-file-transfer)
- [Firewall](#firewall)
- [systemd and logs](#systemd-and-logs)
- [Terminal productivity](#terminal-productivity)
- [Shell scripting essentials](#shell-scripting-essentials)
- [Editors](#editors)

---

## System info

```bash
# Architecture / distro information
echo "You are using $(getconf LONG_BIT) bit Linux distro."
uname -m
uname -a
grep VERSION /etc/os-release
cat /etc/os-release
cat /etc/*-release
cat /etc/*-version
```

Generate a new UUID:

```bash
uuidgen <ifname>
```

---

## Files, paths, and permissions

Working directory:

```bash
pwd
```

Create symbolic links:

```bash
# ln -s <target> <link>
ln -s /usr/libexec/xrdp/startwm.sh /etc/xrdp/startwm.sh

# Change the target of a symbolic link
ln -sfT /path/to/new/target linkname
```

Inspect a file type:

```bash
file ./setup_repository
```

Show numeric permissions:

```bash
stat -c '%a %n' file1.txt
```

Permission code reminder:

| Digit | Meaning | Bits |
| ---: | --- | --- |
| 0 | none | 000 |
| 1 | execute | 001 |
| 2 | write | 010 |
| 3 | write + execute | 011 |
| 4 | read | 100 |
| 5 | read + execute | 101 |
| 6 | read + write | 110 |
| 7 | read + write + execute | 111 |

`umask` example (new files default to `600`):

```bash
umask 077
```

Ownership:

```bash
chown -R mysql:mysql /var/log/mysql/
```

Empty a file:

```bash
truncate -s 0 filename.txt
> filename.txt
```

Create a file:

```bash
touch filename
```

---

## Search and text processing

### `find`

```bash
# Search for names
find . -name "*maria*"
find /path/to/search \( -name "*.html" -o -name "*.py" \)

# Pass found files to a command
find . -name '*.json' -type f -exec cat {} +

# Replace a pattern in many files (test without -i first)
find /path/to/files -type f -exec sed -i 's/old-pattern/new-pattern/g' {} +

# Delete matching files
find . -type f -name "*.qp" -exec rm -v {} \;

# Exclude paths
find -name "*.js" -not -path "/proc/*"
find -name "*.js" -not -path "./directory1/*" -not -path "./directory2/*"
```

### `grep`

```bash
# Search for a string beginning with '-'
grep -- -X file

# Recursive search with useful flags
grep -rnw '/path/to/somewhere/' -e 'pattern'

# Treat pattern as literal (no regex)
grep -Fr 0.49 *

# Example: find effective (non-commented) lines in a config
cat /etc/postgresql/15/main/postgresql.conf | sed 's/^[ \t]*//' | grep -v '^#'
```

### `sed`, `cut`, `awk`

```bash
# Trim leading whitespace
sed 's/^[ \t]*//'

# Remove spaces
sed 's/ //g'

# Cut fields
command | cut -d' ' -f2-
command | cut -d',' --complement -f2

# Simple awk examples
awk -F'&' '{print $2}'
wc -l
```

Decode a URL (function + example):

```bash
urldecode() {
  : "${*//+/ }"
  echo -e "${_//%/\\x}"
}

url=$(urldecode "http%3A%2F%2Fwww.example.com%2Fpath%3Fquery%3Dvalue")
echo "$url"
```

Pipeline-style decode trick:

```bash
... | sed 's/%/\\x/g' | xargs -0 printf "%b"
```

---

## Archives and compression

```bash
# Extract specific files
tar --extract --file=collection.tar <file1> <file2>

# Extract an archive
tar -xvf /home/data/mariadb-10.5.11-rhel-8-x86_64-rpms.tar

# gzip
gzip -d file.gz
gunzip file.gz

# zip
zip myarchive.zip myfile1.txt myfile2.txt
zip -r myarchive.zip directory1/ directory2/
zip -r myarchive.zip mydirectory/ -x '*.mp4'
zip -e myarchive.zip myfile.txt
```

---

## Package managers

### YUM / DNF (RHEL family)

Quick pointers:

- Repos live under `/etc/yum.repos.d/`.
- Cache defaults: `yum` → `/var/cache/yum`, `dnf` → `/var/cache/dnf`.

Common commands:

```bash
yum list [all]
yum search <keyword>
yum info <package>
yum list installed
yum repolist

dnf deplist <package>
```

Install local RPM and resolve dependencies:

```bash
yum localinstall ./google-chrome-stable_current_x86_64.rpm
```

Show duplicates / install a specific version:

```bash
yum --showduplicates list postgresql13-server
yum install firefox-31.5.3-3.el7_1.x86_64
```

Download-only examples:

```bash
# Install yumdownloader
yum install yum-utils -y

# Get package URL
yumdownloader --urls <package-name>

# Download RPMs without installing
yum -y reinstall --downloadonly --downloaddir=. postgresql13-server
dnf download <package-name>
```

Proxy for YUM/DNF: see [set proxy for yum/dnf](../Instruction%20Sets/configure_yum_dnf_proxy_instructions.md).

### RPM

```bash
rpm -qa
rpm -qa --last
rpm -qf /bin/bash
rpm -ivh <packagename>.rpm
rpm --checksig package.rpm
```

GPG keys (import/export):

```bash
gpg -a --export > mypubkeys.asc
gpg -a --export-secret-keys > myprivatekeys.asc
gpg --import mypubkeys.asc
gpg --import myprivatekeys.asc
rpm --import /path/to/YOUR-RPM-GPG-KEY
rpm -qa gpg-pubkey*
```

### APT / DPKG (Debian family)

```bash
apt update
apt upgrade -y
apt list --installed

apt search --names-only docker-ce
apt list --all-versions <package>
sudo apt install <package>=<version>

# Fix broken packages
sudo apt-get -f install
sudo dpkg --configure -a
```

Useful download options:

```bash
apt install --print-uris --reinstall <package>
apt install --print-uris --reinstall --download-only <package>
sudo apt-get install --download-only pppoe
```

Handling `dpkg`/`apt` lock issues safely: see [Resolve APT/DPKG lock errors](../Instruction%20Sets/resolve_apt_dpkg_lock_instructions.md).

Pin/hold packages:

```bash
sudo apt-mark hold <package>
apt-mark showhold
sudo apt-mark unhold <package>
```

### Snap / Flatpak

```bash
snap find <keyword>
snap info <package>
sudo snap install <package>
sudo snap remove <package>
snap refresh <package>
snap list

sudo apt install flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install flathub <app-id>
flatpak update
```

---

## Time and date

```bash
date +%Y-%m-%d\ %H:%M:%S
date "+%Y-%m-%d %T.%N %z"  # shows UTC by default
TZ='Asia/Tehran' date '+%Y-%m-%d %H:%M:%S %z'

# File timestamp
echo "$(TZ='Asia/Tehran' date +%Y-%m-%d-%H%M%S)"

# Convert epoch seconds
date --date='@2147483647'
```

`timedatectl`:

```bash
timedatectl list-timezones
timedatectl list-timezones | grep -i tehran
timedatectl set-timezone Asia/Tehran
timedatectl set-ntp true
```

---

## Users and groups

List users:

```bash
lslogins -u
compgen -u
getent passwd | awk -F: '{print $1}'
```

RHEL: create admin user:

```bash
useradd testadmin
passwd testadmin
usermod -aG wheel testadmin
id testadmin
groups testadmin
```

Ubuntu: create admin user:

```bash
sudo adduser alig
sudo usermod -aG sudo alig
id alig
groups alig
```

Expire a user / password policy:

```bash
sudo chage -E 2024-02-28 -M 30 charlie
```

Useful `usermod` flags:

- `-l` rename
- `-L` lock password
- `-U` unlock
- `-e` set expiration date
- `-s` set shell (e.g., `/sbin/nologin`)
- `-d` home directory (use `-m` to move)

---

## Networking

IP addresses / routes:

```bash
ip a
ip -br link
ip -4 addr show <ifname>

sudo ip addr add 192.168.171.205/24 dev ens33
sudo ip route add default via <gateway> dev ens33
```

Quickly list IPv4 addresses (excluding loopback):

```bash
ip -br link | awk '$1 != "lo" {print $1}' | xargs -I{} ip -4 addr show {} \
  | grep -oP '(?<=inet\s)\d+(\.\d+){3}'
```

`nmcli` basics:

```bash
nmcli device status
nmcli dev show <ifname>
sudo nmcli dev connect <ifname>
sudo nmcli dev disconnect <ifname>
sudo nmcli device set <ifname> managed yes
```

Netplan and DNS setup are documented as step-by-step guides:

- [Ubuntu netplan static IP](../Instruction%20Sets/ubuntu_netplan_static_ip_instructions.md)
- [Fix name resolution (resolvconf)](../Instruction%20Sets/ubuntu_fix_dns_resolvconf_instructions.md)

Proxy environment variables:

```bash
export http_proxy=http://<proxy_server>:<port>/
export https_proxy=http://<proxy_server>:<port>/
export ftp_proxy=http://<proxy_server>:<port>/
export no_proxy="127.0.0.1,localhost"

unset http_proxy https_proxy ftp_proxy no_proxy
```

Package-manager proxy:

- YUM/DNF: [Configure a proxy for yum/dnf](../Instruction%20Sets/configure_yum_dnf_proxy_instructions.md)

---

## SSH and file transfer

SSH basics:

```bash
ssh user@host
ssh user@host 'command'
```

Validate SSH server config:

```bash
sudo sshd -t
```

Step-by-step SSH server configuration:

- [SSH server configuration](../Instruction%20Sets/ssh_server_configuration_instructions.md)

Key generation examples:

```bash
# Linux paths
ssh-keygen -t ed25519 -f /home/ali/keys/my_private_key -C "my-key"

# Windows paths (Git Bash / WSL)
ssh-keygen -t rsa -b 4096 -f "C:\\Users\\Ali\\keys\\my_private_key" -m PEM -C "ali@customhost"
```

Copy keys:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@host
```

SCP examples:

```bash
# Copy directory recursively
scp -rp /DATA/mysql/backups/full-backup1 root@192.168.241.130:/DATA/mysql/backups/

# Use a custom port
scp -P 3131 user@host:/path/to/file /local/destination

# Alternate URI-style syntax
scp scp://user@host:3131/path/to/file /local/destination
```

Rsync examples:

```bash
rsync -av /var/lib/mysql /DATA
rsync -a remote_user@remote_host_or_ip:/opt/media/ /opt/media/
```

Reverse tunnel setup (step-by-step):

- [AutoSSH reverse tunnel with systemd](../Instruction%20Sets/create_ssh_reverse_tunnel_autossh_instructions.md)

---

## Firewall

UFW (Debian/Ubuntu):

```bash
sudo ufw enable
sudo ufw allow 55149/tcp
sudo ufw delete allow 2200/tcp
sudo ufw reload
sudo ufw status
```

firewalld (RHEL):

```bash
sudo firewall-cmd --permanent --add-port=2052/tcp
sudo firewall-cmd --permanent --add-port={80/tcp,443/tcp,9200/tcp}
sudo firewall-cmd --runtime-to-permanent
sudo firewall-cmd --reload
```

---

## systemd and logs

`systemctl` essentials:

```bash
systemctl list-unit-files
systemctl -t service -a

systemctl enable --now <service>
systemctl restart <service>
systemctl status <service>

# Where a unit file lives
systemctl show -p FragmentPath <service>
```

Journal usage:

```bash
journalctl --state=failed
journalctl -xe
journalctl -u <service>
journalctl -S today -f -u <service>

journalctl --disk-usage
journalctl --rotate
journalctl --vacuum-time=2days
```

Boot into a different target (rescue / multi-user):

See [Boot into a specific target](../Instruction%20Sets/systemd_boot_to_target_instructions.md).

Unmask a masked service:

```bash
sudo systemctl unmask <service>
sudo systemctl enable --now <service>
```

If enabling fails due to a stale unit file, reload systemd:

```bash
sudo systemctl daemon-reload
```

---

## Terminal productivity

History:

```bash
history
cat ~/.bash_history

# Write history to a file
history -w history.txt

# Strip the leading numbers
history | cut -c 8-
fc -l -n 1 | sed 's/^\s*//'
```

Terminal shortcuts (readline):

- `Ctrl+k`: delete to end of line
- `Ctrl+u`: delete to start of line
- `Ctrl+r`: reverse search
- `Ctrl+a`: start of line
- `Ctrl+l`: clear screen

Disk usage:

```bash
df -h
du -h --max-depth 1

# Largest files under a directory
find /path/to/directory -type f -exec du -h {} + | sort -rh | head -n 10
```

Create large files:

```bash
dd if=/dev/zero of=bigfile.img bs=1M count=1024
fallocate -l 1G bigfile.img
```

`tee` patterns:

```bash
ls | tee files.txt
ls | tee -a files.txt
echo "127.0.0.1 localhost" | sudo tee -a /etc/hosts
```

Clear caches (system-wide page cache):

```bash
sudo sync
sudo sysctl vm.drop_caches=3
```

---

## Shell scripting essentials

Redirects and suppression:

```bash
command 2>&1          # combine stdout + stderr
command 2>/dev/null   # suppress stderr
command &>/dev/null   # suppress all output
```

Useful shell special variables:

- `$0` script name
- `$#` number of args
- `$@` all args (preserves separation when quoted)
- `$?` last exit code
- `$!` PID of last background job
- `$$` PID of current shell

Example (`$@`):

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "You passed $# arguments: $*"
for arg in "$@"; do
  echo "Processing argument: $arg"
done
```

`nohup` (detach from your shell):

```bash
nohup my_long_running_command > /dev/null 2>&1 &
echo $!  # PID
```

Some common shell test flags:

```bash
if [ -f "file.txt" ]; then
  echo "Regular file exists"
fi

if [ -n "${SOME_VAR:-}" ]; then
  echo "Var is not empty"
fi
```

Passwordless sudo setup (step-by-step):

- [Passwordless sudo](../Instruction%20Sets/passwordless_sudo_instructions.md)

Aliases:

```bash
echo "alias st='systemctl start'" >> ~/.bashrc
source ~/.bashrc
alias
```

Show all env vars:

```bash
printenv
env
```

---

## Editors

Vim:

```vim
:set nu
:set nu!

" Save using root privileges
:w !sudo tee %

" Run a shell command
:!command
```

Change the default editor (Debian/Ubuntu):

```bash
update-alternatives --config editor
update-alternatives --set editor /usr/bin/vim.basic
```
