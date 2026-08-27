defmodule Forecastle.UpgradeCase do
  @moduledoc """
  Case template for tests that upgrade a real release from one version to the
  next.

  A release that assembles is a release that builds. Whether it can be *upgraded*
  is a different question, and the only thing that answers it is starting one
  version, installing the next, and looking at what survived. This is the half of
  that a project does not have to write: a directory to deploy into, and
  `Forecastle.Deployment` aliased for the driving.

  **What it does not do is decide whether the upgrade worked.** That is the
  reason this is a case template and not a `mix castle.upgrade.test` task: a task
  would have to hardcode what "worked" means, and only the project knows. For one
  it is a counter that kept counting, for another a socket still open or a job
  still in flight. As a case template it composes with tags, with CI and with the
  project's own assertions instead.

  ## What a project writes

  Two things have to exist before a test can run: the release that is deployed,
  and the release it is upgraded to, carrying a relup that names the first.
  Neither is this template's business - a project builds its own releases - and
  the second is a single `mix release` once `upgrade_from:` names the baseline:

      defp releases do
        [
          my_app: fn ->
            [upgrade_from: ["tar:artifacts/my_app-1.0.0.tar.gz"]]
            |> Castle.customize()
          end
        ]
      end

  The test then deploys that same artefact, starts it, and installs the tarball
  the build just produced:

      defmodule MyApp.UpgradeTest do
        use Forecastle.UpgradeCase

        @tag :upgrade
        @shipped "tar:artifacts/my_app-1.0.0.tar.gz"
        @next "_build/prod/my_app-1.1.0.tar.gz"

        setup_all %{scratch: scratch} do
          deployment = Deployment.deploy!(@shipped, Path.join(scratch, "deploy"))
          on_exit(fn -> Deployment.stop(deployment) end)

          Deployment.start!(deployment)
          Deployment.rpc!(deployment, "IO.puts(MyApp.Counter.bump())")

          Deployment.stage!(deployment, @next)
          Deployment.castle!(deployment, ["unpack", "1.1.0"])
          Deployment.castle!(deployment, ["install", "1.1.0"])
          Deployment.castle!(deployment, ["commit"])

          {:ok, deployment: deployment}
        end

        test "moved to 1.1.0 and took the count with it", %{deployment: deployment} do
          assert Deployment.rpc!(deployment, "IO.puts(inspect(MyApp.Counter.info()))") ==
                   ~s({"1.1.0", 1})

          assert Deployment.version(deployment) == "1.1.0"
        end
      end

  `castle!/3` raises on a non-zero exit, so `unpack`, `install` and `commit`
  failing is a failure of the setup rather than something a later assertion has
  to notice.

  ## Assert the code as well as the state, and take the version from the code

  **A count that survived is not evidence that anything moved.** An appup that
  does not mention a module leaves that module's *old* code serving calls, with
  the new code on disk beside it, and a count is preserved by exactly that -
  which is the failure `mix castle.appup` exists to catch, and the reason an
  upgrade test asserting only the state would pass one. So `info/0` above
  reports the version alongside the count, and reports it from a literal the
  module carries:

      defmodule MyApp.Counter do
        use GenServer

        @vsn_tag Mix.Project.config()[:version]

        @doc "`{the version compiled into the code serving this call, count}`"
        def info, do: GenServer.call(__MODULE__, :info)

        def handle_call(:info, _from, state), do: {:reply, {@vsn_tag, state.count}, state}
      end

  `@vsn_tag` is compiled into whichever copy of the module is executing, so an
  old one says this process is running old code. Reading the version from
  `Application.spec/2` or from `Deployment.version/1` instead would answer about
  the *release*, which moves whether or not any particular module did - which is
  why the example asserts both, and why they are different questions.

  ## The two transitions are installed differently

  The example above is a hot upgrade. A transition that restarts the emulator
  needs `Forecastle.Deployment.install_supervised!/3` in place of the `install`
  above, because nothing inside the release starts it again after the reboot -
  `bin/start` is inert and the external supervisor owns the restart, so a test of
  one has to *be* the supervisor. There is no call that covers both: a hot
  upgrade never leaves its operating system process, so waiting for that process
  to exit would be waiting for something that is not coming.

  It raises the way `castle!/3` does, and the failure it is raising about is
  usually on the far side of the reboot: `bin/castle install` polls for the
  version it installed *after* the release has come back, so a provisional
  release that rolled back on the way up is reported there and nowhere earlier.
  `Forecastle.Deployment.install_supervised/3` returns `{output, status}` for a
  test that wants to assert on the status itself.

  Which of the two a transition is comes from the relup, and `auto` decides it at
  generation time. A project that wants to be sure gets to say so:
  `mix castle.relup --hot` fails rather than degrading to a restart, which puts
  the failure on the build instead of on an assertion much further down.

  ## Baselines, and why `tar:`

  `Forecastle.Deployment.deploy!/3` takes the baseline grammar
  `Forecastle.Baseline` reads, so the release under test can come from an
  assembled tree (`rel:`), the artefact that shipped (`tar:`) or a git ref built
  in a worktree (`ref:`).

  Prefer `tar:`, and for the same reason relup generation does: `release_handler`
  selects a relup entry by from-version *string* and never checks it against the
  code that is running. An upgrade tested from a baseline rebuilt today is an
  upgrade tested from a release nobody ever deployed, which is exactly the
  question the test was meant to settle.

  ## The scratch directory

  `setup_all` puts a `:scratch` directory in the context, one per test module,
  under `_build/castle/deployments`. It is emptied when the module starts and
  **left behind when it finishes**: a deployment that failed to upgrade is the
  evidence, and deleting it at the end of the run would take away the release
  tree, the logs and the `releases/RELEASES` that say what happened. The next run
  of that module clears it.

  It is a path rather than a directory until something deploys into it -
  `deploy!/3` creates what it needs - so a suite that uses this template for the
  rest of what it offers leaves nothing behind at all.

  Deployments are not stopped for you. A running release outlives the test that
  started it, so `on_exit(fn -> Deployment.stop(deployment) end)` belongs beside
  every `start!/2` - and `stop/1` tolerates a system that is not running, which
  is what makes it safe in a teardown after a setup that died half way.

  ## Not async

  A deployment is a node with a name and a distribution port, and two tests
  starting the same release at once is a name clash rather than two nodes.
  Assembling and booting releases is slow by unit-test standards besides, so
  these tests want a tag of their own and an opt-in run - which is what
  `@moduletag :upgrade` in the example above is for.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Forecastle.Deployment

      # Generous, because a single test module here can assemble releases, boot a
      # node and reboot it. ExUnit's default of 60s is a description of a unit
      # test.
      @moduletag timeout: 600_000
    end
  end

  setup_all context do
    scratch = scratch_dir(context.module)

    # Cleared on the way in rather than on the way out. What a failed upgrade
    # leaves on disk is the evidence - the tree that was deployed, whatever the
    # release logged, and the RELEASES file saying which versions the system
    # knew about - and a teardown that removed it would take that away at exactly
    # the moment it became interesting.
    #
    # Not created here, so that a module using this template for the alias and
    # the timeout does not leave an empty directory behind to explain.
    File.rm_rf!(scratch)

    {:ok, scratch: scratch}
  end

  # Beside `_build/castle/baselines` rather than inside an environment, which is
  # the same reasoning `Forecastle.Baseline` records: `Mix.Project.build_path/0`
  # is `<build root>/<env>`, and a deployment is no more a `test` artefact than a
  # baseline is. One directory per test module, named after it, so that two
  # suites deploying at once cannot land in the same tree.
  defp scratch_dir(module) do
    Path.join([
      Path.dirname(Mix.Project.build_path()),
      "castle",
      "deployments",
      inspect(module)
    ])
  end
end
