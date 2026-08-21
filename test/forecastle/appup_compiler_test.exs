defmodule Forecastle.AppupCompilerTest do
  @moduledoc """
  Drives the `:appup` compiler by compiling the sample fixture for real.

  Compiling is enough - nothing here needs a release assembled - but it still
  shells out to `mix`, so these tests are slow by unit-test standards and are
  never async. They build into a build root of their own, so that deleting the
  fixture's appup cannot disturb the trees the assembly and upgrade tests share.

  The point of exercising this through repeated builds rather than by calling
  `run/1` directly is that the bug only appears on the second build: the first
  one writes the appup, and it is what the second one does with it that matters.
  """

  use ExUnit.Case, async: false

  alias Forecastle.Fixture

  @moduletag :slow
  @moduletag timeout: 600_000

  setup do
    build_root = Path.join(Fixture.workspace(), "_build-appup")
    ebin = Path.join(build_root, "prod/lib/sample/ebin")

    {:ok, build_root: build_root, ebin: ebin, appup: Path.join(ebin, "sample.appup")}
  end

  describe "compiling an appup" do
    test "writes the evaluated source into ebin", ctx do
      compile!(ctx)

      assert {:ok, [{~c"0.1.0", [], []}]} = :file.consult(to_charlist(ctx.appup))
    end

    test "evaluates the source again on every build", ctx do
      compile!(ctx)
      compile!(ctx, [{"SAMPLE_VSN", "0.2.0"}])

      # The fixture's appup.exs reads its version from the environment, so its
      # own mtime says nothing about whether the output is current. This is why
      # the compiler declares no manifests and rewrites unconditionally.
      assert {:ok, [{~c"0.2.0", [_ | _], [_ | _]}]} = :file.consult(to_charlist(ctx.appup))
    end
  end

  describe "an appup left over from an earlier build" do
    test "is removed when the source is deleted", ctx do
      compile!(ctx)
      assert File.exists?(ctx.appup)

      delete_appup_source()
      {output, status} = Fixture.mix(["compile"], env(ctx))

      assert output =~ "error: Appup file not found"
      assert status != 0, "compiling without the configured appup should fail"
      refute File.exists?(ctx.appup)
      # Only the appup: the compiler must not take the rest of ebin with it.
      assert File.exists?(Path.join(ctx.ebin, "Elixir.Sample.Counter.beam"))
    end

    test "is removed when the project stops asking for one", ctx do
      compile!(ctx)
      assert File.exists?(ctx.appup)

      output = compile!(ctx, [{"SAMPLE_APPUP", "none"}])

      refute File.exists?(ctx.appup)
      assert File.exists?(Path.join(ctx.ebin, "Elixir.Sample.Counter.beam"))
      assert output =~ "warning: No appup specified in project"
    end
  end

  defp compile!(ctx, extra \\ []), do: Fixture.mix!(["compile"], env(ctx, extra))

  defp env(%{build_root: build_root}, extra \\ []), do: [{"MIX_BUILD_ROOT", build_root} | extra]

  # The workspace is memoised and shared with every other test in the run, so
  # this has to go back. Through `on_exit`, which runs even if the test times
  # out or the test process dies.
  defp delete_appup_source do
    src = Path.join(Fixture.workspace(), "appup.exs")
    contents = File.read!(src)
    on_exit(fn -> File.write!(src, contents) end)
    File.rm!(src)
  end
end
