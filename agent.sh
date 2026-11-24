#!/usr/bin/env bash
# 持續執行同目錄的 metrics.sh，並以 Bearer token 把 JSON POST 到指定 API。
# 用法：bash agent.sh <api_url> <access_token> <interval_seconds>
set -euo pipefail

die() {
  printf 'agent.sh: %s\n' "$*" >&2
  exit 1
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

script_dir=$(cd "$(dirname "$0")" && pwd)
metrics_sh=$script_dir/metrics.sh
[[ -f $metrics_sh ]] || die "找不到 $metrics_sh"

lock_key=$(printf '%s\0%s' "$api_url" "$access_token" | sha256sum)
lock_key=${lock_key%% *}
lock_file=/tmp/metrics-agent-${lock_key}.lock
exec 9>"$lock_file"
if ! flock -n 9; then
  die "已有相同 api_url 與 access_token 的 agent 在執行"
fi

report_once() {
  local payload status=0
  payload=$(exec 9>&-; bash "$metrics_sh") || status=$?
  if (( status != 0 )) || [[ -z $payload ]]; then
    printf 'agent.sh: 本次回報失敗\n' >&2
    return 0
  fi
  local response
  response=$(exec 9>&-; curl --fail --silent --show-error --max-time 30 \
    --request POST \
    --header "Authorization: Bearer ${access_token}" \
    --header "Content-Type: application/json" \
    --data-binary "$payload" \
    "$api_url") || status=$?
  if (( status != 0 )); then
    printf 'agent.sh: 本次回報失敗\n' >&2
    return 0
  fi
  printf '%s\n' "$response"
}

while true; do
  report_once
  sleep "$interval" 9>&-
done
