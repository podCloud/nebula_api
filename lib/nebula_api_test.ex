defmodule NebulaAPI.Test do
  # use :nonode@nohost if we are in dev mode
  #
  use NebulaAPI, node: :nebula@host

  defapi get_user(name) do
    IO.puts("Hello World : #{name}")
  end
end
