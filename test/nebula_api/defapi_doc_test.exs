defmodule NebulaAPI.DefapiDocTest do
  @moduledoc """
  A user `@doc` written above a `defapi` documents the *public* API, so it must land on
  the public router function — not on the generated private `__nbapi_local_*` /
  `__nbapi_remote_*` helpers (where Elixir discards it with a warning).
  """
  use ExUnit.Case

  import ExUnit.CaptureIO

  setup do
    prev = Application.get_env(:nebula_api, :nodes)
    Application.put_env(:nebula_api, :nodes, [{:"probe@127.0.0.1", [:db]}])

    on_exit(fn ->
      if prev,
        do: Application.put_env(:nebula_api, :nodes, prev),
        else: Application.delete_env(:nebula_api, :nodes)
    end)

    :ok
  end

  defp src(name) do
    """
    defmodule #{name} do
      use NebulaAPI, self_node: :"probe@127.0.0.1"

      @doc "Reads x from the db."
      defapi &db, read(x), do: x
    end
    """
  end

  test "a defapi's @doc lands on the public router, no 'discarded' warning" do
    name = "DefapiDocTest.DocOnPublic"

    docs_was = Code.get_compiler_option(:docs)
    Code.put_compiler_option(:docs, true)
    on_exit(fn -> Code.put_compiler_option(:docs, docs_was) end)

    {[{mod, bin}], stderr} = with_io(:stderr, fn -> Code.compile_string(src(name)) end)

    refute stderr =~ "is always discarded",
           "user @doc on a defapi must not fall on a private __nbapi_* helper"

    # fetch_docs needs a .beam on disk: a Code.compile_string module has no object code.
    path = Path.join(System.tmp_dir!(), "#{mod}.beam")
    File.write!(path, bin)
    on_exit(fn -> File.rm(path) end)
    {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(path)

    doc_entry =
      Enum.find(docs, fn
        {{:function, :read, _arity}, _, _, %{"en" => _}, _} -> true
        _ -> false
      end)

    assert doc_entry, "expected the public read/_ function to carry the doc"
    {{:function, :read, _}, _, _, %{"en" => doc}, _} = doc_entry
    assert doc == "Reads x from the db."
  end
end
