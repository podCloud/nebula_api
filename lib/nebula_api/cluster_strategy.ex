defmodule NebulaAPI.ClusterStrategy do
  @moduledoc """
  Assumes you have nodes that respond to the specified DNS query (A record), and which follow the node name pattern of
  `foo@bar.host.test`. If your setup matches those assumptions, this strategy will periodically poll DNS to check if the host
  exists and connect all nodes it finds using the original name provided.

  ## Options

  * `interval` - How often to poll in milliseconds (optional; default: 5_000)
  * `nodes` - Nodes names, DNS query will use the hostname (required; e.g. "app@my-app.example.com", will poll "my-app.example.com")

  ## Usage

  ```elixir
      config :libcluster,
        topologies: [
          nebula: [
            strategy: #{__MODULE__},
            config: [
              interval: 5_000,
              nodes: ["app1@my-app.example.com", "app2@my-app.example.com"]
            ]
          ]
        ]
  ```
  """

  use GenServer
  use Cluster.Strategy

  import Cluster.Logger

  alias Cluster.Strategy
  alias Cluster.Strategy.State

  @default_polling_interval 5_000

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init([%State{meta: nil} = state]) do
    init([%State{state | :meta => MapSet.new()}])
  end

  def init([%State{} = state]) do
    {:ok, do_poll(state)}
  end

  @impl true
  def handle_info(:timeout, state), do: handle_info(:poll, state)
  def handle_info(:poll, state), do: {:noreply, do_poll(state)}
  def handle_info(_, state), do: {:noreply, state}

  defp do_poll(
         %State{
           topology: topology,
           connect: connect,
           disconnect: disconnect,
           list_nodes: list_nodes
         } = state
       ) do
    debug(topology, "Polling DNS for nodes")
    debug(topology, "Current nodelist: #{inspect(state.meta)}")
    debug(topology, "Topology: #{inspect(topology)}")

    new_nodelist = state |> get_nodes() |> MapSet.new()
    removed = MapSet.difference(state.meta, new_nodelist)

    new_nodelist =
      case Strategy.disconnect_nodes(
             topology,
             disconnect,
             list_nodes,
             MapSet.to_list(removed)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Add back the nodes which should have been removed, but which couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.put(acc, n)
          end)
      end

    new_nodelist =
      case Strategy.connect_nodes(
             topology,
             connect,
             list_nodes,
             MapSet.to_list(new_nodelist)
           ) do
        :ok ->
          new_nodelist

        {:error, bad_nodes} ->
          # Remove the nodes which should have been added, but couldn't be for some reason
          Enum.reduce(bad_nodes, new_nodelist, fn {n, _}, acc ->
            MapSet.delete(acc, n)
          end)
      end

    debug(topology, "New nodelist: #{inspect(new_nodelist)}")
    debug(topology, "Removed nodes: #{inspect(removed)}")

    debug(topology, "Waiting for next poll in #{polling_interval(state)}ms")
    Process.send_after(self(), :poll, polling_interval(state))

    %State{state | :meta => new_nodelist}
  end

  defp polling_interval(%State{config: config}) do
    Keyword.get(config, :interval, @default_polling_interval)
  end

  defp get_nodes(%State{config: config} = state) do
    query = Keyword.fetch(config, :nodes)

    resolver =
      Keyword.get(config, :resolver, fn query ->
        query
        |> String.split("@")
        |> List.last()
        |> String.to_charlist()
        |> lookup_all_ips
        |> Enum.any?()
        |> tap(&debug(state.topology, "Resolved query #{inspect(query)} to #{inspect(&1)}"))
      end)

    resolve(query, resolver, state)
  end

  # query for all ips responding to a given dns query
  # format ips as node names
  # filter out me
  defp resolve({:ok, nodes}, resolver, %State{topology: topology})
       when is_list(nodes) do
    nodes
    |> Enum.map(fn n -> "#{n}" end)
    |> Enum.reject(fn n -> "#{n}" == "#{node()}" end)
    |> Enum.filter(fn n -> resolver.(n) end)
    |> Enum.map(fn n -> :"#{n}" end)
    |> tap(&debug(topology, "Resolved nodes: #{inspect(&1)}"))
  end

  defp resolve(:error, _resolver, %State{topology: topology}) do
    warn(
      topology,
      "nebula cluster strategy is selected, but nodes param is missing or not a list"
    )

    []
  end

  def lookup_all_ips(q) do
    Enum.flat_map([:a, :aaaa], fn t ->
      :inet_res.lookup(q, :in, t)
    end)
  end
end
