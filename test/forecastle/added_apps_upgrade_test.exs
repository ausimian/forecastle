defmodule Forecastle.AddedAppsUpgradeTest do
  @moduledoc """
  Hot-upgrades a release to a version that adds applications, and back down.

  `:systools` starts the applications a relup adds in the order of the target
  `.rel` and stops the ones a downgrade removes in the same order, and Mix writes
  that file alphabetically past the project's own applications - not in
  dependency order. `release_handler` ignores what an `apply` returns, so an
  application started before one it depends on stays stopped and the install
  succeeds anyway. [#66](https://github.com/ausimian/forecastle/issues/66)

  The target is the fixture built with `SAMPLE_ADDED_APPS=true`, which adds
  `:sample_a`, `:sample_b` and `:sample_c`; `:sample_a` and `:sample_c` depend on
  `:sample_b`. So the `.rel` order starts `:sample_a` too early on the way up and
  stops `:sample_b` too early on the way down. Each application records when it
  starts and stops in `:persistent_term`, which is what the runtime half of this
  suite reads back.

  The relup is the one a single `mix release` generates from `upgrade_from:`
  under `auto`, which judges this transition hot: the applications being added
  are left to `:systools`, and the fixture's dependency carries an appup covering
  its move.
  """

  use Forecastle.ReleaseCase
  use Forecastle.UpgradeCase

  @moduletag :e2e

  @from "0.1.0"
  # A version of its own, and so a build root of its own: every other suite
  # builds the fixture without the added applications.
  @to "0.2.0"

  @added [:sample_a, :sample_b, :sample_c]

  setup_all do
    deploy = deployment(assemble!(into: "added-from", vsn: @from))

    next =
      assemble!(
        into: "added-to",
        vsn: @to,
        env: [
          {"SAMPLE_ADDED_APPS", "true"},
          {"SAMPLE_UPGRADE_FROM", "rel:" <> Path.join(deploy.root, "releases/#{@from}/sample")}
        ]
      )

    {:ok, [{_vsn, [{_, _, up}], [{_, _, down}]}]} =
      :file.consult(to_charlist(Path.join(next, "releases/#{@to}/relup")))

    Deployment.stage!(deploy, Path.join(next, "sample-#{@to}.tar.gz"))

    on_exit(fn -> Deployment.stop(deploy) end)

    Deployment.start!(deploy)

    Deployment.castle!(deploy, ["unpack", @to])
    Deployment.castle!(deploy, ["install", @to])

    installed = %{
      started: started(deploy),
      starts: Deployment.rpc!(deploy, "IO.inspect(:persistent_term.get(:sample_added_starts))")
    }

    Deployment.castle!(deploy, ["install", @from])

    downgraded = %{
      started: started(deploy),
      stops: Deployment.rpc!(deploy, "IO.inspect(:persistent_term.get(:sample_added_stops))")
    }

    {:ok, up: up, down: down, installed: installed, downgraded: downgraded}
  end

  describe "the generated relup" do
    test "starts each added application after the ones it depends on", %{up: up} do
      assert started_in(up) == [:sample_b, :sample_a, :sample_c]
    end

    test "starts them only once every added module is loaded", %{up: up} do
      first_start = Enum.find_index(up, &match?({:apply, {:application, :start, _}}, &1))

      loads =
        for {{:load, {module, _, _}}, index} <- Enum.with_index(up),
            module in [SampleA, SampleB, SampleC],
            do: index

      assert length(loads) == 3
      assert Enum.all?(loads, &(&1 < first_start))
    end

    test "stops each removed application before the ones it depends on", %{down: down} do
      assert stopped_in(down) == [:sample_a, :sample_c, :sample_b]
    end

    test "stops them before any removed module is gone", %{down: down} do
      last_stop =
        down
        |> Enum.with_index()
        |> Enum.filter(&match?({{:apply, {:application, :stop, _}}, _}, &1))
        |> List.last()
        |> elem(1)

      first_remove = Enum.find_index(down, &match?({:remove, _}, &1))

      assert last_stop < first_remove
    end
  end

  describe "a hot install" do
    test "starts every added application", %{installed: installed} do
      for app <- @added, do: assert(app in installed.started)
    end

    test "starts them in dependency order", %{installed: installed} do
      assert installed.starts == "[:sample_b, :sample_a, :sample_c]"
    end
  end

  describe "a hot downgrade" do
    test "stops every removed application", %{downgraded: downgraded} do
      for app <- @added, do: refute(app in downgraded.started)
    end

    test "stops dependents before their dependency", %{downgraded: downgraded} do
      assert downgraded.stops == "[:sample_a, :sample_c, :sample_b]"
    end
  end

  defp started(deploy) do
    deploy
    |> Deployment.rpc!(
      "IO.inspect(for {app, _, _} <- Application.started_applications(), do: app)"
    )
    |> Code.string_to_quoted!()
  end

  defp started_in(script) do
    for {:apply, {:application, :start, [app, _type]}} <- script, do: app
  end

  defp stopped_in(script) do
    for {:apply, {:application, :stop, [app]}} <- script, do: app
  end
end
