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

    test "writes a term :file.consult can read back, non-ASCII included", ctx do
      # A codepoint between 128 and 255 came out of the formatter as Unicode
      # chardata and went in as a lone byte, so the build reported success and
      # left behind an appup that neither :file.consult nor systools can parse.
      replace_appup_source(
        ~S<{~c"0.1.0", [{~c"0.0.9", [{:update, :café, {:advanced, []}}]}], []}>
      )

      compile!(ctx)

      assert {:ok, [{~c"0.1.0", [{~c"0.0.9", [{:update, :café, {:advanced, []}}]}], []}]} =
               :file.consult(to_charlist(ctx.appup))
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

      output = compile!(ctx, disabled(ctx))

      refute File.exists?(ctx.appup)
      assert File.exists?(Path.join(ctx.ebin, "Elixir.Sample.Counter.beam"))
      # Worth saying once, on the build where it actually happens: an appup
      # that vanishes without explanation is its own debugging problem.
      assert output =~ "Removed"
    end

    test "having opted out is not reported again on later builds", ctx do
      compile!(ctx)
      compile!(ctx, disabled(ctx))

      # Steady state. Being opted out is not a problem to be told about on
      # every compile, and the per-environment opt-out has to survive the
      # strict compile the precommit convention prescribes - `mix!` raises on
      # a non-zero exit, so getting here at all is the assertion.
      output = Fixture.mix!(["compile", "--warnings-as-errors"], disabled(ctx))

      # Deliberately any mention at all, case-insensitively: the point is that
      # a project which has opted out hears nothing, and a narrower assertion
      # would still pass against a build that announced itself differently.
      refute output =~ ~r/appup/i
      refute File.exists?(ctx.appup)
    end
  end

  defp compile!(ctx, extra \\ []), do: Fixture.mix!(["compile"], env(ctx, extra))

  defp env(%{build_root: build_root}, extra \\ []), do: [{"MIX_BUILD_ROOT", build_root} | extra]

  # `nil` is as close as the fixture can get to dropping the `:appup` key; the
  # compiler reads it through `Mix.Project.config()[:appup]`, which cannot tell
  # an absent key from one set to `nil`.
  defp disabled(ctx), do: env(ctx, [{"SAMPLE_APPUP", "none"}])

  # The workspace is memoised and shared with every other test in the run, so
  # this has to go back. Through `on_exit`, which runs even if the test times
  # out or the test process dies.
  defp delete_appup_source, do: with_restored_appup_source(&File.rm!/1)

  defp replace_appup_source(contents),
    do: with_restored_appup_source(&File.write!(&1, contents))

  defp with_restored_appup_source(fun) do
    src = Path.join(Fixture.workspace(), "appup.exs")
    original = File.read!(src)
    on_exit(fn -> File.write!(src, original) end)
    fun.(src)
  end
end
