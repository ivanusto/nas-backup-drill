# nas-backup-drill

English | [繁體中文](README.zh-TW.md)

Backup audit and restore drill tools for shared folders on a QNAP NAS. They work alongside QuTS hero snapshots and HBS 3 but do not depend on them. Snapshots and sync jobs make the copies; these tools prove the copies come back, and turn restore time (RTO), data point in time (RPO) and copy integrity into numbers.

| File | Runs on | What it does |
|---|---|---|
| `nas-audit.sh` | Any host that can ssh to the NAS, or the NAS itself | Lists pools, datasets, snapshot count and age per dataset, snapshot reserve properties, whether the snapshot schedule files exist, whether HBS 3 is installed, rsync modules and NFS exports, as Markdown |
| `share-canary.sh` | A Linux host that mounts the shared folder | Appends a heartbeat to the folder every minute and fsyncs it, and keeps a fixed payload with its sha256. `verify` points at a snapshot directory, a replica on the secondary NAS, or the folder after a revert, finds the restore point and RPO, and checks the payload. `verify` never writes |
| `replica-verify.sh` | Any host that sees both source and replica | `manifest` writes a sha256 list, `check` verifies every file, `quick` compares paths and sizes only |
| `restore-drill.sh` | The control host | Started when you trigger the restore; waits in order for `beats.log`, the canary check and the manifest check, then prints one drill-log row and a JSONL record |
| `policy.md` | Document (Traditional Chinese) | Audit results, data classification, snapshot and HBS 3 settings with their reasons, the 3-2-1 mapping, and limits found in testing |
| `drill-log.md` | Document (Traditional Chinese) | The four restore drills and their log |
| `outage-checklist.md` | Document (Traditional Chinese) | Checklist for a primary NAS shutdown drill |
| `tests/fake-flow.sh` | Any Linux | Runs the whole flow against fake shared folders |

## Usage

Audit (read only, no root needed):

```sh
NAS=user@primary-nas ./nas-audit.sh > audit-primary.md
NAS=user@secondary-nas ./nas-audit.sh > audit-secondary.md
```

Install one canary per protected shared folder, on the Linux host that mounts it. Root is needed to write to cron.d:

```sh
sudo ./share-canary.sh install /mnt/pve/QNAP-NAS/canary
sudo ./share-canary.sh install /mnt/container/canary
```

Make a manifest of the source before the drill:

```sh
./replica-verify.sh manifest /mnt/drill > drill.sha256
```

Start this the moment you trigger the restore:

```sh
./restore-drill.sh /mnt/drill/canary --label "3. restore from secondary NAS" \
  --failed-at 2026-10-02T03:10:00Z --manifest drill.sha256
```

To learn the data time of a snapshot or replica without restoring anything:

```sh
# Snapshot: NFS clients cannot see snapshot directories, so run it on the NAS.
# busybox date does not parse ISO time, so give the failure time as epoch seconds.
ssh user@primary-nas "CANARY_KIND=frozen sh -s verify /share/Drill/@Recently-Snapshot/GMT+08_2026-10-01_2200/canary 1790863232" < share-canary.sh
# Replica
./share-canary.sh verify /mnt/replica/drill/canary
```

## How the restore point is found

`verify` looks at how old the last heartbeat in `beats.log` is. Older than `CANARY_GAP_MIN` (180 seconds by default) means a frozen copy (snapshot or replica), and the last heartbeat is the restore point. Otherwise it is a live folder (cron started writing again after an in-place revert), and the restore point is the heartbeat just before the most recent gap longer than 180 seconds. Neither case writes anything, so it is safe on read-only snapshot directories and on replicas you do not want to touch.

A snapshot taken less than 180 seconds ago has a last heartbeat that has not crossed the threshold yet, so it looks live, and an older gap inside it gives a wrong restore point. Set `CANARY_KIND=frozen` when verifying such a snapshot to force the last heartbeat as the restore point. `live` forces the gap search; the default is `auto`.

## Limits on QNAP

The primary NAS has no git, scp or nohup, and `curl` lives in `/sbin/curl`. `nas-audit.sh` feeds itself to the remote sh over ssh and copies nothing. The canary runs on the Linux host that mounts the share, not on the NAS, because a QTS crontab needs extra work to survive a reboot while cron.d on the client does not.

## Exit codes

`share-canary.sh verify`: 0 restore point found and payload intact, 1 no gap found, 2 payload mismatch or missing.

`replica-verify.sh check` and `quick`: 0 everything matches, 1 missing files, size mismatch or hash mismatch.

`restore-drill.sh`: 0 drill passed, 2 payload still wrong at timeout, 3 `beats.log` never appeared before timeout, 4 manifest mismatch. The timeout defaults to 1800 seconds; change it with `--timeout`.

The manifest step in `restore-drill.sh` waits until every listed file exists and the folder size has stayed the same for `SETTLE` polls (5 by default) before it hashes, because the small canary often comes back before the rest of the data.

## Tests

```sh
sh tests/fake-flow.sh
shellcheck nas-audit.sh share-canary.sh replica-verify.sh restore-drill.sh tests/fake-flow.sh
```

CI runs both on every push.

## License

Apache-2.0
