#!/bin/bash
#
# debian-stretch-zfs-root.sh V1.00
#
# Install Debian GNU/Linux 9 Stretch to a native ZFS root filesystem
#
# (C) 2017 Hajo Noerenberg
#
#
# http://www.noerenberg.de/
# https://github.com/hn/debian-stretch-zfs-root
#
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3.0 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.txt>.
#

set -e

### Static settings, overridable by environment variables

ZPOOL=${ZPOOL:-tank}
TARGETDIST=${TARGETDIST:-stretch}

SIZESWAP=${SIZESWAP:-2G}
SIZETMP=${SIZETMP:-3G}
SIZEVARTMP=${SIZEVARTMP:-3G}

GRUBPKG=${GRUBPKG:-grub-pc}
#GRUBPKG=grub-efi-amd64 # INCOMPLETE NOT TESTED

test -n "$ETHDEV" || ETHDEV=$(ip -o link show|grep -v ' lo:'|head -n 1|cut -d: -f2|sed -e 's/ //g')

PARTBIOS=${PARTBIOS:-1}
PARTEFI=${PARTEFI:-2}
PARTZFS=${PARTZFS:-3}

ENABLE_POSIXACL=${ENABLE_POSIXACL:-no}

# NEWHOST is also used for hostname of the new system, if set (if unset, is
# taken from freshly generated hostid)

### User settings

declare -A BYID
for IDLINK in $(find /dev/disk/by-id/ -type l); do
	BYID["$(basename $(readlink $IDLINK))"]="$IDLINK"
done

for DISK in $(lsblk -I8 -dn -o name); do
	if [ -z "${BYID[$DISK]}" ]; then
		SELECT+=("$DISK" "(no /dev/disk/by-id persistent device name available)" off)
	else
		SELECT+=("$DISK" "${BYID[$DISK]}" off)
	fi
done

TMPFILE=$(mktemp)
whiptail --backtitle $0 --title "Drive selection" --separate-output \
	--checklist "\nPlease select ZFS RAID drives\n" 20 74 8 "${SELECT[@]}" 2>$TMPFILE

if [ $? -ne 0 ]	; then
	exit 1
fi

while read -r DISK; do
	if [ -z "${BYID[$DISK]}" ]; then
		DISKS+=("/dev/$DISK")
		ZFSPARTITIONS+=("/dev/$DISK$PARTZFS")
		EFIPARTITIONS+=("/dev/$DISK$PARTEFI")
	else
		DISKS+=("${BYID[$DISK]}")
		ZFSPARTITIONS+=("${BYID[$DISK]}-part$PARTZFS")
		EFIPARTITIONS+=("${BYID[$DISK]}-part$PARTEFI")
	fi
done < $TMPFILE

whiptail --backtitle $0 --title "RAID level selection" --separate-output \
	--radiolist "\nPlease select ZFS RAID level\n" 20 74 8 \
	"RAID0" "Striped disks" off \
	"RAID1" "Mirrored disks (RAID10 for n>=4)" on \
	"RAIDZ" "Distributed parity, one parity block" off \
	"RAIDZ2" "Distributed parity, two parity blocks" off \
	"RAIDZ3" "Distributed parity, three parity blocks" off 2>$TMPFILE

if [ $? -ne 0 ]	; then
	exit 1
fi

RAIDLEVEL=$(head -n1 $TMPFILE | tr [:upper:] [:lower:])

case "$RAIDLEVEL" in
  raid0)
	RAIDDEF="${ZFSPARTITIONS[*]}"
  	;;
  raid1)
	if [ $((${#ZFSPARTITIONS[@]} % 2)) -ne 0 ]; then
		echo "Need an even number of disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
		exit 1
	fi
	I=0
	for ZFSPARTITION in "${ZFSPARTITIONS[@]}"; do
		if [ $(($I % 2)) -eq 0 ]; then
			RAIDDEF+=" mirror"
		fi
		RAIDDEF+=" $ZFSPARTITION"
		((I++)) || true
	done
  	;;
  *)
	if [ ${#ZFSPARTITIONS[@]} -lt 3 ]; then
		echo "Need at least 3 disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
		exit 1
	fi
	RAIDDEF="$RAIDLEVEL ${ZFSPARTITIONS[*]}"
  	;;
esac

whiptail --backtitle $0 --title "Confirmation" \
	--yesno "\nAre you sure to destroy ZFS pool '$ZPOOL' (if existing), wipe all data of disks '${DISKS[*]}' and create a RAID '$RAIDLEVEL'?\n" 20 74

if [ $? -ne 0 ]	; then
	exit 1
fi

### Start the real work

# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=595790
if [ $(hostid | cut -b-6) == "007f01" ]; then
	dd if=/dev/urandom of=/etc/hostid bs=1 count=4
fi

DEBRELEASE=$(head -n1 /etc/debian_version)
case $DEBRELEASE in
	8*)
		echo "deb http://http.debian.net/debian/ jessie-backports main contrib non-free" >/etc/apt/sources.list.d/jessie-backports.list
		test -f /var/lib/apt/lists/http.debian.net_debian_dists_jessie-backports_InRelease || apt-get update
		test -d /usr/share/doc/zfs-dkms || DEBIAN_FRONTEND=noninteractive apt-get install --yes gdisk debootstrap dosfstools zfs-dkms/jessie-backports
		;;

	9*)
		echo "deb http://deb.debian.org/debian/ stretch contrib non-free" >/etc/apt/sources.list.d/contrib-non-free.list
		test -f /var/lib/apt/lists/deb.debian.org_debian_dists_stretch_non-free_binary-amd64_Packages || apt-get update
		test -d /usr/share/doc/zfs-dkms || DEBIAN_FRONTEND=noninteractive apt-get install --yes gdisk debootstrap dosfstools zfs-dkms
		;;
	*)
		echo "Unsupported Debian Live CD release" >&2
		exit 1
		;;
esac

modprobe zfs
if [ $? -ne 0 ] ; then
	echo "Unable to load ZFS kernel module" >&2
	exit 1
fi
test -d /proc/spl/kstat/zfs/$ZPOOL && zpool destroy $ZPOOL

for DISK in "${DISKS[@]}"; do
	echo -e "\nPartitioning disk $DISK"

	sgdisk --zap-all $DISK

	sgdisk -a1 -n$PARTBIOS:34:2047   -t$PARTBIOS:EF02 \
	           -n$PARTEFI:2048:+512M -t$PARTEFI:EF00 \
                   -n$PARTZFS:0:0        -t$PARTZFS:BF01 $DISK
done

sleep 2

# Workaround for Debian's grub, especially grub-probe, not supporting all ZFS features
# Using "-d" to disable all features, and selectivly enable features later (but NOT 'hole_birth' and 'embedded_data')
# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=776676
zpool create -f -o ashift=12 -d -o altroot=/target -o autoexpand=on -O atime=off -O mountpoint=none $ZPOOL $RAIDDEF
if [ $? -ne 0 ] ; then
	echo "Unable to create zpool '$ZPOOL'" >&2
	exit 1
fi
for ZFSFEATURE in async_destroy empty_bpobj lz4_compress spacemap_histogram enabled_txg extensible_dataset bookmarks filesystem_limits large_blocks; do
	zpool set feature@$ZFSFEATURE=enabled $ZPOOL
done
zfs set compression=lz4 $ZPOOL
# The two properties below improve performance but reduce compatibility with non-Linux ZFS implementations
case "$ENABLE_POSIXACL" in
	y*)
		zfs set xattr=sa $ZPOOL
		zfs set acltype=posixacl $ZPOOL
		;;
esac

zfs create $ZPOOL/ROOT
zfs create -o mountpoint=/ $ZPOOL/ROOT/debian-$TARGETDIST
zpool set bootfs=$ZPOOL/ROOT/debian-$TARGETDIST $ZPOOL

zfs create -o mountpoint=/tmp -o setuid=off -o exec=off -o devices=off -o com.sun:auto-snapshot=false -o quota=$SIZETMP $ZPOOL/tmp
chmod 1777 /target/tmp

# /var needs to be mounted via fstab, the ZFS mount script runs too late during boot
zfs create -o mountpoint=legacy $ZPOOL/var
mkdir -v /target/var
mount -t zfs $ZPOOL/var /target/var

# /var/tmp needs to be mounted via fstab, the ZFS mount script runs too late during boot
zfs create -o mountpoint=legacy -o com.sun:auto-snapshot=false -o quota=$SIZEVARTMP $ZPOOL/var/tmp
mkdir -v -m 1777 /target/var/tmp
mount -t zfs $ZPOOL/var/tmp /target/var/tmp
chmod 1777 /target/var/tmp

zfs create -V $SIZESWAP -b $(getconf PAGESIZE) -o primarycache=metadata -o com.sun:auto-snapshot=false -o logbias=throughput -o sync=always $ZPOOL/swap
# sometimes needed to wait for /dev/zvol/$ZPOOL/swap to appear
sleep 2
mkswap -f /dev/zvol/$ZPOOL/swap

zpool status
zfs list

# "This is arguably a mis-design in the UEFI specification - the ESP is a single point of failure on one disk."
# https://wiki.debian.org/UEFI#RAID_for_the_EFI_System_Partition
I=0
for EFIPARTITION in "${EFIPARTITIONS[@]}"; do
	mkdosfs -F 32 -n EFI-$I $EFIPARTITION
	if [ $I -eq 0 ]; then
		mkdir -pv /target/boot/efi
		mount $EFIPARTITION /target/boot/efi
	else
		mkdir -pv /mnt/efi-$I
		mount $EFIPARTITION /mnt/efi-$I
	fi
	((I++)) || true
done

debootstrap --include=openssh-server,locales,joe,rsync,sharutils,psmisc,htop,patch,less $TARGETDIST /target http://http.debian.net/debian/

test -n NEWHOST || NEWHOST=debian-$(hostid)}
echo $NEWHOST >/target/etc/hostname
sed -i "1s/^/127.0.1.1\t$NEWHOST\n/" /target/etc/hosts

# Copy hostid as the target system will otherwise not be able to mount the misleadingly foreign file system
cp -va /etc/hostid /target/etc/

cat << EOF >/target/etc/fstab
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system>         <mount point>   <type>  <options>       <dump>  <pass>
/dev/zvol/$ZPOOL/swap     none            swap    defaults        0       0
$ZPOOL/var                /var            zfs     defaults        0       0
$ZPOOL/var/tmp            /var/tmp        zfs     defaults        0       0
EOF

mount --rbind /dev /target/dev
mount --rbind /proc /target/proc
mount --rbind /sys /target/sys
ln -s /proc/mounts /target/etc/mtab

perl -i -pe 's/# (en_US.UTF-8)/$1/' /target/etc/locale.gen
echo 'LANG="en_US.UTF-8"' > /target/etc/default/locale
chroot /target /usr/sbin/locale-gen

perl -i -pe 's/main$/main contrib non-free/' /target/etc/apt/sources.list
chroot /target /usr/bin/apt-get update

chroot /target /usr/bin/apt-get install --yes linux-image-amd64 grub2-common $GRUBPKG zfs-initramfs zfs-dkms
grep -q zfs /target/etc/default/grub || perl -i -pe 's/quiet/boot=zfs quiet/' /target/etc/default/grub 
chroot /target /usr/sbin/update-grub

if [ "${GRUBPKG:0:8}" == "grub-efi" ]; then
	chroot /target /usr/sbin/grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck --no-floppy
else
	EFIFSTAB="#"
fi

I=0
for EFIPARTITION in "${EFIPARTITIONS[@]}"; do
	if [ $I -gt 0 ]; then
		rsync -avx /target/boot/efi/ /mnt/efi-$I/
		umount /mnt/efi-$I
		EFIBAKPART="#"
	fi
	echo "${EFIFSTAB}${EFIBAKPART}PARTUUID=$(blkid -s PARTUUID -o value $EFIPARTITION) /boot/efi vfat defaults 0 1" >> /target/etc/fstab
	((I++))
done
umount /target/boot/efi

if [ -d /proc/acpi ]; then
	chroot /target /usr/bin/apt-get install --yes acpi acpid
	chroot /target service acpid stop
fi

if [ -n "$ETHDEV" ]; then
	echo -e "\nauto $ETHDEV\niface $ETHDEV inet dhcp\n" >>/target/etc/network/interfaces
	echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" >> /target/etc/resolv.conf
fi

chroot /target /usr/bin/passwd
chroot /target /usr/sbin/dpkg-reconfigure tzdata

sync

#zfs umount -a

## chroot /target /bin/bash --login
## zpool import -R /target tank

