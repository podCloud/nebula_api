defmodule NebulaAPI.Test do
  use NebulaAPI

  defapi [@worker, !(&db)], hello_name(name) do
    "Hello #{name} from #{node()}"
  end

  defapi [&nebula, !@api], hello_world() do
    "Hello world from #{node()}"
  end

  on_nebula [&nebula, @api] do
    IO.puts("Hello world from podcloud")
  end

  on_nebula [&youpod, !@api] do
    IO.puts("Hello world from youpod context")
  end
end

NebulaAPI.Test.hello_name("John") |> dbg
NebulaAPI.Test.hello_world() |> dbg
NebulaAPI.Test.hello_name({:asdf}) |> dbg
