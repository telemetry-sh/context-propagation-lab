#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
log_file=$(mktemp)
body_file=$(mktemp)
header_file=$(mktemp)
server_pid=

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$log_file" "$body_file" "$header_file"
}
trap cleanup EXIT INT TERM

cd "$project_dir"
HOST=127.0.0.1 PORT=0 dart run bin/server.dart >"$log_file" 2>&1 &
server_pid=$!

attempt=0
base_url=
while [ "$attempt" -lt 100 ]; do
  base_url=$(sed -n 's/.*"url":"\([^"]*\)".*/\1/p' "$log_file" | head -n 1)
  if [ -n "$base_url" ]; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$log_file"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.05
done

test -n "$base_url"
test "$(curl -fsS "$base_url/healthz")" = "ok"
curl -fsS "$base_url/" >"$body_file"
grep -q "The request succeeded" "$body_file"
grep -q "TRACE LEDGER" "$body_file"
curl -fsS "$base_url/styles.css" | grep -q -- "--violet"
curl -fsS "$base_url/app.js" | grep -q "renderStageChart"

curl -fsS \
  "$base_url/api/simulate?requests=1&async_hops=99&failure_percent=99" \
  >"$body_file"
jq -e '.config.requests == 100' "$body_file" >/dev/null
jq -e '.config.asyncHops == 12' "$body_file" >/dev/null
jq -e '.config.failurePercent == 80' "$body_file" >/dev/null
jq -e '.strategies | length == 4' "$body_file" >/dev/null
jq -e '.strategies[0].metrics.completeTracesPercent == 0' "$body_file" >/dev/null
jq -e '.strategies[3].metrics.completeTracesPercent == 100' "$body_file" >/dev/null

status=$(curl -sS -o "$body_file" -w '%{http_code}' "$base_url/missing")
test "$status" = "404"
jq -e '.error == "not found"' "$body_file" >/dev/null

status=$(curl -sS -X POST -o "$body_file" -w '%{http_code}' "$base_url/api/simulate")
test "$status" = "405"
jq -e '.error == "method not allowed"' "$body_file" >/dev/null

curl -fsS -D "$header_file" -o /dev/null "$base_url/"
grep -qi '^content-security-policy:' "$header_file"
grep -qi '^x-content-type-options: nosniff' "$header_file"
grep -qi '^x-frame-options: DENY' "$header_file"

if HOST=example.com PORT=0 dart run bin/server.dart >"$body_file" 2>&1; then
  echo "invalid HOST unexpectedly succeeded" >&2
  exit 1
fi
grep -q "HOST must be" "$body_file"

printf '%s\n' "ServerTest: routes, clamps, assets, methods, headers, and environment validation passed"
