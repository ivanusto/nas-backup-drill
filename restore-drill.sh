#!/bin/sh
# restore-drill: times a shared-folder restore end to end and prints one
# drill-log row plus a JSONL record.
#
# Start it the moment you trigger the restore (snapshot revert, snapshot
# file copy, HBS 3 restore from the secondary NAS, or a remount of the
# replica). It polls every 2 seconds until, in order:
#
#   appear    <PATH>/beats.log is readable
#   canary    share-canary.sh verify passes (payload sha256 intact)
#   manifest  optional: every file in a replica-verify manifest is back
#             (waits until every listed file exists and the tree has
#             stopped growing for SETTLE polls, default 5, then hashes)
#
# RTO is the last step that applies. RPO comes from the canary.
#
#   restore-drill.sh PATH [--label TEXT] [--failed-at ISO|EPOCH]
#                         [--manifest FILE] [--timeout SEC] [--t0 ISO|EPOCH]
#
# PATH is the canary directory inside the restored copy, e.g.
# /mnt/pve/QNAP-NAS/canary or /mnt/replica/Container/canary.
# --manifest FILE checks the parent of PATH (the share root) with
# replica-verify.sh check; the manifest was made with replica-verify.sh
# manifest before the drill.
#
# Exit: 0 passed, 2 payload mismatch at timeout, 3 timeout before the
# canary appeared, 4 manifest mismatch.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
CANARY=${CANARY:-$HERE/share-canary.sh}
VERIFY=${VERIFY:-$HERE/replica-verify.sh}
OUT=${OUT:-drills.jsonl}
INTERVAL=${INTERVAL:-2}
SETTLE=${SETTLE:-5}   # polls with every manifest file present and an unchanged size before the full check

path=${1:-}; [ -n "$path" ] || { sed -n '2,24p' "$0"; exit 1; }
shift
label=drill; failed_at=; manifest=; timeout=1800; t0=
while [ $# -gt 0 ]; do
  case "$1" in
    --label)     label=$2; shift 2 ;;
    --failed-at) failed_at=$2; shift 2 ;;
    --manifest)  manifest=$2; shift 2 ;;
    --timeout)   timeout=$2; shift 2 ;;
    --t0)        t0=$2; shift 2 ;;
    *) printf 'restore-drill: unknown option %s\n' "$1" >&2; exit 1 ;;
  esac
done

to_epoch() {
  case "$1" in
    ''|*[!0-9]*) date -u -d "$1" +%s ;;
    *) printf '%s' "$1" ;;
  esac
}
iso_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
now() { date -u +%s; }

if [ -n "$t0" ]; then t0=$(to_epoch "$t0"); else t0=$(now); fi
since() { printf '%s' "$(( $(now) - t0 ))"; }
expired() { [ "$(since)" -ge "$timeout" ]; }

log() { printf '[+%ss] %s\n' "$(since)" "$*" >&2; }

t_appear=-; t_canary=-; t_manifest=-; result=FAIL; code=3
restore_point=-; rpo='?'; payload=-; kind=-

# 1. appear
log "waiting for $path/beats.log"
while ! [ -r "$path/beats.log" ]; do
  if expired; then log "timeout: beats.log never appeared"; break; fi
  sleep "$INTERVAL"
done
if [ -r "$path/beats.log" ]; then
  t_appear=$(since)
  log "beats.log present"
fi

# 2. canary: keep retrying while files are still being written back
if [ "$t_appear" != - ]; then
  last=
  while :; do
    set +e
    v=$("$CANARY" verify "$path" "$failed_at" 2>/dev/null)
    rc=$?
    set -e
    last=$rc
    for kv in $v; do
      case "$kv" in
        kind=*) kind=${kv#kind=} ;;
        restore_point=*) restore_point=${kv#restore_point=} ;;
        rpo=*) rpo=${kv#rpo=} ;;
        payload=*) payload=${kv#payload=} ;;
      esac
    done
    if [ "$rc" -eq 0 ]; then
      t_canary=$(since)
      log "canary ok: restore_point=$restore_point rpo=$rpo"
      break
    fi
    if expired; then
      log "timeout: canary rc=$rc payload=$payload"
      break
    fi
    sleep "$INTERVAL"
  done
  if [ "$t_canary" != - ]; then
    code=0
  elif [ "$last" = 2 ]; then
    code=2
  fi
fi

# 3. manifest. The canary is small and often lands first, so wait until
# every listed file exists and the tree stops growing before hashing it.
if [ "$code" -eq 0 ] && [ -n "$manifest" ]; then
  root=$(dirname "$path")
  log "waiting for manifest files to land"
  prev=-1; same=0
  while :; do
    missing=$(cut -c67- "$manifest" | while IFS= read -r f; do
      [ -f "$root/$f" ] || echo x
    done | wc -l | tr -d ' ')
    kb=$(du -sk "$root" 2>/dev/null | cut -f1)
    if [ "$missing" -eq 0 ] && [ "$kb" = "$prev" ]; then same=$((same + 1)); else same=0; fi
    [ "$same" -ge "$SETTLE" ] && break
    prev=$kb
    if expired; then log "timeout: $missing manifest files still missing"; break; fi
    sleep "$INTERVAL"
  done
  set +e
  "$VERIFY" check "$root" "$manifest" >&2
  rc=$?
  set -e
  t_manifest=$(since)
  if [ "$rc" -ne 0 ]; then code=4; log "manifest mismatch"; else log "manifest ok"; fi
fi

[ "$code" -eq 0 ] && result=OK
rto=-
if [ "$code" -eq 0 ]; then
  rto=$t_canary
  [ "$t_manifest" != - ] && rto=$t_manifest
fi

# size and rate, best effort
kb=$(du -sk "$(dirname "$path")" 2>/dev/null | cut -f1 || echo 0)
mb=$(( ${kb:-0} / 1024 ))
rate=-
if [ "$rto" != - ] && [ "$rto" -gt 0 ]; then
  rate=$(( mb / rto ))
fi

s() { case "$1" in -) printf -- '-' ;; *) printf '%ss' "$1" ;; esac; }

# shellcheck disable=SC2016
printf '| %s | %s | `%s` | %s | %s | %s | %s | %s | %s | %s MB | %s | %s |  |\n' \
  "$(iso_of "$t0")" "$label" "$path" "$restore_point" \
  "$(s "$t_appear")" "$(s "$t_canary")" "$(s "$t_manifest")" "$(s "$rto")" \
  "$( [ "$rpo" = "?" ] && printf '?' || printf '%ss' "$rpo" )" \
  "$mb" "$( [ "$rate" = - ] && printf -- '-' || printf '%s MB/s' "$rate" )" "$result"

printf '{"t0":"%s","label":"%s","path":"%s","kind":"%s","restore_point":"%s","appear":"%s","canary":"%s","manifest":"%s","rto":"%s","rpo":"%s","payload":"%s","size_mb":%s,"rate_mbs":"%s","result":"%s","code":%s}\n' \
  "$(iso_of "$t0")" "$label" "$path" "$kind" "$restore_point" \
  "$t_appear" "$t_canary" "$t_manifest" "$rto" "$rpo" "$payload" "$mb" "$rate" "$result" "$code" >> "$OUT"

exit "$code"
