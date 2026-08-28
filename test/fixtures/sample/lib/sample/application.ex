defmodule Sample.Application do
  @moduledoc false

  use Application

  # Two children of the same shape, carrying the same compile-time version tag,
  # one of which the appup mentions and one of which it does not. Both have to
  # be running and supervised for the comparison to mean anything: `update` only
  # reaches processes found through the supervision tree, so the module left out
  # of the appup has to be somewhere the upgrade *would* have reached it.
  @impl true
  def start(_type, _args) do
    if delay = System.get_env("SAMPLE_BOOT_DELAY_MS") do
      Process.sleep(String.to_integer(delay))
    end

    Supervisor.start_link([Sample.Counter, Sample.Unmentioned],
      strategy: :one_for_one,
      name: Sample.Supervisor
    )
  end
end
