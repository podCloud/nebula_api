defmodule NebulaApiTest do
  use ExUnit.Case
  doctest NebulaApi

  test "greets the world" do
    assert NebulaApi.hello() == :world
  end
end
