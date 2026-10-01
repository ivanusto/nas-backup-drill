# nas-backup-drill

QNAP NAS 共享資料夾的備份盤點與還原演練工具。搭配 QuTS hero 的快照與 HBS 3 使用，但不依賴它們。快照與同步工作負責產生副本，這裡負責證明副本回得來，並把還原時間（RTO）、資料時間點（RPO）與副本完整性量成數字。

| 檔案 | 跑在哪 | 做什麼 |
|---|---|---|
| `nas-audit.sh` | 任何能 ssh 到 NAS 的機器，或 NAS 本機 | 列出儲存池、資料集、每個資料集的快照數與新舊、快照保留屬性、快照排程檔是否存在、HBS 3 是否安裝、rsync 模組與 NFS 匯出，輸出 Markdown |
| `share-canary.sh` | 掛載了共享資料夾的 Linux 主機 | 每分鐘往資料夾寫一筆心跳並 fsync，保存固定 payload 與其 sha256。`verify` 指向快照目錄、次要 NAS 的副本或回復後的資料夾，找出還原點與 RPO，校驗 payload。`verify` 不寫入 |
| `replica-verify.sh` | 任何能同時看到來源與副本的主機 | `manifest` 產生 sha256 清單，`check` 逐檔校驗，`quick` 只比路徑與大小 |
| `restore-drill.sh` | 控制端 | 按下還原時啟動，依序等 `beats.log` 出現、canary 驗證、manifest 校驗，印出 drill-log 的一列與 JSONL |
| `policy.md` | 文件 | 盤點結果、資料分級、快照與 HBS 3 的設定與依據、3-2-1 對照、實測到的邊界 |
| `drill-log.md` | 文件 | 四個還原演練與紀錄表 |
| `outage-checklist.md` | 文件 | 主 NAS 停機演練的檢查清單 |
| `tests/fake-flow.sh` | 任何 Linux | 以假的共享資料夾跑完整流程 |

## 用法

盤點（唯讀，非 root 即可）：

```sh
NAS=user@primary-nas ./nas-audit.sh > audit-primary.md
NAS=user@secondary-nas ./nas-audit.sh > audit-secondary.md
```

在每個要保護的共享資料夾裝一個 canary。在掛載了該資料夾的 Linux 主機上執行，需要 root 寫 cron.d：

```sh
sudo ./share-canary.sh install /mnt/pve/QNAP-NAS/canary
sudo ./share-canary.sh install /mnt/container/canary
```

演練前先做來源的 manifest：

```sh
./replica-verify.sh manifest /mnt/drill > drill.sha256
```

按下還原的同時執行：

```sh
./restore-drill.sh /mnt/drill/canary --label "3. 從次要 NAS 還原" \
  --failed-at 2026-10-02T03:10:00Z --manifest drill.sha256
```

只想知道一份快照或副本的資料時間，不必等還原：

```sh
# 快照：NFS 用戶端看不到快照目錄，在 NAS 本機跑；busybox 的 date 不吃 ISO，故障時間給 epoch
ssh user@primary-nas "CANARY_KIND=frozen sh -s verify /share/Drill/@Recently-Snapshot/GMT+08_2026-10-01_2200/canary 1790863232" < share-canary.sh
# 副本
./share-canary.sh verify /mnt/replica/drill/canary
```

## 還原點怎麼判定

`verify` 看 `beats.log` 的最後一筆心跳距現在多久。超過 `CANARY_GAP_MIN`（預設 180 秒）就是凍結的複本（快照、副本），最後一筆心跳就是還原點。沒超過就是活的資料夾（原地回復後 cron 又開始寫），找最後一個超過 180 秒的斷層，斷層前一筆是還原點。兩種情況都不需要寫入，所以對唯讀的快照目錄與不想弄髒的副本都安全。

剛建好不到 180 秒的快照，最後一筆心跳還沒超過門檻，會被當成活的資料夾，若裡面留有更早的斷層就會報錯還原點。驗證這種快照時設 `CANARY_KIND=frozen`，強制以最後一筆心跳為還原點；`live` 則強制找斷層，預設 `auto`。

## QNAP 上的限制

主 NAS 沒有 git、scp、nohup，`curl` 在 `/sbin/curl`。`nas-audit.sh` 把腳本經 ssh 餵給遠端的 sh，不複製任何檔案。canary 不在 NAS 上跑，在掛載共享資料夾的 Linux 主機上跑，因為 QTS 的 crontab 要另外處理才能跨重開機保留，而掛載端的 cron.d 沒有這個問題。

## 結束碼

`share-canary.sh verify`：0 找到還原點且 payload 正確，1 找不到斷層，2 payload 不符或缺少。

`replica-verify.sh check` 與 `quick`：0 全數一致，1 有缺檔、大小不符或雜湊不符。

`restore-drill.sh`：0 演練通過，2 逾時前 payload 一直不符，3 逾時前 `beats.log` 沒出現，4 manifest 不符。逾時預設 1800 秒，`--timeout` 調整。

## 測試

```sh
sh tests/fake-flow.sh
shellcheck nas-audit.sh share-canary.sh replica-verify.sh restore-drill.sh tests/fake-flow.sh
```

CI 在每次 push 跑這兩項。

## 授權

Apache-2.0
