# 從節點系統指標

在 Linux 從節點採集系統指標，並推送到主節點 API。

## 需求

- bash
- `/proc` 與 `df`
- 查詢 IP 時需要系統已安裝的 `ip`（iproute2）；沒有則 `ip` 欄位為空字串
- 推送時需要 `curl`

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

`agent.sh` 執行同目錄的 `metrics.sh`，再以 POST 把 JSON 送到主節點。

```bash
bash agent.sh <api_url> <access_token>
```

- `Content-Type: application/json`
- `Authorization: Bearer <access_token>`
- 逾時 30 秒
- 成功時把 API 回應印到 stdout
- 參數缺少、`metrics.sh` 失敗，或 HTTP 非 2xx 時，結束碼非 0
