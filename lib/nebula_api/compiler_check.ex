defmodule NebulaAPI.CompilerCheck do
  @moduledoc """
  Pure decision logic for the `:nebula` Mix compiler (`Mix.Tasks.Compile.Nebula`).

  Kept separate from the compiler so it can be unit-tested without touching Mix or
  `.beam` files: it works on already-extracted module attributes.
  """

  @doc """
  Verifies an app's modules. `modules_attrs` is a list of `{module, attributes}` where
  `attributes` is the persisted attribute keyword list (as returned by
  `module.__info__(:attributes)` or the `:attributes` beam chunk).

  Returns one of:

    * `{:error, local_modules}` — modules with local methods on this build exist, but no module
      wired a server via `nebula_api_server/0` (those RPC workers would never start).
    * `{:warn, :server_without_methods}` — a server is wired but the app defines **no** `defapi`
      methods at all, so it can never serve anything (likely a leftover `nebula_api_server()`).
      Node-independent: an app whose methods are all *remote* on this build still has `defapi`,
      so it does NOT warn.
    * `:ok` — otherwise.

  The caller formats the human message; this stays pure decision logic.
  """
  def verify(modules_attrs) do
    local_modules =
      for {module, attrs} <- modules_attrs, local_methods?(attrs), do: module

    server_wired = Enum.any?(modules_attrs, fn {_m, attrs} -> wired?(attrs) end)
    has_defapi = Enum.any?(modules_attrs, fn {_m, attrs} -> defapi?(attrs) end)

    cond do
      local_modules != [] and not server_wired -> {:error, local_modules}
      server_wired and not has_defapi -> {:warn, :server_without_methods}
      true -> :ok
    end
  end

  # Does the module define any defapi method at all (on any node)? The single source,
  # :nebula_configured_nodes, carries an entry per defapi regardless of where it's local.
  defp defapi?(attrs) do
    attrs |> Keyword.get_values(:nebula_configured_nodes) |> List.flatten() != []
  end

  # Local on this build = the compiled node (self_node, baked into the :nebula_api opts)
  # is in a method's configured serving set. Derived from the single source
  # (:nebula_configured_nodes); stays pure (no node()) — reads only the given attrs.
  defp local_methods?(attrs) do
    self_node = self_node(attrs)

    attrs
    |> Keyword.get_values(:nebula_configured_nodes)
    |> List.flatten()
    |> Enum.any?(fn {_method, nodes} -> self_node in nodes end)
  end

  defp self_node(attrs) do
    attrs
    |> Keyword.get_values(:nebula_api)
    |> List.flatten()
    |> Keyword.get(:self_node)
  end

  defp wired?(attrs) do
    attrs |> Keyword.get_values(:nebula_api_server_wired) |> List.flatten() |> Enum.any?()
  end
end
