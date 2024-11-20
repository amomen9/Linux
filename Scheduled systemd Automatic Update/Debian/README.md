# Automatic Linux Update (Applications, Modules, and Kernel)

Install service files contained within the `service files` directory. Use `Systemd Service and Timer` instructions for help if needed.
 You can find it on the following link:
 
[Systemd Service and Timer](../../Systemd%20Service%20and%20Timer/README.md)

## Required unit files to install:

### system_update.service

Here is the service file that installs updates:

```shell
[Unit]
Description=Update Linux Service
After=network.target
After=multi-user.target
Wants=system_update.timer

[Service]
#Type=oneshot

User=root
Group=root


# Where to send early-startup messages from the server
# This is normally controlled by the global default set by systemd
StandardOutput=syslog

# Disable OOM kill on the scripts
OOMScoreAdjust=-1000
Environment=PGB_OOM_ADJUST_FILE=/proc/self/oom_score_adj
Environment=PGB_OOM_ADJUST_VALUE=0

# update & upgrade
ExecStart=/bin/sh -c 'dpkg --configure -a; DEBIAN_FRONTEND=noninteractive apt update && apt upgrade -y'

[Install]
WantedBy=multi-user.target

```

The command `/bin/sh -c 'sudo dpkg --configure -a; DEBIAN_FRONTEND=noninteractive apt update && apt upgrade -y'` first recovers
 any broken dpkg process, then updates the repository indexes first, then upgrades the packages, suppressing service(s) restart
 prompt. We evidently need to skip the service restart prompt because the update process needs to be carried out passively.


### system_update.timer

Here is the timer file that triggers updates:

```shell
# Timer for the service

[Unit]
Description=Triggers system and applications update
Requires=system_update.service

[Timer]
Unit=system_update.service
OnCalendar=*-*-* 02:30:00
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target

```

The directive `OnCalendar=*-*-* 02:30:00` triggers the service every day at 02:30:00 A.M.



<!--

## restart the system on schedule

### system_restart.service

-->

