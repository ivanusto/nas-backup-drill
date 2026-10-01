# 還原演練紀錄

每一列由 `restore-drill.sh` 印出，貼上後補「備註」欄。時間全部 UTC，秒數從按下還原算起。

欄位說明

- 還原點：`share-canary.sh verify` 找到的資料時間。快照或副本這類凍結的複本，是最後一筆心跳。原地回復的資料夾，是最後一個斷層之前的那一筆
- 出現 / canary / manifest / RTO：`beats.log` 可讀、payload 校驗通過、manifest 全數通過，各自距 T0 的秒數。RTO 取最後一個有做的步驟
- RPO：模擬故障時間減還原點，`--failed-at` 沒給時為 ?
- 大小與速率：還原目錄的 `du -sk` 除以 RTO，只在整份資料是還原回來的情況下有意義
- 結果：OK 是 payload 與 manifest 都通過，FAIL 是校驗不符或逾時

演練資料集：共享資料夾 `Drill`，內含 canary 目錄與 20 GB 的隨機檔（`head -c 20G /dev/urandom`，分成 20 個 1 GB 檔），manifest 事先以 `replica-verify.sh manifest` 產生。

| T0 | 演練 | 路徑 | 還原點 | 出現 | canary | manifest | RTO | RPO | 大小 | 速率 | 結果 | 備註 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-10-01T14:00:32Z | 1. 從快照目錄取回單一檔案 | `/mnt/drill/canary` | 2026-10-01T14:00:01Z | 0s | 31s | 69s | 31s | 31s | 64 MiB | - | OK | 取回在 NAS 本機 cp（NFS 看不到快照目錄），NAS 上 10s 完成，用戶端快取到 31s 才看到；還原點以 CANARY_KIND=frozen 對 22:00 快照驗證，restore-drill 印的 13:00:01 與 RPO 3631s 是沿用演練 2 的斷層，作廢；69s 是整個資料夾 manifest |
| 2026-10-01T13:38:49Z | 2. 整個共享資料夾回復到快照 | `/mnt/drill/canary` | 2026-10-01T13:00:01Z | 0s | 653s | 694s | 694s | 1799s | 20549 MB | - | OK | T0 取 NAS 事件日誌的回復開始時間；NAS 回報完成在 552s；用戶端 I/O 在 +192s 到 +656s 之間停住（hard mount，無錯誤，只有逾時）；回復期間整台 NAS 的 NFS 暫停，沒掛 Drill 的 PVE 節點也報 not responding |
| 2026-10-01T14:22:55Z | 3. 從次要 NAS 還原回主 NAS | `/mnt/drill/canary` | 2026-10-01T14:14:01Z | - | 99s | 684s | 684s | 534s | 20549 MB | 47.7 MiB/s | OK | T0 取刪除時間（故障時間）；第一次執行因目的地資料夾不存在而失敗，22:23:56 手動建回 data/ 與 canary/；canary 與 data 分屬兩個工作（Sync 3 8s、Sync 2 429s）；速率只算 Sync 2 的傳輸段；出現欄不計，因為 cron 先在空資料夾建了 beats.log；restore-drill 當場印的 FAIL 是 manifest 只檢查一次的缺陷，已修，本列以手動 check 為準 |
| 2026-10-01T15:35:24Z | 4. PVE 直接從副本開機 VM | vm:100 → 9100（次要 NAS 副本） | 2026-10-01T15:14:14Z | - | - | - | 33s | 1270s | 70.3 GiB | - | OK | RTO 取客體代理回應並回報原 IP；這台沒開遠端桌面、防火牆擋 ping 與 SMB，外部訊號量不到；Windows 記 Kernel-Power 41 與 6008，NTFS 98 兩個磁碟區健康；第一次同步沒開快照，副本 qcow2 有 54 個錯誤，開快照重跑後為 0 |

## 四個演練

| 演練 | 做法 | 看什麼 |
|---|---|---|
| 1. 從快照目錄取回單一檔案 | 刪掉 `Drill/canary/payload.bin`，從 `@Recently-Snapshot/<最新快照>/canary/` 複製回來 | RTO 應在秒級。先對快照目錄跑 `verify`，得到這份快照的還原點，快照的 RPO 就是距上一次排程的時間 |
| 2. 整個共享資料夾回復到快照 | 先在 `Drill` 寫入 5 GB 新檔並刪掉 5 個舊檔，再用 Storage & Snapshots 對 `Drill` 做回復（revert）到前一份快照 | 回復耗時是否與資料集大小無關。回復期間在一台節點上持續讀 `Drill` 的檔案，記錄 NFS 用戶端看到的錯誤（stale handle 或短暫 I/O error） |
| 3. 從次要 NAS 還原回主 NAS | 確認 `Drill` 已同步到次要 NAS 且 manifest 通過，刪掉主 NAS 的 `Drill` 內容，建一個反向的 RTRR 單向同步工作（次要到主）跑一次 | 速率 MB/s，據此推算 HDP_Business 262 GB 的還原時間。manifest 要全數通過 |
| 4. PVE 直接從副本開機 VM | 把次要 NAS 的 images 副本以 NFS 加進 PVE 儲存，停掉原 VM，`qm create` 一台新 VM 指向副本裡的 qcow2，沿用原 MAC，開機 | RTO 與 Day 16 完整還原的 569 秒比較。副本是 crash-consistent，客體要能 fsck 過。canary 的還原點應是 04:00 同步前那一份快照的時間 |

前置條件

- `Drill` 共享資料夾在主 NAS 建好，NFS 匯出給演練用的節點，canary 在該節點以 `share-canary.sh install /mnt/drill/canary` 裝好，跑滿一小時再開始
- `Drill` 有快照排程（每小時），且已進 HBS 3 的同步工作，至少跑過一次完整同步
- 演練 4 的 VM 要有靜態 IP 或 DHCP 保留（Day 16 演練 1 的教訓），原 VM 必須先停機
- 演練 3 的反向同步工作做完要停用或刪除，不能留一個會把次要 NAS 蓋回主 NAS 的工作

演練後檢查與清理

- 演練 3 的反向工作已刪除，HBS 3 只剩主到次要的一個工作
- 演練 4 的新 VM 已刪除，PVE 上加的次要 NAS 儲存已移除或標為停用，避免 HA 或排程備份看到兩份同名磁碟
- `Drill` 資料夾在演練期結束後刪除，或保留作為每季演練的固定對象（保留就要進 HBS 3 的排除清單，避免 20 GB 隨機檔每天被檢查）
- 演練期間主 NAS 的快照佔用回到基線
