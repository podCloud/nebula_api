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
end
