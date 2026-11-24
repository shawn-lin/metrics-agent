# 從節點系統指標

在 Linux 從節點採集系統指標，並推送到主節點 API。

## 需求

- bash
- `/proc` 與 `df`
- 查詢 IP 時需要系統已安裝的 `ip`（iproute2）；沒有則 `ip` 欄位為空字串
- 推送時需要 `curl`、`flock` 與 `sha256sum`

## 採集

`metrics.sh` 約 1 秒後在 stdout 印出一行 JSON。CPU 與網路流量會取樣兩次。

```bash
bash metrics.sh
```

```json
{"cpu_percent":1.20,"memory_percent":40.00,"disk_percent":32.00,"upload_mbps":0.15,"download_mbps":1.20,"ip":"192.168.1.10","os":"Ubuntu 24.04.1 LTS"}
```

| 欄位 | 說明 |
| --- | --- |
| `cpu_percent` | CPU 使用率，0–100 |
| `memory_percent` | 記憶體使用率，0–100 |
| `disk_percent` | 根目錄 `/` 使用率，0–100 |
| `upload_mbps` | 預設路由網卡上傳速率，單位 Mbps |
| `download_mbps` | 預設路由網卡下載速率，單位 Mbps |
| `ip` | 該網卡的 global IPv4；沒有則改用 global IPv6 |
| `os` | `/etc/os-release` 的 `PRETTY_NAME` |

沒有預設路由時，流量改為加總除 `lo` 以外的網卡。讀不到 `/proc` 或 `df` 時，錯誤寫到 stderr，結束碼非 0。

## 推送

`agent.sh` 持續執行同目錄的 `metrics.sh`，再以 POST 把 JSON 送到主節點。啟動後立刻回報一次，然後等待指定秒數再重複。等待時間不含採集本身約 1 秒。

```bash
bash agent.sh <api_url> <access_token> <interval_seconds>
```

- `interval_seconds`：兩次回報之間的等待秒數，非負整數
- `Content-Type: application/json`
- `Authorization: Bearer <access_token>`
- 逾時 30 秒
- 成功時把 API 回應印到 stdout，並換行
- 日誌統一追加寫入腳本目錄的 `agent.log`
- 每一行格式為 `[時間][api_url][access_token] <請求 JSON> <伺服器回應>`
- 單次採集或 HTTP 失敗只寫到 stderr，進程繼續
- 參數不正確、缺少 `curl`、`flock` 或 `metrics.sh` 時，結束碼為 1
- 同一組 `api_url` 與 `access_token` 不能同時跑兩個進程；第二個會立刻失敗
