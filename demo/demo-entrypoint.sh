#!/usr/bin/env bash
set -e

: "${RELEASE_NODE:?RELEASE_NODE must be set}"
: "${RELEASE_COOKIE:=demo-cookie}"

echo "demo-entrypoint: node=${RELEASE_NODE} release_name=${RELEASE_NAME}"

mix deps.get

# If a command was passed (e.g. `mix test`), run it with the node name; else run the app.
if [ "$#" -gt 0 ]; then
  exec elixir --name "${RELEASE_NODE}" --cookie "${RELEASE_COOKIE}" -S "$@"
else
  exec elixir --name "${RELEASE_NODE}" --cookie "${RELEASE_COOKIE}" -S mix run --no-halt
fi
