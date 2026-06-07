#!/usr/bin/env bash
# Usage: ./console.sh <service>   e.g. ./console.sh worker2
set -e
svc="${1:?usage: ./console.sh <service: demo_app|worker1|worker2|worker3|db>}"
case "$svc" in
  worker?) node="worker@${svc}.test" ;;
  *)       node="${svc}@${svc}.test" ;;
esac
exec docker compose exec "$svc" \
  iex --name "console@${svc}.test" --cookie demo-cookie --remsh "${node}"
