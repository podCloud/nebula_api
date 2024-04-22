defmodule NebulaAPI.Test do
  use NebulaAPI, node: "nebula@host.example"

  defapi hello_name(name) do
    IO.puts("Hello #{name} from #{node()}")
  end

  defapi hello_world() do
    hello_name("World")
  end
end
