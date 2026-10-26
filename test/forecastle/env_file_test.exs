defmodule Forecastle.EnvFileTest do
  @moduledoc """
  Starts and evaluates a real release with `CASTLE_ENV_FILE` set, and asserts
  on the configuration `runtime.exs` resolved from it.

  `Forecastle.EnvFileScriptTest` runs the prefix on its own; this is the claim
  that it reaches the launcher's commands and the VM they start. The file sets
  `SAMPLE_ENV_MARKER` as well as `SAMPLE_GREETING`, and the fixture's own
  `env.sh` exports the marker after it - so a node answering the file's greeting
  and the project's marker says both that the file was read and that the
  project's `env.sh` ran after it.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Deployment

  @moduletag :e2e

  @contents """
  SAMPLE_GREETING=from-env-file
  SAMPLE_ENV_MARKER=from-env-file
  """

  setup_all do
    deploy = deployment(assemble!(into: "env-file"))

    file = Path.join(deploy.root, "etc/castle.env")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, @contents)

    {:ok, deploy: deploy}
  end

  test "an eval resolves runtime.exs over the file, named relative to the release root",
       %{deploy: deploy} do
    env = [{"CASTLE_ENV_FILE", "etc/castle.env"}]

    assert Deployment.launcher!(deploy, ["eval", "IO.puts(Sample.greeting())"], env) ==
             "from-env-file"

    assert Deployment.launcher!(deploy, ["eval", "IO.puts(Sample.env_marker())"], env) ==
             "preserved"
  end

  test "a started node is configured from the file", %{deploy: deploy} do
    suffix = System.unique_integer([:positive])

    env = [
      {"CASTLE_ENV_FILE", Path.join(deploy.root, "etc/castle.env")},
      {"RELEASE_NODE", "sample_env_file_#{suffix}"}
    ]

    on_exit(fn -> Deployment.stop(deploy, env) end)

    Deployment.start!(deploy, env)

    assert Deployment.rpc!(deploy, "IO.puts(Sample.greeting())", env) == "from-env-file"
    assert Deployment.rpc!(deploy, "IO.puts(Sample.env_marker())", env) == "preserved"
  end

  test "a file that is not there stops the command", %{deploy: deploy} do
    missing = Path.join(deploy.root, "etc/absent.env")
    env = [{"CASTLE_ENV_FILE", missing}]

    for args <- [["eval", "IO.puts(:evaluated)"], ["daemon"]] do
      {output, status} = Deployment.launcher(deploy, args, env)

      assert status != 0
      assert output =~ "ERROR: CASTLE_ENV_FILE names #{missing}, which is not a readable file"
      refute output =~ "evaluated"
    end
  end
end
