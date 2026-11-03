defmodule Forecastle.RemovedAppsUpgradeTest do
  @moduledoc """
  Hot-upgrades a release to a version that removes applications, and back down.

  `:systools` removes an application with `application:stop/1`, a `remove` and
  `purge` of each of its modules and `application:unload/1`, and nothing in that
  touches the code path. `release_handler_1` only ever *replaces* paths, at
  `point_of_no_return`, for the libraries a relup loads code from. So a hot
  removal left the application's `lib/<app>-<vsn>/ebin` on the code path for the
  life of the node, and while the superseded release was still on disk, its
  `.app` could still be found. `application:ensure_all_started/1` decides whether
  an optional dependency is available by exactly that lookup, so a later
  upgrade adding an application with an optional dependency on the removed one
  took it for present. A restart builds the path from the boot script and never
  had the problem, so a hot install and a restart disagreed.

  The relup now deletes the path after each removed application is unloaded.
  The downgrade half is what says that is safe: adding the application back
  goes through `load_object_code`, which records its library for
  `point_of_no_return`, whose `code:replace_path/2` adds a path where there is
  none to replace.

  The starting point is the fixture built with `SAMPLE_ADDED_APPS=true`, which
  carries `:sample_a`, `:sample_b` and `:sample_c`; the target is built without
  them. Both are on the versions the fixture's appups cover, so `auto` judges the
  transition hot.
  """

  use Forecastle.ReleaseCase
  use Forecastle.UpgradeCase

  @moduletag :e2e

  @from "0.1.0"
  # A version of its own, and so a build root of its own.
  @to "0.4.0"

  @removed [:sample_a, :sample_b, :sample_c]

  setup_all do
    # 0.1.0 is every other suite's baseline, built without the added
    # applications, so this build of it takes a build root of its own.
    root =
      assemble!(
        into: "removed-from",
        vsn: @from,
        build_root: "_build-#{@from}-added",
        env: [{"SAMPLE_ADDED_APPS", "true"}]
      )

    deploy = deployment(root)

    next =
      assemble!(
        into: "removed-to",
        vsn: @to,
        env: [
          {"SAMPLE_UPGRADE_FROM", "rel:" <> Path.join(deploy.root, "releases/#{@from}/sample")}
        ]
      )

    {:ok, [{_vsn, [{_, _, up}], [{_, _, down}]}]} =
      :file.consult(to_charlist(Path.join(next, "releases/#{@to}/relup")))

    Deployment.stage!(deploy, Path.join(next, "sample-#{@to}.tar.gz"))

    on_exit(fn -> Deployment.stop(deploy) end)

    Deployment.start!(deploy)
    booted = observe(deploy)

    Deployment.castle!(deploy, ["unpack", @to])
    Deployment.castle!(deploy, ["install", @to])
    installed = observe(deploy)

    Deployment.castle!(deploy, ["install", @from])
    downgraded = observe(deploy)

    {:ok,
     root: deploy.root,
     up: up,
     down: down,
     booted: booted,
     installed: installed,
     downgraded: downgraded}
  end

  describe "the generated relup" do
    test "deletes each removed application's path immediately after unloading it", %{up: up} do
      for app <- @removed do
        unload = Enum.find_index(up, &(&1 == {:apply, {:application, :unload, [app]}}))

        assert is_integer(unload), "no unload for #{inspect(app)}"
        assert Enum.at(up, unload + 1) == {:apply, {:code, :del_path, [app]}}
      end
    end

    test "deletes no path on the way down, which removes nothing", %{down: down} do
      refute Enum.any?(down, &match?({:apply, {:code, :del_path, _}}, &1))
    end
  end

  describe "the release as booted" do
    test "has every application on its code path", %{booted: booted} do
      assert booted.paths == ["sample_a-0.1.0", "sample_b-0.1.0", "sample_c-0.1.0"]
      for app <- @removed, do: assert(app in booted.started)
    end
  end

  describe "a hot install that removes applications" do
    test "stops them", %{installed: installed} do
      for app <- @removed, do: refute(app in installed.started)
    end

    test "leaves their directories on disk while the old release is installed", %{root: root} do
      for app <- @removed, do: assert(File.dir?(Path.join(root, "lib/#{app}-0.1.0/ebin")))
    end

    test "takes them off the code path", %{installed: installed} do
      assert installed.paths == []
    end

    # What `application:ensure_all_started/1` asks of an optional dependency,
    # and what `application:load/1` asks of any application.
    test "leaves no .app for them to be found by", %{installed: installed} do
      assert installed.app_files == [:non_existing, :non_existing, :non_existing]
    end
  end

  describe "a hot downgrade that adds them back" do
    test "puts each back on the code path, once", %{downgraded: downgraded} do
      assert downgraded.paths == ["sample_a-0.1.0", "sample_b-0.1.0", "sample_c-0.1.0"]
    end

    test "finds their .app files again", %{downgraded: downgraded, root: root} do
      assert downgraded.app_files ==
               for(app <- @removed, do: Path.join(root, "lib/#{app}-0.1.0/ebin/#{app}.app"))
    end

    test "starts them", %{downgraded: downgraded} do
      for app <- @removed, do: assert(app in downgraded.started)
    end
  end

  # One rpc, so that the three answers are about one moment. Paths are reduced
  # to the library directory's name, and `.app` lookups use
  # `code:where_is_file/1`, which reads the code path without changing anything:
  # `Application.load/1` would load the specification and alter what the
  # downgrade starts from.
  defp observe(deploy) do
    removed = inspect(@removed)

    deploy
    |> Deployment.rpc!("""
    paths =
      for path <- :code.get_path(),
          dir = path |> to_string() |> Path.dirname() |> Path.basename(),
          String.starts_with?(dir, "sample_") and not String.starts_with?(dir, "sample_dep"),
          do: dir

    app_files =
      for app <- #{removed} do
        case :code.where_is_file(~c"\#{app}.app") do
          :non_existing -> :non_existing
          file -> to_string(file)
        end
      end

    started = for {app, _, _} <- Application.started_applications(), do: app

    IO.inspect(%{paths: Enum.sort(paths), app_files: app_files, started: started}, limit: :infinity)
    """)
    |> Code.string_to_quoted!()
    |> then(fn {:%{}, _, kvs} -> Map.new(kvs) end)
  end
end
