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

### 3. How to mount the remote share


#### Temporarily

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
mount -t cifs -o username=RedgateMon@mofid.dc,password=P@$$vvorcl,uid=116,gid=122,file_mode=0660,dir_mode=0660,_netdev //172.23.97.4/PostgreSQL /backup

```


#### Persistently


```shell
sudo vi /etc/fstab
```

Add the following line at the end of the file:

```shell
//WINDOWS_IP/SHARE_NAME /mnt/windows_share cifs username=username,password=your_password,uid=116,gid=122,file_mode=0660,dir_mode=0660,_netdev 0 0
//172.23.97.4/PostgreSQL /backup cifs username=RedgateMon@mofid.dc,password=P@$$vvorcl,uid=116,gid=122,file_mode=0660,dir_mode=0660,_netdev 0 0
```

Test the `fstat` file modifications and also if correct, make them effective without a restart
```shell
sudo mount -a
```

### 4. Test the mounted share

Query the mounted directory contents. If the result is empty and the remote share is non-empty, your samba client share setup is not functional.
 If the remote is empty, try to create some files/directories there to ascertain that the file operations are visible on the client. 

```shell
ls -lha --color=auto /backup
```
