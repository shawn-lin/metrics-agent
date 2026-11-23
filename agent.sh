#!/usr/bin/env bash
# 執行同目錄的 metrics.sh，並以 Bearer token 把 JSON POST 到指定 API。
# 用法：bash agent.sh <api_url> <access_token>
set -euo pipefail

die() {
  printf 'agent.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '用法：bash agent.sh <api_url> <access_token>\n' >&2
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

api_url=$1
access_token=$2

[[ -n $api_url ]] || die "api_url 不可為空"
[[ -n $access_token ]] || die "access_token 不可為空"
command -v curl >/dev/null 2>&1 || die "找不到 curl"

script_dir=$(cd "$(dirname "$0")" && pwd)
metrics_sh=$script_dir/metrics.sh
[[ -f $metrics_sh ]] || die "找不到 $metrics_sh"

payload=$(bash "$metrics_sh")
[[ -n $payload ]] || die "metrics.sh 沒有輸出"

curl --fail --silent --show-error --max-time 30 \
  --request POST \
  --header "Authorization: Bearer ${access_token}" \
  --header "Content-Type: application/json" \
  --data-binary "$payload" \
  "$api_url"
