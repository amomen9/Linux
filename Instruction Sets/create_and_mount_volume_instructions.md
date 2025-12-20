# Create a filesystem and mount it permanently (parted + mkfs)

This guide is handy for new disks or new partitions.

## Steps

1. Identify the disk/partition.

   ```bash
   lsblk -f
   ```

2. Partition the disk using `parted` (interactive).

   ```bash
   sudo parted /dev/sdX
   ```

3. Format the partition.

   ```bash
   sudo mkfs.ext4 /dev/sdX1        # ext4
   sudo mkfs.ntfs /dev/sdX1        # NTFS
   sudo mkfs.vfat -F32 /dev/sdX1   # FAT32
   ```

4. Mount and persist.

   ```bash
   sudo mkdir -p /mnt/mydrive
   sudo mount /dev/sdX1 /mnt/mydrive
   sudo blkid /dev/sdX1
   ```

   Add to `/etc/fstab` (UUID recommended):

   ```bash
   echo "UUID=<uuid> /mnt/mydrive ext4 defaults 0 2" | sudo tee -a /etc/fstab
   sudo mount -a
   ```
