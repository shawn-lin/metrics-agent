#!/usr/bin/env bash
# 持續執行同目錄的 metrics.sh，並以 Bearer token 把 JSON POST 到指定 API。
# 用法：bash agent.sh <api_url> <access_token> <interval_seconds>
set -euo pipefail

die() {
  printf 'agent.sh: %s\n' "$*" >&2
  if [[ -n ${log_file:-} && -n ${access_token:-} ]]; then
    log_record "" "agent.sh: $*" || true
  fi
  exit 1
}

# [time][url][access_token] <request> <response>
log_record() {
  local request=${1//$'\n'/ }
  local response=${2//$'\n'/ }
  printf '[%s][%s][%s] %s %s\n' "$(date -Iseconds)" "$api_url" "$access_token" "$request" "$response" >> "$log_file"
}

usage() {
  printf '用法：bash agent.sh <api_url> <access_token> <interval_seconds>\n' >&2
}

if [[ $# -ne 3 ]]; then
  usage
  exit 1
fi

api_url=$1
access_token=$2
interval=$3

[[ -n $api_url ]] || die "api_url 不可為空"
[[ -n $access_token ]] || die "access_token 不可為空"
[[ $interval =~ ^[0-9]+$ ]] || die "等待秒數必須是非負整數"
command -v curl >/dev/null 2>&1 || die "找不到 curl"
command -v flock >/dev/null 2>&1 || die "找不到 flock"
command -v sha256sum >/dev/null 2>&1 || die "找不到 sha256sum"
command -v mktemp >/dev/null 2>&1 || die "找不到 mktemp"

script_dir=$(cd "$(dirname "$0")" && pwd)
metrics_sh=$script_dir/metrics.sh
log_file=$script_dir/agent.log
[[ -f $metrics_sh ]] || die "找不到 $metrics_sh"
touch "$log_file" || die "無法寫入 $log_file"

lock_key=$(printf '%s\0%s' "$api_url" "$access_token" | sha256sum)
lock_key=${lock_key%% *}
lock_file=/tmp/metrics-agent-${lock_key}.lock
exec 9>"$lock_file"
if ! flock -n 9; then
  die "已有相同 api_url 與 access_token 的 agent 在執行"
fi

report_once() {
  local payload status=0 metrics_err response curl_err
  local metrics_err_file curl_err_file
  metrics_err_file=$(exec 9>&-; mktemp)
  payload=$(exec 9>&-; bash "$metrics_sh" 2>"$metrics_err_file") || status=$?
  metrics_err=$(cat "$metrics_err_file" 2>/dev/null || true)
  rm -f "$metrics_err_file"
  if [[ -n $metrics_err ]]; then
    printf '%s\n' "$metrics_err" >&2
  fi
  if (( status != 0 )) || [[ -z $payload ]]; then
    printf 'agent.sh: 本次回報失敗\n' >&2
    log_record "" "${metrics_err:-agent.sh: 本次回報失敗}"
    return 0
  fi
  curl_err_file=$(exec 9>&-; mktemp)
  response=$(exec 9>&-; curl --fail --silent --show-error --max-time 30 \
    --request POST \
    --header "Authorization: Bearer ${access_token}" \
    --header "Content-Type: application/json" \
    --data-binary "$payload" \
    "$api_url" 2>"$curl_err_file") || status=$?
  curl_err=$(cat "$curl_err_file" 2>/dev/null || true)
  rm -f "$curl_err_file"
  if [[ -n $curl_err ]]; then
    printf '%s\n' "$curl_err" >&2
  fi
  if (( status != 0 )); then
    printf 'agent.sh: 本次回報失敗\n' >&2
    log_record "$payload" "${curl_err:-agent.sh: 本次回報失敗}"
    return 0
  fi
  printf '%s\n' "$response"
  log_record "$payload" "$response"
}

while true; do
  report_once
  sleep "$interval" 9>&-
done
