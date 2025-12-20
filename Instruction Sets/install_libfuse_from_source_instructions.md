# Install `libfuse` from source (Ubuntu example)

Use this when distro packages are too old or you need a specific `libfuse` release.

## Steps

1. Install build tools.

   ```bash
   sudo apt update
   sudo apt install -y build-essential ninja-build pkg-config python3-pip
   ```

2. Install Python build helpers used by the upstream build.

   ```bash
   python3 -m pip install --user pytest looseversion meson
   ```

   If you need a specific `meson` version:

   ```bash
   python3 -m pip install --user 'meson==0.51'
   ```

3. Download and verify (optional) the release.

   ```bash
   mkdir -p ~/src/libfuse && cd ~/src/libfuse

   wget https://github.com/libfuse/libfuse/releases/download/fuse-3.16.2/fuse-3.16.2.tar.gz
   wget https://github.com/libfuse/libfuse/releases/download/fuse-3.16.2/fuse-3.16.2.tar.gz.sig || true
   ```

4. Build.

   ```bash
   tar xzf fuse-3.16.2.tar.gz
   cd fuse-3.16.2
   mkdir -p build && cd build
   meson setup ..
   ninja
   ```

5. Test (optional).

   ```bash
   sudo python3 -m pytest test/
   ```

6. Install.

   ```bash
   sudo ninja install
   ```

7. Ensure `fusermount3` permissions (some setups require setuid root).

   ```bash
   sudo chown root:root /usr/local/bin/fusermount3 2>/dev/null || true
   sudo chmod 4755 /usr/local/bin/fusermount3 2>/dev/null || true
   ```

---
