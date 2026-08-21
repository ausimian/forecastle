defmodule Sample.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([Sample.Counter], strategy: :one_for_one, name: Sample.Supervisor)
  end
end
