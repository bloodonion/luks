DISKS="/dev/sdb /dev/sdc /dev/sdd /dev/sde"   # the drives you picked
LEVEL=10                                      # 1, 6 or 10
TANG1=http://10.0.0.5:7500; THP1=<thumbprint> # on each tang server: tang-show-keys 7500
TANG2=http://10.0.0.6:7500; THP2=<thumbprint>
OPT_SIZE=2T  

#before touching anything. Every drive should show no partitions, no FSTYPE and no wipefs output:
lsblk -o NAME,SIZE,TYPE,FSTYPE,PTTYPE,MOUNTPOINT $DISKS
for d in $DISKS; do echo "== $d"; wipefs --no-act $d; done
cat /proc/mdstat  


#Create md0, and make it come back as md0 after a reboot
mdadm --create /dev/md0 --level=$LEVEL --raid-devices=$(echo $DISKS | wc -w) \
      --metadata=1.2 --bitmap=internal $DISKS
mdadm --detail --brief /dev/md0 >> /etc/mdadm.conf
dracut -f --regenerate-all
cat /proc/mdstat                              # the initial sync runs in the background; you can carry on

#Encrypt md0. The key file becomes keyslot 0, your disaster-recovery passphrase. luksFormat asks you to type YES.
tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64 > /root/md0.key; chmod 400 /root/md0.key
cryptsetup luksFormat --type luks2 --label md0 --key-file /root/md0.key /dev/md0
cryptsetup luksUUID /dev/md0

#Bind to both Tang servers. Either one can unlock it. Clevis adds keyslot 1.
clevis luks bind -d /dev/md0 -k /root/md0.key sss \
  "{\"t\":1,\"pins\":{\"tang\":[{\"url\":\"$TANG1\",\"thp\":\"$THP1\"},{\"url\":\"$TANG2\",\"thp\":\"$THP2\"}]}}"
clevis luks list -d /dev/md0

# prove Tang can unlock it (use the slot number shown by the list command)
clevis luks pass -d /dev/md0 -s 1 | cryptsetup open --test-passphrase --key-file=- /dev/md0 && echo "tang unlock OK"
cryptsetup open --test-passphrase --key-file /root/md0.key /dev/md0 && echo "DR key OK"
cryptsetup luksHeaderBackup /dev/md0 --header-backup-file /root/md0.luksheader

#Unlock it now
clevis luks unlock -d /dev/md0 -n md0_crypt
ls -l /dev/mapper/md0_crypt


#LVM: two volumes
pvcreate /dev/mapper/md0_crypt
vgcreate datavg /dev/mapper/md0_crypt
lvcreate -n opt -L $OPT_SIZE datavg
lvcreate -n containers -l 90%FREE datavg      # leaves ~10% spare for growing or snapshots later
lvs datavg
mkfs.xfs -L opt /dev/datavg/opt
mkfs.xfs -L containers /dev/datavg/containers

# Copy over anything already in /opt or /var/lib/containers. Skip this on a fresh server where both are empty.
systemctl stop podman.socket podman.service 2>/dev/null; podman stop -a 2>/dev/null
mkdir -p /mnt/new_opt /mnt/new_cont
mount /dev/datavg/opt /mnt/new_opt; mount /dev/datavg/containers /mnt/new_cont
rsync -aAXH --numeric-ids /opt/ /mnt/new_opt/
rsync -aAXH --numeric-ids /var/lib/containers/ /mnt/new_cont/
umount /mnt/new_opt /mnt/new_cont

#Make it unlock and mount at every boot
echo "md0_crypt UUID=$(cryptsetup luksUUID /dev/md0) none luks,_netdev,nofail" >> /etc/crypttab
cat >> /etc/fstab <<'EOF'
/dev/datavg/opt         /opt                 xfs  defaults,_netdev,nofail  0 0
/dev/datavg/containers  /var/lib/containers  xfs  defaults,_netdev,nofail  0 0
EOF
systemctl enable clevis-luks-askpass.path remote-cryptsetup.target
systemctl daemon-reload
mount /opt; mount /var/lib/containers
restorecon -Rv /opt /var/lib/containers       # SELinux labels on the new filesystems
df -h /opt /var/lib/containers

#Don’t let Podman start before its storage is mounted. If the volume isn’t unlocked yet, containers would otherwise start against the empty folder on the root disk.
mkdir -p /etc/systemd/system/podman.service.d
printf '[Unit]\nRequiresMountsFor=/var/lib/containers\n' > /etc/systemd/system/podman.service.d/storage.conf
systemctl daemon-reload

#Get the backup files off the server. From your controller: 
scp root@store01:/root/md0.key root@store01:/root/md0.luksheader luks-keys/store01/

#Then on the server:
shred -u /root/md0.key    # the server keeps no key; it unlocks through Tang only

#Reboot test
reboot
# after it's back:
cat /proc/mdstat; lsblk /dev/md0; findmnt /opt; findmnt /var/lib/contain

#Unlocking by hand with the backup key if Tang is down:
cryptsetup open --key-file md0.key /dev/md0 md0_crypt
vgchange -ay datavg
mount -a

#To start over during testing (this destroys everything on md0):
umount /opt /var/lib/containers
vgchange -an datavg
cryptsetup close md0_crypt
mdadm --stop /dev/md0
mdadm --zero-superblock $DISKS
wipefs -a $DISKS

#Then remove the md0 lines from /etc/mdadm.conf, /etc/crypttab and /etc/fstab, and run dracut -f --regenerate-all.
