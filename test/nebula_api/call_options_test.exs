defmodule NebulaAPI.CallOptionsTest do
  use ExUnit.Case

  alias NebulaAPI.Config

  describe "Config.default_timeout/0 (R3)" do
    test "reads the :default_timeout app env" do
      Application.put_env(:nebula_api, :default_timeout, 777)
      on_exit(fn -> Application.delete_env(:nebula_api, :default_timeout) end)

      assert Config.default_timeout() == 777
    end

    test "falls back to 5000 when unset" do
      assert Config.default_timeout() == 5_000
    end
  end

  describe "APIServer.resolve_timeout/2 (R3)" do
    alias NebulaAPI.APIServer

    # Mirrors what `use NebulaAPI, default_timeout: 1234` persists.
    defmodule WithModuleDefault do
      Module.register_attribute(__MODULE__, :nebula_api, persist: true)
      @nebula_api [default_timeout: 1234]
    end

    defmodule WithoutOpts do
    end

    test "the call's timeout: option wins over everything" do
      assert APIServer.resolve_timeout(WithModuleDefault, timeout: 99) == 99
    end

    test "the module's default_timeout beats the global default" do
      assert APIServer.resolve_timeout(WithModuleDefault, []) == 1234
    end

    test "the global default applies when the module has none" do
      Application.put_env(:nebula_api, :default_timeout, 777)
      on_exit(fn -> Application.delete_env(:nebula_api, :default_timeout) end)

      assert APIServer.resolve_timeout(WithoutOpts, []) == 777
    end

    test "a module atom that is not a compiled module falls back safely" do
      assert APIServer.resolve_timeout(NotARealModule, []) == 5_000
    end
  end
end
