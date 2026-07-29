# Automatic Linux Update (Applications, Modules, and Kernel)

This is the RHEL / Fedora family (RHEL, CentOS Stream, Rocky, AlmaLinux, Fedora)
 counterpart of the [Debian](../Debian/README.md) setup. It uses `dnf` instead of `apt`.

> **Tip:** To install these units automatically on either Debian- or RHEL-family
> systems, use the cross-platform [`install_system_maintenance.sh`](../install_system_maintenance.sh)
> script (see the [top-level README](../README.md)). The rest of this document
> describes the units and their manual installation.

Install service files contained within the `service files` directory. Use `Systemd Service and Timer` instructions for help if needed.
 You can find it on the following link:

[Systemd Service and Timer](../../Systemd%20Service%20and%20Timer%20DOC/README.md)

> **Prerequisite:** The `needs-restarting` and `yum-complete-transaction` helpers used below ship in the
> `dnf-utils` package (called `yum-utils` on some releases). Install it once with:
>
> ```shell
> dnf install -y dnf-utils
> ```

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
ExecStart=/bin/sh -c '/usr/bin/yum-complete-transaction --cleanup-only; /usr/bin/dnf -y upgrade --refresh'

[Install]
WantedBy=multi-user.target

```

The command `/bin/sh -c '/usr/bin/yum-complete-transaction --cleanup-only; /usr/bin/dnf -y upgrade --refresh'` first
 finishes/cleans up any interrupted `dnf`/`rpm` transaction (the RHEL analogue of `dpkg --configure -a`), then refreshes the
 repository metadata (`--refresh`, equivalent to `apt update`) and upgrades every installed package non-interactively (`-y`,
 equivalent to `apt upgrade -y`). Unlike `apt`, `dnf` does not raise a service-restart prompt, so no extra suppression flag is
 required for the update to run passively.

### system_update.timer

Here is the timer file that triggers updates:

```shell
# Timer for the service

[Unit]
Description=Triggers system and applications update
Requires=system_update.service

[Timer]
Unit=system_update.service
OnCalendar=*-*-* 01:00:00
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target

```

The directive `OnCalendar=*-*-* 01:00:00` triggers the service every day at 01:00:00 A.M.


<br/>

---

<br/>

# Automatic restart on schedule (if feasible)

It might suit your strategies for a server to be restarted on schedule if a restart is pending for the update
 process to complete. The following plan restarts the server on schedule should a restart be required.

## Required unit files to install:

### system_restart.service

Here is the service file that restarts the server:

```shell
[Unit]
Description=Reboot Linux Service
After=network.target
After=multi-user.target
Wants=system_restart.timer

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

# reboot if required
ExecStart=/usr/bin/bash -c 'if /usr/bin/needs-restarting -r; then echo "No reboot required."; else echo "rebooting..."; /usr/sbin/reboot; fi'

[Install]
WantedBy=multi-user.target

```

The command `/usr/bin/bash -c 'if /usr/bin/needs-restarting -r; then echo "No reboot required."; else echo "rebooting..."; /usr/sbin/reboot; fi'`
 first checks whether a reboot is required. `needs-restarting -r` (from `dnf-utils`) is the RHEL analogue of Debian's
 `/var/run/reboot-required` file: it exits `0` when no reboot is needed and `1` when the running kernel or core libraries have
 been updated and a reboot is pending. When a reboot is pending, the server is rebooted. Additional conditions or actions for
 reboot can be applied arbitrarily.


### system_restart.timer

Here is the timer file that triggers the reboot:

```shell
# Timer for the service

[Unit]
Description=Triggers system reboot when an update requires it
Requires=system_restart.service

[Timer]
Unit=system_restart.service
OnCalendar=Fri *-*-* 04:00:00
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target

```

The directive `OnCalendar=Fri *-*-* 04:00:00` triggers the service every Friday at 04:00:00 A.M.
