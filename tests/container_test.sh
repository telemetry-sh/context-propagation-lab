#!/bin/sh
set -eu

image=${1:-context-propagation-lab:test}
container_id=$(docker run -d -p 127.0.0.1::8080 "$image")

cleanup() {
  docker rm -f "$container_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

port=$(docker port "$container_id" 8080/tcp | sed 's/.*://')
attempt=0
while [ "$attempt" -lt 60 ]; do
  if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 0.25
done

test "$(curl -fsS "http://127.0.0.1:$port/healthz")" = "ok"
curl -fsS "http://127.0.0.1:$port/api/simulate" |
  jq -e '.strategies[3].policy == "zone_plus_envelope"' >/dev/null

test "$(docker inspect -f '{{.Config.User}}' "$container_id")" = "lab"

attempt=0
health=
while [ "$attempt" -lt 60 ]; do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$container_id")
  if [ "$health" = "healthy" ]; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 0.25
done
test "$health" = "healthy"

printf '%s\n' "ContainerTest: image, non-root runtime, healthcheck, and API passed"
