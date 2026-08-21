defmodule Sample.Counter do
  @moduledoc false

  use GenServer

  # Baked in at compile time so that the 0.1.0 and 0.1.1 builds of this module
  # genuinely differ, and so that a hot upgrade is observable from the outside.
  @vsn_tag System.get_env("SAMPLE_VSN", "0.1.0")

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def bump, do: GenServer.call(__MODULE__, :bump)

  @doc "Returns `{code version, count}`. The count must survive a hot upgrade."
  def info, do: GenServer.call(__MODULE__, :info)

  @impl true
  def init(:ok), do: {:ok, %{count: 0, vsn: @vsn_tag}}

  @impl true
  def handle_call(:bump, _from, %{count: count} = state),
    do: {:reply, count + 1, %{state | count: count + 1}}

  def handle_call(:info, _from, state), do: {:reply, {state.vsn, state.count}, state}

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, %{state | vsn: @vsn_tag}}
end
