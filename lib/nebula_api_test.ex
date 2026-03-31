defmodule NebulaAPI.Test do
  use NebulaAPI

  defapi [@worker, !(&db)], hello_name(name) do
    "Hello #{name} from #{node()}"
  end

  defapi [&nebula, !@api], hello_world() do
    "Hello world from #{node()}"
  end

  on_nebula_nodes [&nebula, @api] do
    @api_greeting "Hello world from podcloud"
  end

  on_nebula_nodes [&youpod, !@api] do
    @worker_greeting "Hello world from youpod context"
  end
end
