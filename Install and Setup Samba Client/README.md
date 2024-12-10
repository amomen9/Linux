# Install and setup Samba client on Linux (Ubuntu)


### 1. Install required packages

```shell
sudo apt-get update
sudo apt install -y samba-common samba-common-bin samba-client cifs-utils
```

### 2. Create mount point directory

```shell
sudo mkdir /backup
sudo chown -R postgres:postgres /backup
```

### 3. Mount (temporary mount) the remote share

Mount (temporary mount) the remote share on the created local mount point. You will be prompted to enter the password for the Windows user account afterwards.

```shell
# to unmount previously mounted:
# sudo umount /mnt/windows_share
# If you encounter an error stating that the device is busy, you can try using the lsof command to find out which process is using the mount point
# lsof /mnt/windows_share

# to unmount previously mounted:
# sudo umount /backup
# If you encounter an error stating that the device is busy, you can try using the lsof command to find out which process is using the mount point
# lsof /backup

# sudo mount -t cifs -o username=username,password=P@$$vvorcl,uid=116,gid=122,_netdev //WINDOWS_IP/SHARE_NAME /mnt/windows_share
mount -t cifs -o username=RedgateMon@mofid.dc,password=P@$$vvorcl,uid=116,gid=122,_netdev //172.23.97.4/PostgreSQL /backup

```


### 4. Make the mount persistent


```shell
sudo vi /etc/fstab
```

Add the following line at the end of the file:

```shell
//WINDOWS_IP/SHARE_NAME /mnt/windows_share cifs username=username,password=your_password,uid=116,gid=122,_netdev 0 0
//172.23.97.4/PostgreSQL /backup cifs username=RedgateMon@mofid.dc,password=P@$$vvorcl,uid=116,gid=122,_netdev 0 0
```

### 5. Test the configuration

```shell
sudo mount -a

ls -lha --color=auto /backup
```
