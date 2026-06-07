#!/bin/sh
set -e

: "${RELEASE_NODE:?RELEASE_NODE must be set}"
: "${RELEASE_COOKIE:=demo-cookie}"

echo "demo-entrypoint: node=${RELEASE_NODE} release_name=${RELEASE_NAME}"

# Deps are fetched ONCE via the setup step (docker compose run --rm db mix deps.get),
# not per container — avoids concurrent deps.get races on the shared deps/mix.lock.

# If a command was passed (e.g. `mix test`), run it with the node name; else run the app.
if [ "$#" -gt 0 ]; then
  exec elixir --name "${RELEASE_NODE}" --cookie "${RELEASE_COOKIE}" -S "$@"
else
  exec elixir --name "${RELEASE_NODE}" --cookie "${RELEASE_COOKIE}" -S mix run --no-halt
fi
