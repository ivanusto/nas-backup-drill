#!/bin/sh
# End-to-end test with fake shares under a temp dir. No NAS, no root,
# no cron. Exercises canary install/beat/verify (frozen and live copies),
# replica-verify manifest/check/quick, restore-drill success, payload
# mismatch, manifest mismatch and timeout.
# shellcheck disable=SC2016,SC2034
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T"

export CANARY_NO_CRON=1 CANARY_PAYLOAD_MIB=1 CANARY_GAP_MIN=180 INTERVAL=1 OUT="$T/drills.jsonl"
CANARY="$HERE/share-canary.sh"; VERIFY="$HERE/replica-verify.sh"; DRILL="$HERE/restore-drill.sh"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

now=$(date -u +%s)
# beats.log with beats every 60 s from now-900 to now-300, then nothing:
# what a snapshot or replica taken at now-300 looks like.
fake_beats() {
  : > "$1"
  t=$((now - 900))
  while [ "$t" -le $((now - 300)) ]; do
    printf '%s %s fakehost\n' "$t" "$(date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ)" >> "$1"
    t=$((t + 60))
  done
}

# --- source share with a canary and some data
mkdir -p src/canary src/data/sub
"$CANARY" install "$T/src/canary" >/dev/null
check "install creates payload and sha256" '[ -s src/canary/payload.bin ] && [ -s src/canary/payload.sha256 ]'
check "install wrote a first beat" '[ "$(wc -l < src/canary/beats.log)" -eq 1 ]'
"$CANARY" beat "$T/src/canary"
check "beat appends" '[ "$(wc -l < src/canary/beats.log)" -eq 2 ]'
head -c 300000 /dev/urandom > src/data/a.bin
printf 'hello\n' > src/data/sub/b.txt
mkdir -p src/@Recently-Snapshot/x; printf 'ignored\n' > src/@Recently-Snapshot/x/z

# --- manifest of the source
"$VERIFY" manifest "$T/src" > m.sha256
check "manifest lists 4 files, skips @Recently-Snapshot and beats.log" '[ "$(wc -l < m.sha256)" -eq 4 ] && ! grep -q Recently m.sha256'

# --- frozen copy (replica / snapshot): beats end 300 s ago
cp -r src replica
fake_beats replica/canary/beats.log
v=$("$CANARY" verify "$T/replica/canary" "$now")
check "verify frozen copy: restore point is the last beat" 'printf "%s" "$v" | grep -q "kind=frozen" && printf "%s" "$v" | grep -q "rpo=300 "'
check "verify frozen copy: payload ok" 'printf "%s" "$v" | grep -q "payload=ok"'
check "verify accepts ISO failed-at" '"$CANARY" verify "$T/replica/canary" "$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)" | grep -q "rpo=300 "'

# --- live copy after an in-place revert: cron resumed 30 s ago
cp -r src live
fake_beats live/canary/beats.log
printf '%s %s fakehost\n' $((now - 30)) "$(date -u -d "@$((now - 30))" +%Y-%m-%dT%H:%M:%SZ)" >> live/canary/beats.log
v=$("$CANARY" verify "$T/live/canary" "$now")
check "verify live copy: boundary is the gap, restore point before it" 'printf "%s" "$v" | grep -q "kind=live" && printf "%s" "$v" | grep -q "rpo=300 "'

# --- snapshot taken 30 s ago that still carries an older gap: auto mistakes it
# for a live folder, CANARY_KIND=frozen takes the last beat
v=$(CANARY_KIND=frozen "$CANARY" verify "$T/live/canary" "$now")
check "CANARY_KIND=frozen on a fresh snapshot: restore point is the last beat" 'printf "%s" "$v" | grep -q "kind=frozen" && printf "%s" "$v" | grep -q "rpo=30 "'
check "CANARY_KIND rejects unknown values" '! CANARY_KIND=x "$CANARY" verify "$T/live/canary" >/dev/null 2>&1'

# --- live copy with no gap at all
cp -r src nogap
v=$("$CANARY" verify "$T/nogap/canary" "$now" || true)
check "verify live copy without gap reports NO_BOUNDARY" 'printf "%s" "$v" | grep -q NO_BOUNDARY'

# --- payload mismatch
cp -r replica broken
printf 'x' >> broken/canary/payload.bin
check "verify detects payload mismatch (exit 2)" '"$CANARY" verify "$T/broken/canary" >/dev/null 2>&1; [ $? -eq 2 ]'

# --- replica-verify check and quick
check "check passes on intact replica" '"$VERIFY" check "$T/replica" m.sha256 >/dev/null'
mkdir -p partial && cp -r replica/canary partial/ && mkdir -p partial/data && cp replica/data/a.bin partial/data/
check "check reports the missing file" '"$VERIFY" check "$T/partial" m.sha256 | grep -q "missing=1"'
check "check fails on missing file (exit code)" '! "$VERIFY" check "$T/partial" m.sha256 >/dev/null'
check "quick passes on intact replica" '"$VERIFY" quick "$T/src" "$T/replica" >/dev/null'
check "quick reports src_only on partial replica" '"$VERIFY" quick "$T/src" "$T/partial" | grep -q "src_only=1"'

# --- restore-drill: the restored copy appears 3 s after T0
rm -rf restored
( sleep 3; cp -r replica restored ) &
row=$("$DRILL" "$T/restored/canary" --label "fake restore" --failed-at "$now" --manifest "$T/m.sha256" --timeout 20 2>/dev/null)
check "drill passes with manifest and prints an OK row" 'printf "%s" "$row" | grep -q "| OK |"'
check "drill row carries RPO 300s" 'printf "%s" "$row" | grep -q "| 300s |"'
check "drill appends JSONL" 'grep -q "\"label\":\"fake restore\"" "$OUT" && grep -q "\"code\":0" "$OUT"'
wait

# --- restore-drill: the canary lands first and the rest 4 s later, as an
# HBS 3 job with the canary in its own folder pair does; the manifest must wait
rm -rf staged; mkdir staged; cp -r replica/canary staged/
( sleep 4; for d in replica/*; do [ "$d" = replica/canary ] || cp -r "$d" staged/; done ) &
row=$(INTERVAL=1 SETTLE=2 "$DRILL" "$T/staged/canary" --label "staged" --manifest "$T/m.sha256" --timeout 30 2>/dev/null)
check "drill waits for files that land after the canary" 'printf "%s" "$row" | grep -q "| OK |"'
wait

# --- restore-drill: manifest mismatch (exit 4)
rm -rf restored2; cp -r partial restored2
set +e; INTERVAL=1 "$DRILL" "$T/restored2/canary" --label "partial" --manifest "$T/m.sha256" --timeout 5 >/dev/null 2>&1; rc=$?; set -e
check "drill exits 4 on manifest mismatch" '[ "$rc" -eq 4 ]'

# --- restore-drill: payload mismatch until timeout (exit 2)
set +e; "$DRILL" "$T/broken/canary" --label "broken" --timeout 3 >/dev/null 2>&1; rc=$?; set -e
check "drill exits 2 on payload mismatch at timeout" '[ "$rc" -eq 2 ]'

# --- restore-drill: never appears (exit 3)
set +e; "$DRILL" "$T/never/canary" --label "never" --timeout 3 >/dev/null 2>&1; rc=$?; set -e
check "drill exits 3 on timeout" '[ "$rc" -eq 3 ]'

# --- remove is safe without cron dir
CANARY_CRON_DIR="$T/cron" "$CANARY" remove "$T/src/canary" >/dev/null
ok "remove without cron entry does not fail"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
