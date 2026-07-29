# Install Google Chrome (Debian/Ubuntu and RHEL/Rocky)

This installs **Google Chrome Stable** from Google's official download.

## Debian/Ubuntu

1. Confirm architecture.

   ```bash
   echo "You are using $(getconf LONG_BIT) bit Linux distro."
   ```

2. Download and install.

   ```bash
   sudo apt update
   sudo apt install -y wget

   wget -O google-chrome-stable_current_amd64.deb \
     https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb

   # Install local .deb and fix dependencies if required
   sudo apt install -y ./google-chrome-stable_current_amd64.deb
   sudo apt-get -f install -y

   rm -f google-chrome-stable_current_amd64.deb
   ```

3. Run.

   ```bash
   google-chrome 2>/dev/null &
   ```

## RHEL/Rocky/Alma

1. Confirm architecture.

   ```bash
   echo "You are using $(getconf LONG_BIT) bit Linux distro."
   ```

2. Download and install.

   ```bash
   sudo dnf install -y wget || sudo yum install -y wget

   wget -O google-chrome-stable_current_x86_64.rpm \
     https://dl.google.com/linux/direct/google-chrome-stable_current_x86_64.rpm

   # Install local RPM and resolve dependencies
   sudo dnf install -y ./google-chrome-stable_current_x86_64.rpm || sudo yum localinstall -y ./google-chrome-stable_current_x86_64.rpm

   rm -f google-chrome-stable_current_x86_64.rpm
   ```

3. Run.

   ```bash
   google-chrome 2>/dev/null &
   ```
