defmodule NebulaAPI.Test do
  use NebulaAPI

  defapi [@worker, !(&db)], hello_name(name) do
    "Hello #{name} from #{node()}"
  end

  defapi [&nebula, !@nebula], hello_world() do
    "Hello world from #{node()}"
  end

  on_nebula [&nebula, @nebula] do
    IO.puts("Hello world from podcloud")
  end

  on_nebula [&youpod, !@nebula] do
    IO.puts("Hello world from youpod context")
  end
end
