defmodule SampleB do
  @moduledoc false

  # Records the order applications start and stop in, in `:persistent_term`
  # rather than anything this application owns, so that it outlives the stop and
  # the unload that follows it.
  use Application

  @impl true
  def start(_type, _args) do
    record(:sample_added_starts)
    # A supervisor, because `release_handler` asks every application's top
    # process for its children during an upgrade.
    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
  end

  @impl true
  def stop(_state) do
    record(:sample_added_stops)
  end

  defp record(key) do
    :persistent_term.put(key, :persistent_term.get(key, []) ++ [:sample_b])
  end
end
