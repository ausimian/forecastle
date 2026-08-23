defmodule Forecastle.Fixture do
  @moduledoc """
  Owns the on-disk workspace that the sample fixture application is built in,
  and runs commands inside it.

  The workspace lives under `_build` rather than `test/fixtures` so that the
  dependencies and build artefacts it accumulates are never picked up by the
  formatter or by `mix test`, and so that they survive between runs.
  Preparation is memoised: the first caller pays for `mix deps.get`, everyone
  else gets the path.

  Delete `_build/fixtures` to start from a clean slate.
  """

  use Agent

  @root Path.expand("../..", __DIR__)
  @source Path.join(@root, "test/fixtures/sample")
  @workspace Path.join(@root, "_build/fixtures/sample")

  # Mix variables that would otherwise leak from the parent test run into the
  # fixture build and silently redirect its output, and release variables that
  # would leak into a launcher the tests invoke.
  #
  # `ERL_AFLAGS`, `ERL_FLAGS` and `ERL_ZFLAGS` are here alongside
  # `ELIXIR_ERL_OPTIONS` because all four carry flags to the emulator - erlexec
  # prepends the first and appends the other two to the command line it builds -
  # so any of them set in a developer's shell or a CI image would put a `-heart`
  # into every start these suites make. A suite that wants one there sets it
  # itself, which is what `Forecastle.RestartUpgradeTest` does.
  #
  # `ERL_OTP<major>_FLAGS` is a fifth such variable - erlexec prepends it too -
  # and it leaks the same way, but it cannot be written into this list because its
  # name carries the emulator's OTP major. It is appended in `env/1` instead. The
  # `env.sh` fragment measures that variable rather than modelling it now, which
  # makes one leaked into an e2e start a way to hang a boot on two `-heart` flags
  # rather than merely a way to add an unexpected one.
  #
  # `RELEASE_VM_ARGS` and `RELEASE_REMOTE_VM_ARGS` name the args file, which
  # carries the same flags, and they belong here for a sharper reason than the
  # others: they do not merely *add* a flag, they redirect the launcher to a
  # different args file entirely. One set in the environment would have every
  # release these suites assemble boot on some other project's vm.args, which would
  # present as an assembly bug rather than as a leaked variable.
  @scrubbed ~w(MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_TARGET MIX_QUIET
               MIX_DEBUG ERL_LIBS ELIXIR_ERL_OPTIONS ERL_AFLAGS ERL_FLAGS
               ERL_ZFLAGS RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS
               RELEASE_ROOT RELEASE_NAME
               RELEASE_VSN RELEASE_COOKIE RELEASE_NODE RELEASE_TMP)

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  @doc "Returns the prepared workspace path, preparing it on first call."
  def workspace do
    Agent.get_and_update(__MODULE__, &ensure_prepared/1, :infinity)
  end

  @doc "The root of the Forecastle checkout under test."
  def repo_root, do: @root

  @doc "Runs `mix` in the workspace, raising on failure."
  def mix!(args, env \\ []) do
    cmd!(mix_executable(), args, env)
  end

  @doc """
  Runs `mix` in the workspace, returning `{output, status}`.

  For the cases where a non-zero exit is the thing under test.
  """
  def mix(args, env \\ []) do
    cmd(mix_executable(), args, env)
  end

  @doc "Runs a command in the workspace, raising on a non-zero exit."
  def cmd!(exe, args, env \\ [], opts \\ []) do
    case cmd(exe, args, env, opts) do
      {output, 0} ->
        output

      {output, status} ->
        raise """
        #{Path.basename(exe)} #{Enum.join(args, " ")} exited with #{status}

        #{output}
        """
    end
  end

  @doc "Runs a command in the workspace, returning `{output, status}`."
  def cmd(exe, args, env \\ [], opts \\ []) do
    opts = Keyword.merge([cd: workspace(), stderr_to_stdout: true, env: env(env)], opts)
    System.cmd(exe, args, opts)
  end

  defp mix_executable, do: System.find_executable("mix") || "mix"

  defp ensure_prepared(nil) do
    File.mkdir_p!(@workspace)
    File.cp_r!(@source, @workspace)

    # Not via cmd/4: that would call back into this agent for the workspace.
    {output, status} =
      System.cmd(System.find_executable("mix") || "mix", ["deps.get"],
        cd: @workspace,
        stderr_to_stdout: true,
        env: env([])
      )

    if status != 0 do
      raise "could not fetch the fixture's dependencies:\n\n#{output}"
    end

    {@workspace, @workspace}
  end

  defp ensure_prepared(workspace), do: {workspace, workspace}

  defp env(extra) do
    scrubbed = ["ERL_OTP#{:erlang.system_info(:otp_release)}_FLAGS" | @scrubbed]

    Enum.map(scrubbed, &{&1, nil}) ++ [{"MIX_ENV", "prod"}, {"FORECASTLE_PATH", @root}] ++ extra
  end
end
