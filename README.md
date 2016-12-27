# debian-jessie-zfs-root
Installs Debian GNU/Linux 8 Jessie to a native ZFS root filesystem using a [Debian Live CD](https://www.debian.org/CD/live/) and ZFS packages from [backports.org](https://backports.debian.org/).

## Usage

1. Boot [Jessie Live CD](https://www.debian.org/CD/live/) ('standard' edition)
1. Set `http_proxy` environment variable (if needed)
1. Run this script
1. User interface: Select disks and RAID level
1. Let the installer do the work
1. User interface: install grub to *all* relevant disks
1. User interface: enter root password and select timezone
1. Reboot

## Fixes included

* grub (v2.02, included in Debian 8), especially grub-probe, does not support all ZFS features and subsequently refuses to install. This script disables `feature@hole_birth` and `feature@embedded_data` (and you should _not_ enable those features after installation).
* The ZFS SPL uses the system `hostid`, [which isn't initialized correctly on Debian systems](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=595790).
* Woraround for grub (v2.02) mysteriously _not_ searching devices in `/dev/disk/by-id` but in `/dev`.
* Some mountpoints, notably `/var`, need to be mounted via fstab as the ZFS mount script runs too late during boot.
* The EFI System Partition (ESP) is a single point of failure on one disk, [this is arguably a mis-design in the UEFI specification](https://wiki.debian.org/UEFI#RAID_for_the_EFI_System_Partition).

## Bugs

* Booting via EFI has not been tested at all.
* RAID10 Mirror with >= 6 disks fails to boot with grub, probably a grub bug -- need to investigate further.

## Credits

* https://github.com/zfsonlinux/zfs/wiki/Ubuntu-16.04-Root-on-ZFS
* https://janvrany.github.io/2016/10/fun-with-zfs-part-1-installing-debian-jessie-on-zfs-root.html

