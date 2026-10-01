# NAS 備份原則（快照、HBS 3 與 3-2-1）

適用版本：主 NAS 與次要 NAS 皆為 QuTS hero h6.0.2.3591，HBS 3 26.4.4.788。版本更新後，本表逐項重驗。

## 盤點：實施前的狀態（2026-10-01）

盤點由 `nas-audit.sh` 產生，摘要如下。

| 項目 | 主 NAS | 次要 NAS（TS-464） |
|---|---|---|
| 儲存池 | zpool1 22.6 TB，已用 26%（4.8 TB） | zpool1 432 GB 單顆筆電碟無備援，zpool2 562 GB 兩碟 mirror，各用 1% |
| 快照排程 | 無。`/etc/config/qsnapshot/zsnapshotJob.conf` 0 位元組 | 無 |
| 現有快照 | 只有 7 個 `:init:`，Public 的 `zfs_snapshot_maxid` 為 7，表示手動建過又刪了 | 只有 `:init:` |
| 快照保留空間 | 池層級 5%，實際保留 0 位元組 | 未設定 |
| HBS 3 | 已裝。兩個工作都手動、未加密、目的地已離線，一個從未執行，一個 2026-04-16 失敗後沒再跑 | 未安裝 |
| 快照複本工作 | 無 | 無 |
| rsync 伺服器 | 開著（Public、Container、homes、JustBackup、HDP_Business），沒有工作在用 | 未確認 |

結論：主 NAS 上沒有任何一份資料有第二份副本，也沒有任何可回溯的時間點。Day 16 的 HDP 儲存庫、Day 13 的模型庫、Day 2 到 8 的容器卷、PVE 的 VM 磁碟，全部只有一份，全部在同一個儲存池。

## 分級：備什麼、怎麼備

次要 NAS 只有約 0.9 TB，放不下主 NAS 的 4.8 TB，所以先分級。判準只有兩個：這份資料是不是唯一副本，以及丟了要花多久重建。

| 共享資料夾或子目錄 | 大小 | 唯一副本 | 快照（主） | 複製到次要 NAS | 依據 |
|---|---|---|---|---|---|
| Container | 22.5 GB | 是 | 每小時保 24 份，每日保 7 份 | 是，zpool2 | Day 2 到 8 的服務狀態，重建要重跑每個服務的初始化 |
| HDP_Business | 262 GB | 是 | 每日保 7 份 | 是，zpool2 | Day 16 的 VM 備份庫，本機不可變只鎖新 pack，儲存庫的 `config` 與 `keys/` 仍可寫 |
| Public/images | 99 GiB | 否（HDP 有版本） | 隨 Public 每日保 7 份 | 是，zpool2 | PVE 的 VM 磁碟。副本是一份可直接掛載的 qcow2，用來做演練 4 的副本開機，RTO 比 HDP 完整還原短 |
| homes | 22 MB | 是 | 每日保 7 份 | 是，zpool2 | 小，順手 |
| Public/Wordpress、Public/Music | 10 GiB、4.7 GiB | 是 | 隨 Public | 是，zpool2 | Music 是 Day 18 外移雲端的對象，先有本地第二份 |
| JustBackup | 258 GB | 否（vzdump 第二套） | 每日保 3 份 | 是，zpool1 單碟 | 放單碟池是刻意的，這一份丟了還有 HDP_Business |
| Public/AIModels、Public/models、Public/comfyui | 2.29 TiB、476 GiB、104 GiB | 否，可從上游重下載 | 隨 Public（幾乎不變，快照成本接近零） | 否 | 放不下。重下載的時間成本在 Day 18 一併算 |
| Public/hdptest-convert | 10.5 GiB | 否 | 隨 Public | 否 | Day 16 實測殘留，清掉 |
| Container Station 兩個 zvol | 32.7 GB、5.3 GB | 系統卷 | 每日保 7 份 | 否 | zvol 不能用 RTRR，可走快照複本，待查 |

次要 NAS 的容量分配：zpool2（mirror）收 Container、HDP_Business、images、homes、Wordpress、Music，合計約 407 GB，佔 562 GB 的 72%，剩下的給次要 NAS 自己的快照。zpool1（單碟）只收 JustBackup 258 GB，佔 60%。HDP_Business 會隨 30 天版本成長，每月看一次 `nas-audit.sh` 的池使用率，超過 85% 先砍 JustBackup 的副本。

## 快照

| 項目 | 主 NAS | 次要 NAS | 依據 |
|---|---|---|---|
| 排程 | Container 每小時整點，其餘每日 00:30 | 每日 05:00（同步完成後） | 主 NAS 避開 01:00 快取釋放、02:00 qfstrim、03:00 惡意程式掃描與 vs_refresh，以及 01:30 的 HDP 工作。次要 NAS 的快照要在同步之後，才是同步完成的版本 |
| 保留 | Container 24 份小時快照加 7 份日快照，Public 與 HDP_Business 7 份，JustBackup 3 份 | 每個副本資料集 14 份 | 次要 NAS 保得比主 NAS 久，因為它在勒索或誤刪之後才是能回頭的那一份 |
| 快照保留空間 | 池層級 5%（約 1.1 TB），維持 | zpool2 設 10% | Public 的日變動主要來自 VM 磁碟，7 天在 1.1 TB 之內。實際佔用以 `nas-audit.sh` 的「快照佔用」欄為準 |
| 快照目錄 | snapdir visible，`@Recently-Snapshot` 可從 NFS 與 SMB 直接讀 | 同左 | 演練 1 直接從快照目錄取檔，不經 UI |

快照防的是誤刪、客體端勒索與錯誤變更，不防儲存池損毀。主 NAS 只有一個儲存池，快照與正本同生共死，所以快照不計入 3-2-1 的任何一個數字。

## HBS 3 到次要 NAS

| 項目 | 值 | 依據 |
|---|---|---|
| 工作類型 | RTRR 單向同步（主到次要） | 副本是可直接掛載的檔案，演練 4 才做得到。QuDedup 的 .qdff 要靠 HBS 才能還原，舊工作也是在這種類型上失敗的 |
| 目的地 | 次要 NAS 的 RTRR 伺服器（HBS 3 提供），每個來源一個專用資料夾 | 次要 NAS 要先裝 HBS 3 並開 RTRR 伺服器 |
| 來源網卡 | 自動，每次看工作紀錄確認 | 主 NAS 有一張 10GbE 與一張 2.5GbE 在同一網段。HBS 3 會在工作紀錄寫下它自動選的虛擬交換器，要對到 10GbE 那一張 |
| 排程 | 每日 04:00 | 01:30 的 HDP 工作跑完後，副本才包含當天的 HDP 版本 |
| 備份前先建快照 | 開 | 同步的是快照裡的一致版本，VM 磁碟的副本才是 crash-consistent |
| 刪除多餘檔案 | 開 | 副本是鏡像。版本由次要 NAS 的快照提供，不由 HBS 提供 |
| 加密 | 關 | 同一個 VLAN 內，10GbE 上開 RTRR 加密會吃掉 TS-464 的 CPU，待實測 |
| 完整性檢查 | 每週日執行後完整檢查 | 舊工作只開快速檢查，形同沒檢查 |
| 版本 | 由次要 NAS 的每日快照提供，14 份 | 同步不帶版本，勒索軟體改壞的檔案會在 04:00 被同步過去，回頭要靠 05:00 之前的那一份快照 |

替代方案與不採用的理由。快照複本（Snapshot Replica）是區塊層級、帶快照的 hero 對 hero 複製，效率最好，但以資料集為單位。Public 是一個 3.3 TB 的資料集，次要 NAS 放不下，而要保護的 images 只是它的子目錄。Container、HDP_Business、JustBackup 三個整資料集其實適合走快照複本，留作下一輪的變更。

## 3-2-1 對照

| 數字 | 要求 | 這個場域 | 狀態 |
|---|---|---|---|
| 3 | 三份副本 | 正本、次要 NAS 副本、Day 18 的雲端副本 | 本日達成兩份 |
| 2 | 兩種媒體 | 兩台 NAS 都是 HDD。算兩台獨立設備、兩個獨立儲存池、獨立的電源與控制器，不算嚴格意義的兩種媒體 | 誠實標為部分達成 |
| 1 | 一份異地 | Day 18 | 未達成 |
| 額外的 1 | 一份離線或不可變 | Day 16 的 HDP 本機不可變只鎖新 pack，Day 18 的 Object Lock 才算 | 未達成 |
| 0 | 零還原錯誤 | 本日演練與 `drill-log.md` | 以演練結果為準 |

## 實測到的邊界（本場域，待演練後填）

- 主 NAS 到次要 NAS 的 RTRR 首次同步速率：待測
- RTRR 對一個每天都變的 qcow2 是整檔重傳還是差異傳輸：待查
- 快照回復（revert）一個 20 GB 的資料集要幾秒，以及回復期間 NFS 用戶端看到什麼：待測
- 從次要 NAS 還原 20 GB 回主 NAS 的速率，據此推算 HDP_Business 262 GB 的還原時間：待測
- PVE 直接從次要 NAS 的 qcow2 副本開機一台 VM 的 RTO，與 Day 16 完整還原的 569 秒比較：待測
- 次要 NAS zpool1 單碟的 SMART 狀態，以及它一旦故障 JustBackup 副本消失的影響：待確認
