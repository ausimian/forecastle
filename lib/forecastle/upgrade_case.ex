defmodule Forecastle.UpgradeCase do
  @moduledoc """
  Case template for tests that upgrade a real release from one version to the
  next.

  The template adds a per-module `:scratch` path and aliases
  `Forecastle.Deployment`. The project supplies the releases and assertions.

  Build the target release with a relup for the deployed baseline:

      defp releases do
        [
          my_app: fn ->
            [upgrade_from: ["tar:artifacts/my_app-1.0.0.tar.gz"]]
            |> Castle.customize()
          end
        ]
      end

  Deploy the baseline, start it, then install and commit the target:

      defmodule MyApp.UpgradeTest do
        use Forecastle.UpgradeCase

        @moduletag :upgrade

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

  `castle!/3` raises on a non-zero exit. Assert both retained state and the code
  version serving calls. A missing appup instruction can leave old code running
  while the release reports the new version. Compile a version tag into the
  module under test:

      defmodule MyApp.Counter do
        use GenServer

        @vsn_tag Mix.Project.config()[:version]

        @doc "`{the version compiled into the code serving this call, count}`"
        def info, do: GenServer.call(__MODULE__, :info)

        def handle_call(:info, _from, state), do: {:reply, {@vsn_tag, state.count}, state}
      end

  `Deployment.deploy!/3` accepts `rel:`, `tar:` and `ref:` baselines. Prefer the
  shipped `tar:` artifact when available.

  Use `Deployment.install_supervised!/3` for `restart_emulator` transitions and
  `castle!/3` for hot installs. The supervised form restarts the release while
  `bin/castle install` waits for it to return.

  The scratch path lives under `_build/castle/deployments`. The template does
  not create, clear or remove it. Register `Deployment.stop/1` with `on_exit/1`
  for every started deployment.

  Mark the whole module with `@moduletag :upgrade`; these tests start named nodes
  and should not run asynchronously or as part of the ordinary unit suite.
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
    # Named and nothing more: not created, and **not cleared**. Clearing it was
    # the obvious thing and it was wrong in a way that comes back as a passing
    # test. The path is stable per module, so a run interrupted before its
    # `on_exit` - Ctrl-C, a killed CI job - leaves a daemon running out of this
    # tree; a recursive delete here would not stop that node, and the next
    # deployment would come up beside one that still answers to the release's
    # name. Nothing at this level knows which releases are in there or whether
    # any of them is alive.
    #
    # `Forecastle.Deployment.deploy!/3` empties its own destination, which is
    # the same question asked where the release name is known, and it refuses a
    # destination that is still running rather than deleting underneath it. So
    # what survives here is what nothing redeployed - which is the evidence a
    # failed upgrade left.
    {:ok, scratch: scratch_dir(context.module)}
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
