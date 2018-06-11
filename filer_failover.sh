#!/bin/sh

log_name="filer"
log_prio="user.notice"

flog () {
  logger -p "$log_prio" -t "$log_name" "$1"
}

boottime=$(sysctl -n kern.boottime | awk '{print $4}' | tr -dc 0-9)
now=$(date +%s)
delta=$(($now-$boottime))

# This is to prevent the script to be executed at boot. If the two
# machines are powered on at the same time there is a risk that the
# CARP status switches rapidly in a few seconds, for example:
# bge0: link state changed to DOWN
# bge0: promiscuous mode enabled
# carp: demoted by 240 to 240 (interface down)
# carp: VHID 54@bge0: INIT -> BACKUP
# carp: demoted by -240 to 0 (interface up)
# bge0: link state changed to UP
# carp: VHID 54@bge0: BACKUP -> MASTER (master down)
# carp: VHID 54@bge0: MASTER -> BACKUP (more frequent advertisement received)
# Also, don't do failover if there is a /root/scripts/NO_FAILOVER file,
# in case we have to reboot the MASTER for some maintenance
# (freebsd-update, updates, etc) or ...
if [ $delta -lt 180 -o -f /root/scripts/NO_FAILOVER ] ; then
  flog "Failover script skipped (delta: $delta)"
  exit
else
  flog "Running failover script (delta: $delta)"
fi

case "$1" in
  MASTER)
    if [ -f /root/scripts/NO_FAILOVER_MASTER ] ; then
      flog "No failover: /root/scripts/NO_FAILOVER_MASTER exists"
      exit
    fi
    # This is run when the machine WAS a SLAVE and becomes the new
    # MASTER. Basically we do the following:
    # 1) Shutdown the replication interface so that we are sure that
    # no data is written on the iSCSI disks
    # 2) Change the advskew of the CARP interface, so that the OLD
    # MASTER never returns (and adapt rc.conf)
    # 3) Shutdown the CAM Target Layer / iSCSI target daemon. At this
    # stage the disks are *unlocked*
    # 4) Import the shared pool (data). As we turned off the
    # replication interface an import -f should be safe (and needed
    # as the old MASTER may have been restarted roughly: powerloss,
    # etc)
    # 5) Start the NFS services (and adapt rc.conf)
    flog "Shutting down the replication interface"
    ifconfig bge1 down
    sysrc ifconfig_bge1="down"

    # Backup is the new master
    flog "Adapting advskew on the main interface"
    sysrc ifconfig_bge0_alias0="inet vhid 54 advskew 10 pass 249bcd2afe7d951d9bbede600rdd4804 alias 192.168.10.15/32" 
    ifconfig bge0 vhid 54 advskew 10

    flog "Shutting down the CTLD daemon"
    sysrc ctld_enable="NO"
    service ctld stop
    while pgrep -u root ctld > /dev/null ; do
      sleep 0.01
    done

    flog "Import data zpool"
    zpool import -f -o cachefile=none data 2> /dev/null

    flog "Enable NFS services in rc.conf"

    if [ ! -f /etc/exports ] ; then
      echo "V4: /data -sec=sys" > /etc/exports
    fi

    sysrc mountd_enable="YES"
    sysrc mountd_flags="-r -S -h 192.168.10.15"
    sysrc nfs_server_enable="YES"
    sysrc nfs_server_flags="-t -h 192.168.10.15"
    sysrc nfsuserd_enable="YES"
    sysrc nfsuserd_flags="-domain prod.lan"
    sysrc nfsv4_server_enable="YES"

    flog "Start NFS services (nfsuserd, nfsd)"
    service nfsuserd start
    service nfsd start
  ;;

  BACKUP)
    if [ -f /root/scripts/NO_FAILOVER_SLAVE ] ; then
      flog "No failover: /root/scripts/NO_FAILOVER_SLAVE exists"
      exit
    fi
    # This is run when the machine WAS a MASTER and becomes a SLAVE.
    # It's too risky to be done automatically as we risk to corrupt the
    # zpool, it's the task of the sysadmin to do that manually.
    flog "Stop NFS services (nfsuserd, nfsd)"
    service nfsuserd stop
    service nfsd stop
    service mountd stop

    flog "Disable NFS services in rc.conf"
    sysrc mountd_enable="NO"
    sysrc nfs_server_enable="NO"
    sysrc nfsuserd_enable="NO"
    sysrc nfsv4_server_enable="NO"
  ;;
esac
