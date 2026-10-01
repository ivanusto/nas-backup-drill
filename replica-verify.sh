#!/bin/sh
# replica-verify: proves a replica (or a restored folder) holds the same
# files as the source, not just the same number of bytes.
#
#   replica-verify.sh manifest DIR > m.sha256   # sha256 of every file, sorted
#   replica-verify.sh check DIR m.sha256        # verify DIR against a manifest
#   replica-verify.sh quick SRC DST             # path + size compare, no hashing
#
# manifest walks DIR and hashes every regular file. Run it on the source
# before the drill (mounted anywhere, or over ssh on the NAS). On a large
# share it takes as long as reading the share once.
#
# check runs sha256sum -c inside DIR and prints ok / missing / mismatch
# counts. Exit 0 only when every entry is ok.
#
# quick lists relative path and size on both sides and diffs the lists.
# It is what you run when hashing 262 GB is not on the schedule; it
# catches missing and truncated files, not silent bit flips.
#
# Skips @Recently-Snapshot, .snapshot, @Recycle and .streams so a source
# with visible snapshots does not fail against a replica without them,
# and skips beats.log, which is expected to differ between copies.
# POSIX sh; GNU or busybox find, stat, sha256sum (or openssl).
set -eu

PRUNE='-name @Recently-Snapshot -o -name .snapshot -o -name @Recycle -o -name .streams -o -name .@__thumb'

die() { printf 'replica-verify: %s\n' "$*" >&2; exit 1; }

hasher() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    printf '%s  %s\n' "$(openssl dgst -sha256 "$1" | awk '{print $NF}')" "$1"
  fi
}

# relative regular files under ., sorted, prune list applied
files() {
  # shellcheck disable=SC2086
  find . \( $PRUNE \) -prune -o -type f ! -name beats.log -print | LC_ALL=C sort
}

size_of() {
  if stat -c %s "$1" >/dev/null 2>&1; then stat -c %s "$1"; else
    # busybox without -c: fall back to ls
    # shellcheck disable=SC2012
    ls -ln "$1" | awk '{print $5}'
  fi
}

cmd_manifest() {
  [ -d "$1" ] || die "$1 is not a directory"
  cd "$1"
  files | while IFS= read -r f; do hasher "$f"; done
}

cmd_check() {
  dir=$1; m=$2
  [ -d "$dir" ] || die "$dir is not a directory"
  [ -s "$m" ] || die "manifest $m is empty"
  case "$m" in /*) ;; *) m=$(pwd)/$m ;; esac
  cd "$dir"
  ok=0; missing=0; bad=0
  # sha256sum -c prints "path: OK|FAILED|FAILED open or read"
  # Some busybox builds lack -c, so hash ourselves.
  while IFS= read -r line; do
    want=${line%% *}
    f=${line#*  }
    if [ ! -f "$f" ]; then
      missing=$((missing + 1)); printf 'MISSING %s\n' "$f"
    elif [ "$(hasher "$f" | cut -d' ' -f1)" = "$want" ]; then
      ok=$((ok + 1))
    else
      bad=$((bad + 1)); printf 'MISMATCH %s\n' "$f"
    fi
  done < "$m"
  printf 'ok=%s missing=%s mismatch=%s\n' "$ok" "$missing" "$bad"
  [ "$missing" -eq 0 ] && [ "$bad" -eq 0 ]
}

listing() {
  cd "$1"
  files | while IFS= read -r f; do printf '%s %s\n' "$(size_of "$f")" "$f"; done | LC_ALL=C sort
}

cmd_quick() {
  src=$1; dst=$2
  [ -d "$src" ] || die "$src is not a directory"
  [ -d "$dst" ] || die "$dst is not a directory"
  a=$(mktemp); b=$(mktemp)
  listing "$src" > "$a"
  listing "$dst" > "$b"
  n_src=$(wc -l < "$a" | tr -d ' ')
  n_dst=$(wc -l < "$b" | tr -d ' ')
  # lines only in src (missing or different size on dst), only in dst (extra)
  only_src=$(LC_ALL=C comm -23 "$a" "$b" | wc -l | tr -d ' ')
  only_dst=$(LC_ALL=C comm -13 "$a" "$b" | wc -l | tr -d ' ')
  LC_ALL=C comm -23 "$a" "$b" | sed 's/^/SRC_ONLY /'
  LC_ALL=C comm -13 "$a" "$b" | sed 's/^/DST_ONLY /'
  rm -f "$a" "$b"
  printf 'src_files=%s dst_files=%s src_only=%s dst_only=%s\n' "$n_src" "$n_dst" "$only_src" "$only_dst"
  [ "$only_src" -eq 0 ]
}

[ $# -ge 2 ] || { sed -n '2,22p' "$0"; exit 1; }
cmd=$1; shift
case "$cmd" in
  manifest) cmd_manifest "$1" ;;
  check)    [ $# -eq 2 ] || die "check DIR MANIFEST"; cmd_check "$1" "$2" ;;
  quick)    [ $# -eq 2 ] || die "quick SRC DST"; cmd_quick "$1" "$2" ;;
  *) die "unknown command: $cmd" ;;
esac
