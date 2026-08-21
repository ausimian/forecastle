defmodule ForecastleTest do
  use ExUnit.Case, async: true

  doctest Forecastle

  describe "steps/1" do
    test "wraps the assemble step" do
      assert [pre, :assemble, post, :tar] = Forecastle.steps()
      assert pre == (&Forecastle.pre_assemble/1)
      assert post == (&Forecastle.post_assemble/1)
    end

    test "preserves the caller's own steps around the injected ones" do
      before_step = fn release -> release end
      after_step = fn release -> release end

      assert [^before_step, pre, :assemble, post, :tar, ^after_step] =
               Forecastle.steps([before_step, :assemble, :tar, after_step])

      assert pre == (&Forecastle.pre_assemble/1)
      assert post == (&Forecastle.post_assemble/1)
    end

    test "is a no-op when there is no assemble step" do
      assert Forecastle.steps([:tar]) == [:tar]
    end
  end

  describe "pre_assemble/1" do
    setup do
      release = %Mix.Release{
        name: :sample,
        version: "1.2.3",
        config_providers: [{Config.Reader, "/nowhere/provider.exs"}],
        boot_scripts: %{start_clean: [kernel: :permanent, stdlib: :permanent]},
        options: []
      }

      {:ok, release: Forecastle.pre_assemble(release)}
    end

    test "refuses to carry a staged relup it did not stage itself" do
      # Mix keeps release options it does not recognise, so without dropping
      # this key first a project that had set it would have had its value
      # written out as the release's upgrade plan, unchecked. A release of its
      # own rather than the one from setup: what is under test is what
      # pre_assemble does with an option it finds already there.
      refute File.exists?(Path.join(File.cwd!(), "relup")),
             "this test assumes the project has no relup of its own"

      release = %Mix.Release{
        name: :sample,
        version: "1.2.3",
        config_providers: [],
        boot_scripts: %{start_clean: [kernel: :permanent, stdlib: :permanent]},
        options: [forecastle_relup: "not a plan"]
      }

      options = release |> Forecastle.pre_assemble() |> Map.fetch!(:options)

      assert Keyword.fetch(options, :forecastle_relup) == :error
    end

    test "takes the config providers away from Mix", %{release: release} do
      assert release.config_providers == []
    end

    test "stashes the config providers for post-assembly", %{release: release} do
      assert [{Config.Reader, args}] = release.options[Forecastle]
      assert args[:path] == "/nowhere/provider.exs"
      assert args[:env] == Mix.env()
    end

    test "adds a preboot script that can start Castle", %{release: release} do
      preboot = release.boot_scripts[:preboot]

      assert preboot[:kernel] == :permanent
      assert preboot[:stdlib] == :permanent

      for app <- [:sasl, :compiler, :elixir, :castle] do
        assert preboot[app] == :permanent, "expected #{app} in the preboot script"
      end
    end

    test "leaves the start_clean script alone", %{release: release} do
      assert release.boot_scripts[:start_clean] == [kernel: :permanent, stdlib: :permanent]
    end

    test "leaves runtime config evaluation alone when there is no runtime.exs",
         %{release: release} do
      # Forecastle's own project has no config/runtime.exs, so the option that
      # disables Mix's evaluation of it must not have been set.
      refute Keyword.has_key?(release.options, :runtime_config_path)
    end
  end
end
