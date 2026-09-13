defmodule NebulaAPI.APIServer.NodesCacheOwner do
  @moduledoc """
  Owns the `:nebula_nodes_cache` ETS table — and does nothing else.

  The table is `:protected`, so only its owner process can write; every write
  in the library funnels through this process (`insert/1`, `delete/1`). Keeping
  the OWNER separate from the REFRESHER (`NebulaAPI.APIServer.NodesInfoCache`)
  decouples the cached data's lifetime from the refresh logic: the refresher
  can crash and be restarted without destroying the cache — `last_seen_at`
  history for currently-unreachable nodes is not reconstructible, so the table
  must not die with the process most likely to have bugs. This process is
  deliberately too dumb to crash: create the table, serve two write calls,
  ignore everything else.
  """

  use GenServer

  require Logger

  @table :nebula_nodes_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  # Write one `{key, value}` entry through the owner. Callable from any
  # process; without a running owner (bare test contexts, app not booted) it
  # is the same silent no-op as writing to a missing table used to be.
  # Returns :ok, or {:error, exception} if `entry` isn't a valid ETS object
  # for this table (e.g. not a tuple) -- the owner survives either way.
  def insert(entry) do
    GenServer.call(__MODULE__, {:insert, entry})
  catch
    :exit, _ -> :ok
  end

  @doc false
  # Drop one key through the owner. Same no-owner semantics as insert/1.
  def delete(key) do
    GenServer.call(__MODULE__, {:delete, key})
  catch
    :exit, _ -> :ok
  end

  @doc false
  # Fire-and-forget insert, for a caller that neither needs nor should wait on
  # a reply -- build_nodes_info/0 writes one best-effort entry per configured
  # node, and a synchronous call there means one slow/unresponsive owner can
  # stall the whole refresh by up to (node count) * (the call's timeout).
  # A cast never blocks, whether or not the owner is running.
  def insert_async(entry) do
    GenServer.cast(__MODULE__, {:insert, entry})
    :ok
  end

  @impl true
  def init(_opts) do
    # The rescue covers an exotic restart race (name freed, table not yet
    # destroyed) — and bare contexts where something else made the table.
    try do
      :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    rescue
      ArgumentError -> :ok
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:insert, entry}, _from, state) do
    {:reply, do_insert(entry), state}
  end

  @impl true
  def handle_call({:delete, key}, _from, state) do
    {:reply, do_delete(key), state}
  end

  # Registered under a public, predictable name: stray messages happen, and a
  # crash here destroys the table — the exact blast radius this process exists
  # to prevent. Same hardening as Worker / NodesInfoCache.
  @impl true
  def handle_call(other, _from, state) do
    {:reply, {:nebula_error, {:unexpected_message, other}}, state}
  end

  @impl true
  def handle_cast({:insert, entry}, state) do
    do_insert(entry)
    {:noreply, state}
  end

  @impl true
  def handle_cast(other, state) do
    Logger.warning("NodesCacheOwner ignored unexpected cast: #{inspect(other)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(other, state) do
    Logger.warning("NodesCacheOwner ignored unexpected message: #{inspect(other)}")
    {:noreply, state}
  end

  # entry/key are caller-supplied (insert/1, insert_async/1, delete/1 are all
  # callable from any process) -- :ets.insert/2 raises ArgumentError for
  # anything that isn't a tuple with at least @table's keypos elements. This
  # process owns a :protected table with no :heir, so letting that propagate
  # would crash US, and ETS destroys an owner-less table the instant its
  # owner dies -- taking every other node's cached data down with one bad
  # write.
  defp do_insert(entry) do
    :ets.insert(@table, entry)
    :ok
  rescue
    e -> {:error, e}
  end

  # :ets.delete/2 doesn't actually reject malformed keys the way insert
  # rejects malformed values (any term is a valid key) -- guarded anyway, for
  # the same reason the module exists: this process must not crash.
  defp do_delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    e -> {:error, e}
  end
end
