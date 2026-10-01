#!/bin/sh
# nas-audit: what is actually protected on a QuTS hero NAS, as Markdown.
#
# Reads only. Prints pools, datasets, snapshot counts and ages per
# dataset, the snapshot reserve properties, whether a snapshot schedule
# exists, whether HBS 3 is installed, and the rsync modules. Paste the
# output into policy.md as the "before" and "after" evidence.
#
#   NAS=user@primary-nas ./nas-audit.sh        # over ssh
#   ./nas-audit.sh --local                        # on the NAS itself
#
# Non-root is enough for zfs list/get on QuTS hero. Lines that need root
# print "(無法讀取)" instead of failing. The NAS has no git, scp or
# nohup, so the script is piped to a remote sh and nothing is copied.
set -eu

# shellcheck disable=SC2016
remote='
set -u
h() { printf "\n## %s\n\n" "$1"; }
now=$(date -u +%s)
printf "# NAS audit %s (%s)\n" "$(hostname 2>/dev/null || echo nas)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf "\n韌體 %s\n" "$(getcfg System Version -f /etc/config/uLinux.conf 2>/dev/null || echo "(無法讀取)")"

h "儲存池"
printf "| 池 | 大小 | 已用 | 可用 | 使用率 | 健康 |\n|---|---|---|---|---|---|\n"
zpool list -H -o name,size,alloc,free,cap,health 2>/dev/null | awk -F"\t" "{printf \"| %s | %s | %s | %s | %s | %s |\n\", \$1,\$2,\$3,\$4,\$5,\$6}"

h "資料集"
printf "| 資料集 | 已用 | 本體 | 掛載點 |\n|---|---|---|---|\n"
zfs list -H -t filesystem,volume -o name,used,refer,mountpoint 2>/dev/null | awk -F"\t" "{printf \"| %s | %s | %s | %s |\n\", \$1,\$2,\$3,\$4}"

h "快照（每個資料集）"
printf "| 資料集 | 快照數 | 其中 :init: | 最舊 | 最新 | 快照佔用 |\n|---|---|---|---|---|---|\n"
snaps=$(zfs list -Hp -t snapshot -o name,creation,used 2>/dev/null || zfs list -H -t snapshot -o name,creation,used 2>/dev/null)
if [ -z "$snaps" ]; then printf "| (沒有快照) | | | | | |\n"; else
printf "%s\n" "$snaps" | awk -F"\t" -v now="$now" "
{ split(\$1, a, \"@\"); ds=a[1]; sn=a[2]
  n[ds]++; if (sn ~ /:init:/) init[ds]++
  c=\$2+0; if (c>0) { if (!(ds in old) || c<old[ds]) old[ds]=c; if (c>new[ds]) new[ds]=c }
  used[ds]+=\$3 }
function age(t){ d=now-t; if (d<0) d=0; if (d>=86400) return int(d/86400) \"d\"; if (d>=3600) return int(d/3600) \"h\"; return int(d/60) \"m\" }
function hb(b){ if (b>=1073741824) return sprintf(\"%.1f GiB\", b/1073741824); if (b>=1048576) return sprintf(\"%.1f MiB\", b/1048576); return b \" B\" }
END { for (ds in n) printf \"| %s | %d | %d | %s | %s | %s |\n\", ds, n[ds], init[ds]+0, (ds in old)?age(old[ds]) \" 前\":\"-\", (ds in new)?age(new[ds]) \" 前\":\"-\", hb(used[ds]) }" | sort
fi

h "快照相關屬性"
printf "\`\`\`\n"
zfs get -H -o name,property,value all 2>/dev/null | awk -F"\t" "\$2 ~ /snap/ && \$3 != \"-\" {printf \"%s  %s = %s\n\", \$1,\$2,\$3}" | sort | uniq
printf "\`\`\`\n"

h "快照排程與快照複本設定檔"
for f in /etc/config/qsnapshot/zsnapshotJob.conf /etc/config/qsnapshot/*.conf; do
  [ -e "$f" ] || continue
  sz=$(wc -c < "$f" 2>/dev/null || echo "?")
  printf -- "- %s：%s 位元組\n" "$f" "$sz"
done 2>/dev/null | sort -u || printf "(無法讀取)\n"

h "備份相關套件"
for p in HybridBackup SnapshotManager HDP_Business HDPBusiness QVPN; do
  v=$(getcfg "$p" Version -f /etc/config/qpkg.conf 2>/dev/null)
  en=$(getcfg "$p" Enable -f /etc/config/qpkg.conf 2>/dev/null)
  [ -n "$v" ] && printf -- "- %s %s（Enable=%s）\n" "$p" "$v" "${en:-?}"
done
[ -n "$(getcfg HybridBackup Version -f /etc/config/qpkg.conf 2>/dev/null)" ] || printf -- "- HBS 3 未安裝\n"

h "rsync 伺服器模組"
if [ -r /etc/config/rsyncd.conf ]; then
  awk "/^\[/{gsub(/[][]/,\"\"); printf \"- %s\n\", \$0}" /etc/config/rsyncd.conf
else
  printf "(無法讀取 /etc/config/rsyncd.conf)\n"
fi

h "NFS 匯出"
if [ -r /etc/exports ]; then printf "\`\`\`\n"; cat /etc/exports; printf "\`\`\`\n"; else printf "(無法讀取 /etc/exports)\n"; fi
'

case "${1:-}" in
  --local) exec sh -c "$remote" ;;
  "") [ -n "${NAS:-}" ] || { sed -n '2,15p' "$0"; exit 1; }
      printf '%s\n' "$remote" | ssh -o BatchMode=yes "$NAS" sh -s ;;
  *) printf 'nas-audit: unknown option %s\n' "$1" >&2; exit 1 ;;
esac
