defmodule Sample.Unmentioned do
  @moduledoc false

  use GenServer

  # `Sample.Counter`'s twin in every respect but one: the fixture's `appup.exs`
  # names `Sample.Counter` and deliberately says nothing about this module.
  #
  # That incompleteness *is* the fixture. `:systools.make_relup/4` fails when an
  # appup has no entry for the from-version, but it does not and cannot notice
  # that an entry is incomplete - so the relup generates, the install succeeds,
  # and this process goes on serving calls from the code that was loaded before,
  # with the new code sitting on disk, reachable and unused. That is the failure
  # `design/upgrade-tooling.md` §1.1 states, and `Forecastle.UpgradeTest` pins
  # that it really happens rather than leaving it as a mechanism nobody
  # demonstrated.
  #
  # **Do not add this module to `appup.exs`**, and do not "fix" the appup. The
  # upgrade suite asserts that this module still answers with the old tag after
  # an upgrade that reported success, and completing the appup takes that away.
  @vsn_tag System.get_env("SAMPLE_VSN", "0.1.0")

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  `{the tag in this process's state, the tag compiled into the code serving the
  call}`.

  Two answers rather than one, because they fail differently and only the second
  is about the *code*. `state.vsn` is put there by `init/1` at boot and replaced
  by `code_change/3` if anything ever calls it, so an unchanged one says no
  instruction reached this module - but it would be unchanged just the same if
  new code had been loaded with no `code_change` behind it. `@vsn_tag` is a
  literal in whichever copy of this module is executing the call, so an old one
  says this process is serving calls from the old code, which is the claim §1.1
  actually makes.
  """
  def info, do: GenServer.call(__MODULE__, :info)

  @impl true
  def init(:ok), do: {:ok, %{vsn: @vsn_tag}}

  @impl true
  def handle_call(:info, _from, state), do: {:reply, {state.vsn, @vsn_tag}, state}

  # Present, and never reached, which is what makes the assertion in
  # `Forecastle.UpgradeTest` a discriminator rather than a restatement. It would
  # answer with the *new* tag if the upgrade ever called it, so a process still
  # reporting the old one says no instruction reached this module at all.
  #
  # Its presence says nothing else. `use GenServer` injects an overridable
  # `code_change/3` into every module that uses it, so exporting one is not
  # evidence that a module was written to be upgraded - see
  # `design/upgrade-tooling.md` §3.2, which is why the coverage check does not
  # look at it.
  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, %{state | vsn: @vsn_tag}}
end
