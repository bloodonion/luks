# LUKS + Tang for Rocky Linux 10 (re-runnable, network unlock only)

- **tang_server**: Tang key server (port, SELinux, firewalld). Saves its thumbprint and keys to `luks-keys/tang/`.
- **luks_encrypt**: encrypts blank data volumes, binds OS and data volumes to Tang, and saves every passphrase and LUKS header backup to `luks-keys/<host>/`. **No keys are stored on the servers**; everything unlocks over the network.

## How a disk is judged

One read-only command builds the `luks_disks` fact for every whole disk **and** md array:

```bash
lsblk -J -d -b -o NAME,PATH,TYPE,SIZE,RM,FSTYPE,PTTYPE,LABEL,MOUNTPOINT
```

Combined with `ansible_facts.devices` (partitions and holders), each device gets one state:

| State | Meaning | Action |
|---|---|---|
| `encrypted` | FSTYPE is `crypto_LUKS` (open or closed) | skip |
| `in_use` | any filesystem, RAID member, LVM, partition table, partitions, holders, or mounted | skip |
| `blank` | none of the above | encrypt, if `luks_allow_format=true` |

Every run prints this as a table, so you can compare it with the same `lsblk` command run by hand on the server.

Right before `luksFormat`, `wipefs --no-act` reads the disk directly (not udev's cache). If it finds anything at all, the format is stopped.

## Software RAID

- `raid` mode targets the array (`/dev/md0`), never its member disks. `/dev/md/<name>` paths are resolved with `realpath`.
- Member disks show `FSTYPE=linux_raid_member` and have the array as a holder, so `dynamic` mode never picks them, even if they're in the size window. Arrays themselves are `TYPE=raid*`, so `dynamic` mode never picks those either.
- Before encrypting an array the role checks it's assembled and running (`/sys/block/mdX/md/array_state`), and warns if it's missing from `/etc/mdadm.conf`.
- Arrays are named by their md UUID (`data-md-<uuid>`), so keys still match if `md0` comes back as `md127`.
- The OS volume on RAID (e.g. `/dev/md1`) is found automatically by `luks_os_mode: auto`.

## Running it

```bash
ansible-galaxy collection install -r requirements.yml
cp inventory/group_vars/luks_servers/vault.yml.example inventory/group_vars/luks_servers/vault.yml
ansible-vault encrypt inventory/group_vars/luks_servers/vault.yml

ansible-playbook site.yml --limit tang_servers                                         # 1. Tang
ansible-playbook site.yml --limit luks_servers -e luks_preview_only=true --ask-vault-pass  # 2. see the plan
ansible-playbook site.yml --limit luks_servers -e luks_allow_format=true --ask-vault-pass  # 3. do it
```

The plan prints one line per device, e.g. `/dev/sdb: ENCRYPT`, `/dev/sdc: skip: already encrypted by this role`, `/dev/sdd: skip: in use (fstype=xfs, pttype=-)`.

## Data volume selection

| `luks_data_mode` | Targets |
|---|---|
| `raid` | `luks_data_raid_devices` (default `/dev/md0`) |
| `dynamic` | Disks between `luks_data_min_size_tb` and `luks_data_max_size_tb` (decimal TB) |
| `devices` | `luks_data_devices` |

`luks_data_expected_count` counts disks in the size window before skipping, so it still passes on re-runs.

## How unlock works

- **Root**: the initramfs brings up the network (`rd.neednet=1`), Clevis asks Tang, root unlocks. The role proves this works on each run with `clevis luks pass`.
- **Data**: crypttab entries use `none` with `_netdev,nofail`; `clevis-luks-askpass` unlocks them from Tang after the network is up.

If Tang is down, root waits at the console prompt (type the key from `luks-keys/<host>/os-*.key`), and data volumes stay locked but don't block boot. Run two Tang servers with `luks_tang_threshold: 1` to avoid this.

## If a run stops part way

Volumes formatted by this role carry the LUKS2 label `ansible-luks`. If a run failed after formatting (for example Tang was unreachable), re-run with `-e luks_resume_own_volumes=true`. That finishes only those volumes: Tang binding, header backup, crypttab, unlock, and mount if the filesystem already exists. It never formats or creates filesystems.

## OS install (kickstart)

The OS volume must be LUKS from install time:

```
part pv.01 --size=1 --grow --encrypted --luks-version=luks2 --passphrase=<temp>
# RAID: raid pv.01 --level=1 --device=md1 --encrypted --luks-version=luks2 --passphrase=<temp> raid.01 raid.02
```

Use `<temp>` as `luks_os_existing_passphrase`.

## Disaster recovery

Each volume has `<name>.key`, `<name>.luksheader` and `<name>.yml` (device, disk WWN/serial, LUKS UUID) in `luks-keys/<host>/`.

```bash
cryptsetup open --key-file data-XXXX.key /dev/sdX data-XXXX
cryptsetup luksHeaderRestore /dev/sdX --header-backup-file data-XXXX.luksheader
```

`luks-keys/` is in `.gitignore`. Back it up, encrypted:

```bash
tar czf - luks-keys | gpg --symmetric -o luks-keys.tgz.gpg
```
