# The NodesInfoCache singleton refreshes the node-info snapshot on a 5s timer.
# Tests that seed/wipe the snapshot and assert on it would RACE that tick over
# a full suite run (a background refresh landing between the seed and the
# assertion overwrites the marker). Make the periodic tick effectively inert
# for the suite: tests that need a refresh trigger one explicitly through
# NebulaAPI.APIServer.refresh_nodes_cache/0.
Application.put_env(:nebula_api, :nodes_info_refresh_interval, 3_600_000)

# The cache read its interval at init (the app booted before this file ran):
# bounce it so the setting takes effect.
:ok = Supervisor.terminate_child(NebulaAPI.APIServer, NebulaAPI.APIServer.NodesInfoCache)
{:ok, _} = Supervisor.restart_child(NebulaAPI.APIServer, NebulaAPI.APIServer.NodesInfoCache)

ExUnit.start()
