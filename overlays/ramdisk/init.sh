#!/rescue/sh

PATH="/rescue"

if [ "`ps -o command 1 | tail -n 1 | ( read c o; echo ${o} )`" = "-s" ]; then
	echo "==> Running in single-user mode"
	SINGLE_USER="true"
	kenv boot_mute="NO"
fi

if [ "`ps -o command 1 | tail -n 1 | ( read c o; echo ${o} )`" = "-v" ]; then
	echo "==> Running in verbose mode"
	kenv boot_mute="NO"
fi

# Silence messages if boot_mute="YES" is set
if [ "$(kenv boot_mute)" = "YES" ] ; then
      exec 1>>/dev/null 2>&1
fi

set -x

echo "==> Ramdisk /init.sh running"

echo "==> Remount rootfs as read-write"
mount -u -w /

echo "==> Make mountpoints"
mkdir -p /cdrom /memdisk /sysroot

echo "Waiting for Live media to appear"
while : ; do
    [ -e "/dev/iso9660/LIVE" ] && echo "found /dev/iso9660/LIVE" && break
    sleep 1
done

echo "==> Mount cdrom"
mount_cd9660 -o ro /dev/iso9660/LIVE /cdrom
mdconfig -o readonly -f /cdrom/data/system.uzip -u 1
zpool import furybsd -o readonly=on # Without readonly=on zfs refuses to mount this with: "one or more devices is read only"
zpool list # furybsd
mount # /usr/local/furybsd/uzip

if [ "$SINGLE_USER" = "true" ]; then
        echo "Starting interactive shell in temporary rootfs ..."
        exit 0
fi

# Optionally use unionfs if requested. FIXME: This does not boot yet
if [ "$(kenv use_unionfs)" = "YES" ] ; then
  echo "==> Trying unionfs"
  
  # Could we snapshot /usr/local/furybsd/uzip here?
  # zfs snapshot furybsd@now
  # results in:
  # cannot create shapshots : pool is read-only
  
  # FIXME: The following does NOT seem to work
  mkdir /tmp
  mount -t tmpfs tmpfs /tmp
  mount -t unionfs /tmp /usr/local/furybsd/uzip # FIXME: mount_unionfs: /usr/local/furybsd/uzip: Operation not supported by device
  
  # TODO: https://github.com/lantw44/freebsd-gnome-livecd/blob/master/init.sh.in
  # shows how to make /cdrom available to the booted system
  
  mount -t devfs devfs /usr/local/furybsd/uzip/dev
  mount -t tmpfs tmpfs /usr/local/furybsd/uzip/tmp
  
  # chroot /usr/local/furybsd/uzip /usr/local/bin/furybsd-init-helper # Should we run it? Only makes sense if we can become r/w until here
  
  kenv init_chroot=/usr/local/furybsd/uzip # TODO: Can we possibly reroot instead of chroot?
  kenv init_shell="/rescue/sh"
  exit 0 # etc/rc in he ramdisk gets executed next
fi

# Ensure the system has more than enough memory for memdisk
 x=3163787264
 y=$(sysctl -n hw.physmem)
 echo "Required memory ${x} for memdisk"
 echo "Detected memory ${y} for memdisk"
 if [ $x -gt $y ] ; then 
  echo "Live system requires 4GB of memory for memdisk, and operation!"
  echo "Type exit, and press enter after entering the rescue shell to power off."
  exit 1
 fi

echo "==> Mount swap-based memdisk"
mdconfig -a -t swap -s 3g -u 2 >/dev/null 2>/dev/null
gpart create -s GPT md2 >/dev/null 2>/dev/null
gpart add -t freebsd-zfs md2 >/dev/null 2>/dev/null
zpool create livecd /dev/md2p1 >/dev/null 2>/dev/null

# From FreeBSD 13 on, zstd can be used with zfs in base
MAJOR=$(printf '%-.2s' $(sysctl -n kern.osrelease)) # First two characters of kern.osrelease
if [ $MAJOR -lt 13 ] ; then
  zfs set compression=gzip-6 livecd 
else
  zfs set compression=zstd-6 livecd 
fi

zfs set primarycache=none livecd

echo "==> Replicate system image to swap-based memdisk."
echo "    TODO: Remove the need for this."
echo "    Can we get unionfs or OpenZFS to make the r/o system image r/w instantly"
echo "    without the need for this time consuming operation? Please let us know."
echo "    https://github.com/helloSystem/ISO/issues/4"
zfs send -c -e furybsd | dd status=progress bs=1M | zfs recv -F livecd

mount -t devfs devfs /livecd/dev
chroot /livecd /usr/local/bin/furybsd-init-helper

kenv init_shell="/rescue/sh"
exit 0
