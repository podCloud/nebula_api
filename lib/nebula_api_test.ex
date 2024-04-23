defmodule NebulaAPI.Test do
  use NebulaAPI, node: "nebula@host.example"

  defapi hello_name(name) do
    "Hello #{name} from #{node()}"
  end

  defapi hello_world() do
    "Hello world from #{node()}"
  end
end
