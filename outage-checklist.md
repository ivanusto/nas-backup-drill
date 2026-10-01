# 主 NAS 停機演練檢查清單

演練 4 不需要停主 NAS。這份清單是給「主 NAS 真的停下來」的那一次用的，需另約時段。每一項打勾並記時間，整份清單就是演練紀錄。

## 停機前

- [ ] 時段已確認並通知。記下 `zpool list`、`/etc/exports`、Virtualization Station 內的 VM 清單（`nas-audit.sh` 的輸出即可）
- [ ] PVE：`ha-manager status` 存檔。放在 NFS 上的 VM 正常關機或設為 stopped，避免 I/O 卡住觸發 fence
- [ ] QDevice 在主 NAS 的 Virtualization Station 上。停機期間叢集只剩兩票，任何一台節點再掉就失去法定人數。停機期間不動 PVE 節點
- [ ] 推論節點的 LLM 後端與 API 入口：確認沒有長任務，必要時先停。其他 GPU 節點確認沒有在讀模型庫
- [ ] Virtualization Station 內的 VM 先在 VS 關機。Day 15 實測系統重開時只會把 VM 暫停，並沒有關機，開機後時鐘會落後
- [ ] HBS 3 的同步工作與快照排程在停機時段內沒有觸發點，有的話先暫停
- [ ] 記下停機指令送出的時間（T0）

## 開機後

- [ ] `zpool status` 全部 ONLINE，沒有 resilver
- [ ] NFS 匯出恢復，`/etc/exports` 與停機前一致
- [ ] Virtualization Station 的 VM 冷開機。QDevice VM 的 qnetd 上線，`pvecm status` 回到三票
- [ ] PVE 端 `pvesm status` 三個 NFS 儲存 active，HA 資源恢復
- [ ] 推論節點的 API 健康檢查正常，模型庫可讀
- [ ] 在每個有 canary 的共享資料夾跑 `share-canary.sh verify`，心跳的斷層長度就是這個資料夾的實際停機時間
- [ ] HBS 3 與快照排程恢復，下一次觸發時間正確
- [ ] 記時：停機、開機、各服務恢復的時間點，整理成一列進 `drill-log.md`
