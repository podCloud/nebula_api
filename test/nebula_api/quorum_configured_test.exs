defmodule NebulaAPI.QuorumConfiguredTest do
  @moduledoc """
  End-to-end behaviour of `quorum: :configured` (the default): the quorum is a
  strict majority of the CONFIGURED nodes that serve the method and match the
  selector — connected or not — never just the live workers. The method's
  configured serving set is baked into its generated remote stub, so a `defapi`
  call always carries it; a direct `call_remote_method/3` with `:configured` and
  no set is a misuse and crashes (see the crash test).
  """
  use ExUnit.Case

  alias NebulaAPI.APIServer

  setup do
    prev = Application.get_env(:nebula_api, :nodes)

    # Three nodes, all :replica; we compile as probe@127.0.0.1 (the test VM's node).
    Application.put_env(:nebula_api, :nodes, [
      {:"probe@127.0.0.1", [:db, :replica]},
      {:db2@somewhere, [:db, :replica]},
      {:db3@somewhere, [:db, :replica]}
    ])

    on_exit(fn ->
      if prev,
        do: Application.put_env(:nebula_api, :nodes, prev),
        else: Application.delete_env(:nebula_api, :nodes)
    end)

    :ok
  end

  defp compile!(name, body) do
    src = """
    defmodule #{name} do
      use NebulaAPI, self_node: :"probe@127.0.0.1"
      #{body}
    end
    """

    [{mod, _bin}] = Code.compile_string(src)
    mod
  end

  test "default quorum (:configured) counts the method's configured serving set" do
    # write/1 is served by the 3 :replica nodes; none has a running worker here.
    # The default quorum is a majority of those 3 configured (= 2), not of the 0
    # present — so it refuses up front (one live node can't be a quorum of three).
    mod = compile!("QC_Default", "defapi &replica, write(x), do: {:ok, x}")

    assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}} =
             mod.write(:v, multicast: true, strategy: :quorum)
  end

  test "a static block selector counts its CONFIGURED matching set, not the present workers" do
    # call_on_nodes &replica wraps the call; &replica matches all 3 configured
    # nodes. The default quorum is a majority of those 3 (= 2), connected or not —
    # so with none present it refuses, never counting just the live workers.
    mod =
      compile!("QC_BlockSelector", """
      defapi &replica, write(x), do: {:ok, x}

      def run(x) do
        call_on_nodes &replica, strategy: :quorum do
          write(x)
        end
      end
      """)

    assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}} = mod.run(:v)
  end

  test "quorum: :configured with a function selector is a compile error" do
    # A runtime function picks its own set; there is no static configured set to
    # take a majority of. The macro refuses it at compile time (use :available).
    assert_raise CompileError, ~r/function selector/, fn ->
      compile!("QC_FnConfigured", """
      defapi &replica, write(x), do: {:ok, x}

      def run(x) do
        call_on_nodes fn _info -> [] end, strategy: :quorum, quorum: :configured do
          write(x)
        end
      end
      """)
    end
  end

  test "a function selector with strategy: :quorum needs an explicit quorum: :available or at_least:" do
    # No silent downgrade: a runtime function has no static configured set, so
    # the macro refuses :configured (the default) at compile time.
    assert_raise CompileError, ~r/quorum: :available, or at_least/, fn ->
      compile!("QC_FnDefault", """
      defapi &replica, write(x), do: {:ok, x}

      def run(x) do
        call_on_nodes fn _info -> [] end, strategy: :quorum do
          write(x)
        end
      end
      """)
    end
  end

  test "a function selector with at_least: compiles and counts (no injected quorum conflict)" do
    # I-3: at_least: is a valid escape; the macro must NOT inject quorum: :available
    # (which would collide with at_least: at runtime). fn returns [] → 0 present,
    # at_least 2 → required 2 > 0 → unreachable, no ArgumentError.
    mod =
      compile!("QC_FnAtLeast", """
      defapi &replica, write(x), do: {:ok, x}

      def run(x) do
        call_on_nodes fn _info -> [] end, strategy: :quorum, at_least: 2 do
          write(x)
        end
      end
      """)

    assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}} = mod.run(:v)
  end

  test "a caller can't shrink the quorum by passing __method_configured_nodes (builder uses put)" do
    # M-1: 3 configured replicas → required 2. A spoofed set must be ignored;
    # the generated stub's baked set always wins.
    mod = compile!("QC_NoSpoof", "defapi &replica, write(x), do: {:ok, x}")

    assert {:nebula_error, :quorum_unreachable, %{workers: 0, required: 2}} =
             mod.write(:v,
               multicast: true,
               strategy: :quorum,
               __method_configured_nodes: [:"probe@127.0.0.1"]
             )
  end

  test "a direct :configured call without the method's set is a misuse and raises loud" do
    # The configured set is injected by the generated stub. Reaching
    # call_remote_method/3 directly with :configured and no set means bypassing the
    # stub — a programming error, refused up front rather than silently falling back
    # to the present workers (which would weaken the quorum behind the caller's back).
    assert_raise ArgumentError, ~r/quorum: :configured needs the method's configured/, fn ->
      APIServer.call_remote_method(NoSuchMod, {:work},
        multicast: true,
        strategy: :quorum,
        quorum: :configured,
        timeout: 100
      )
    end
  end

  test "the default quorum without the configured set raises too (the default is :configured)" do
    assert_raise ArgumentError, ~r/configured/, fn ->
      APIServer.call_remote_method(NoSuchMod, {:work},
        multicast: true,
        strategy: :quorum,
        timeout: 100
      )
    end
  end
end
