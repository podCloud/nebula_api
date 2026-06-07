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

  Returns `:ok`, or `{:error, local_modules}` — the list of modules with local methods
  on this node — when at least one such module exists but none of the app's modules
  wired a server via `nebula_api_server/0` (so those methods' RPC workers would never
  start). The caller formats the human message; this stays pure decision logic.
  """
  def verify(modules_attrs) do
    local_modules =
      for {module, attrs} <- modules_attrs, local_methods?(attrs), do: module

    if local_modules != [] and not Enum.any?(modules_attrs, fn {_m, attrs} -> wired?(attrs) end) do
      {:error, local_modules}
    else
      :ok
    end
  end

  defp local_methods?(attrs) do
    attrs |> Keyword.get_values(:nebula_local_api_methods) |> List.flatten() != []
  end

  defp wired?(attrs) do
    attrs |> Keyword.get_values(:nebula_api_server_wired) |> List.flatten() |> Enum.any?()
  end
end
