# Create a new partition, format it, and mount it (fdisk workflow)

This guide follows the classic `fdisk` → `mkfs` → `/etc/fstab` flow.

## Before you start

- Identify the target disk **carefully** (`/dev/sdb`, `/dev/nvme0n1`, …).
- Back up data. Partitioning can destroy data.

## Steps

1. List disks.

   ```bash
   lsblk -f
   sudo fdisk -l
   ```

2. Create a new partition.

   ```bash
   sudo fdisk /dev/sdb
   ```

   In `fdisk`:

   1. `p` (print)
   2. `n` (new)
   3. `p` (primary)
   4. accept defaults (start/end) unless you need specific sizing
   5. `w` (write)

3. Re-read partition table (or reboot).

   ```bash
   sudo partprobe /dev/sdb || true
   ```

4. Format the new partition.

   Replace `<partition>` with the new partition name (example: `/dev/sdb1`).

   ```bash
   sudo mkfs.ext4 /dev/sdb1
   ```

5. Create a mount point.

   ```bash
   sudo mkdir -p /newpartition
   ```

6. Mount it.

   ```bash
   sudo mount /dev/sdb1 /newpartition
   df -h | grep newpartition || true
   ```

7. Make the mount persistent.

   Prefer `UUID=` to avoid device renaming issues.

   ```bash
   sudo blkid /dev/sdb1
   sudo nano /etc/fstab
   ```

   Example entry:

   ```fstab
   UUID=<uuid-from-blkid>  /newpartition  ext4  defaults  0  2
   ```

8. Test and reboot.

   ```bash
   sudo mount -a
   sudo reboot
   ```
