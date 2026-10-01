#!/bin/sh
# share-canary: proves which point in time a restored shared folder came
# back from, and that its data is intact.
#
# Runs on any Linux host that mounts the protected shared folder (NFS or
# SMB). Every minute it appends one heartbeat line (epoch seconds, ISO
# time, hostname) to beats.log inside the share and fsyncs it, and keeps
# a fixed payload file whose sha256 was recorded at install.
#
# After a restore you point "verify" at wherever the restored copy is:
# a snapshot directory (@Recently-Snapshot/<name>/canary), a replica on
# the secondary NAS, or the folder itself after an in-place revert.
# verify never writes, so it is safe on read-only snapshots and on a
# replica you do not want to dirty.
#
#   share-canary.sh install DIR            # cron.d entry + payload + sha256
#   share-canary.sh beat DIR               # one heartbeat (cron calls this)
#   share-canary.sh verify DIR [FAILED_AT] # FAILED_AT is ISO UTC or epoch
#   share-canary.sh remove DIR             # drop the cron.d entry only
#
# DIR is a directory inside the share, e.g. /mnt/pve/QNAP-NAS/canary.
# One share, one DIR. Several shares, several installs.
#
# POSIX sh; needs coreutils date (-d) for ISO input, sha256sum or openssl.
set -eu

PAYLOAD_MIB=${CANARY_PAYLOAD_MIB:-64}
GAP_MIN=${CANARY_GAP_MIN:-180}     # seconds; a gap larger than this is a restore boundary
KIND=${CANARY_KIND:-auto}          # auto, frozen or live; force frozen for a snapshot taken minutes ago
CRON_DIR=${CANARY_CRON_DIR:-/etc/cron.d}
BIN=${CANARY_BIN:-/usr/local/bin/share-canary.sh}

die() { printf 'share-canary: %s\n' "$*" >&2; exit 1; }

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '-' | sed 's/^-*//; s/-*$//; s/--*/-/g'; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

to_epoch() {
  case "$1" in
    ''|*[!0-9]*) date -u -d "$1" +%s ;;
    *) printf '%s' "$1" ;;
  esac
}

iso_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

cmd_install() {
  dir=$1
  mkdir -p "$dir"
  if [ ! -f "$dir/payload.bin" ]; then
    dd if=/dev/urandom of="$dir/payload.bin" bs=1M count="$PAYLOAD_MIB" status=none
    sha256_of "$dir/payload.bin" > "$dir/payload.sha256"
    sync "$dir/payload.bin" "$dir/payload.sha256" 2>/dev/null || sync
  fi
  if [ -z "${CANARY_NO_CRON:-}" ]; then
    [ "$(id -u)" -eq 0 ] || die "install needs root for $CRON_DIR (set CANARY_NO_CRON=1 to skip cron)"
    if [ ! -f "$BIN" ] || ! cmp -s "$0" "$BIN"; then
      cp "$0" "$BIN"
      chmod 0755 "$BIN"
    fi
    f="$CRON_DIR/share-canary-$(slug "$dir")"
    printf '* * * * * root %s beat %s\n' "$BIN" "$dir" > "$f"
    chmod 0644 "$f"
  fi
  cmd_beat "$dir"
  printf 'share-canary installed: %s (payload %s MiB, sha256 %s)\n' \
    "$dir" "$PAYLOAD_MIB" "$(cut -c1-12 "$dir/payload.sha256")"
}

cmd_remove() {
  f="$CRON_DIR/share-canary-$(slug "$1")"
  rm -f "$f"
  printf 'share-canary: removed %s (data in %s kept)\n' "$f" "$1"
}

cmd_beat() {
  dir=$1
  [ -d "$dir" ] || die "$dir missing, run install first"
  now=$(date -u +%s)
  printf '%s %s %s\n' "$now" "$(iso_of "$now")" "$(hostname)" >> "$dir/beats.log"
  # fsync so the beat is on disk before the next snapshot or sync
  sync "$dir/beats.log" 2>/dev/null || sync
}

cmd_verify() {
  dir=$1
  failed_at=${2:-}
  [ -s "$dir/beats.log" ] || die "no beats in $dir/beats.log"

  now=$(date -u +%s)
  last=$(awk 'END{print $1}' "$dir/beats.log")
  age=$((now - last))

  # Two shapes of a restored copy:
  #  frozen: a snapshot or a replica. Beats stop at the copy time, so the
  #          last beat is the restore point.
  #  live:   the folder itself after an in-place revert. Cron keeps
  #          beating, so the boundary is the most recent gap larger than
  #          GAP_MIN and the beat before it is the restore point.
  # A snapshot younger than GAP_MIN looks live to auto, so set
  # CANARY_KIND=frozen when verifying a snapshot taken minutes ago.
  case "$KIND" in
    auto|frozen|live) ;;
    *) die "CANARY_KIND must be auto, frozen or live" ;;
  esac
  if [ "$KIND" = frozen ] || { [ "$KIND" = auto ] && [ "$age" -gt "$GAP_MIN" ]; }; then
    kind=frozen
    rp=$last
    gap=$age
  else
    kind=live
    set -- "$(awk -v g="$GAP_MIN" '
      NR>1 && $1-prev>g {rp=prev; gap=$1-prev}
      {prev=$1}
      END{print rp+0, gap+0}' "$dir/beats.log")"
    # shellcheck disable=SC2086
    set -- $1
    rp=$1; gap=$2
    [ "$rp" -gt 0 ] || { printf 'result=NO_BOUNDARY kind=live last_beat=%s\n' "$(iso_of "$last")"; exit 1; }
  fi

  payload=missing
  if [ -f "$dir/payload.bin" ] && [ -s "$dir/payload.sha256" ]; then
    want=$(tr -d ' \n' < "$dir/payload.sha256")
    got=$(sha256_of "$dir/payload.bin")
    if [ "$want" = "$got" ]; then payload=ok; else payload=mismatch; fi
  fi

  rpo='?'
  if [ -n "$failed_at" ]; then
    fe=$(to_epoch "$failed_at")
    rpo=$((fe - rp))
  fi

  ntp=unknown
  if command -v timedatectl >/dev/null 2>&1; then
    ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)
  fi

  printf 'kind=%s restore_point=%s restore_epoch=%s gap=%ss rpo=%s payload=%s beats=%s ntp=%s\n' \
    "$kind" "$(iso_of "$rp")" "$rp" "$gap" "$rpo" "$payload" "$(wc -l < "$dir/beats.log" | tr -d ' ')" "$ntp"

  case "$payload" in
    ok) exit 0 ;;
    *) exit 2 ;;
  esac
}

[ $# -ge 2 ] || { sed -n '2,22p' "$0"; exit 1; }
cmd=$1; shift
case "$cmd" in
  install) cmd_install "$1" ;;
  beat)    cmd_beat "$1" ;;
  verify)  cmd_verify "$1" "${2:-}" ;;
  remove)  cmd_remove "$1" ;;
  *) die "unknown command: $cmd" ;;
esac
