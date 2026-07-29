# Mount a CD-ROM / USB drive

## Steps

1. Create a mount point.

   ```bash
   sudo mkdir -p /media/iso
   ```

2. Identify the device.

   ```bash
   lsblk -f
   sudo blkid
   ```

3. Mount.

   ```bash
   sudo mount /dev/<device> /media/iso
   ```

   For an ISO/CD-ROM you may need:

   ```bash
   sudo mount -t iso9660 -o ro /dev/sr0 /media/iso
   ```

4. Unmount.

   ```bash
   sudo umount /media/iso
   ```
