defmodule Forecastle.HeartBootstrapTest do
  @moduledoc """
  Boots a real release on its first start with no heart flag supplied by the
  project. This is the path where Forecastle has to create releases/RELEASES
  with a short-lived VM and then add its own -heart for the system VM.

  The distinction is observable only across the whole launcher: before the
  ordering fix the helper inherited Forecastle's flag and printed an orderly
  heart shutdown from `bin/sample daemon`, while the daemon started normally
  afterwards. A shell assertion can pin the ordering; this pins the two VMs.
  """

  use Forecastle.ReleaseCase

  alias Forecastle.Deployment

  @moduletag :e2e

  @heart_report """
  IO.puts(inspect({:init.get_argument(:heart), System.get_env("ELIXIR_ERL_OPTIONS")}))
  """

  setup_all do
    deploy = deployment(assemble!(into: "heart-bootstrap"))
    suffix = System.unique_integer([:positive])
    env = [{"RELEASE_NODE", "sample_heart_bootstrap_#{suffix}"}]

    on_exit(fn -> Deployment.stop(deploy, env) end)

    output = Deployment.start!(deploy, env)

    {:ok, deploy: deploy, env: env, output: output}
  end

  test "keeps the helper quiet and starts the system with one added heart",
       %{deploy: deploy, env: env, output: output} do
    refute output =~ "heart_beat_kill_pid"
    refute output =~ "heart_beat_timeout"
    refute output =~ "Erlang has closed"
    refute output =~ "Would reboot"

    assert File.regular?(Path.join(deploy.root, "releases/RELEASES"))
    assert Deployment.rpc!(deploy, @heart_report, env) == ~s({{:ok, [[]]}, "-heart"})
  end
end
