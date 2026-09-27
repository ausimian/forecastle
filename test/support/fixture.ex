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

  alias Forecastle.Deployment

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

  # The variables that leak from the test run into a fixture build, and from
  # there into every release these suites start, are the shipped harness's list:
  # a project running an upgrade test has exactly the same problem with them, and
  # keeping a second copy here is how the two drift. See
  # `Forecastle.Deployment.scrubbed_env/1` for what is in it and why.
  #
  # The two set afterwards are this fixture's own: `MIX_ENV` because the fixture
  # is assembled in `prod`, and `FORECASTLE_PATH` because its `mix.exs` takes the
  # Forecastle under test from there. `extra` comes last, so a suite that wants a
  # scrubbed variable set - which is how `Forecastle.RestartUpgradeTest` gives a
  # release a hostile environment to boot in - simply names it.
  defp env(extra) do
    Deployment.scrubbed_env([{"MIX_ENV", "prod"}, {"FORECASTLE_PATH", @root}] ++ extra)
  end
end
