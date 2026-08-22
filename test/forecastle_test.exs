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

      {:ok, release: release, assembled: Forecastle.pre_assemble(release)}
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

    test "leaves the config providers with Mix", %{release: release, assembled: assembled} do
      # They used to be taken away here and replayed into the release's
      # configuration afterwards, with their init arguments rewritten into a
      # keyword list on the way through. Mix initialises them itself, with
      # whatever term the project declared, and nothing here has an opinion.
      assert assembled.config_providers == release.config_providers
    end

    test "says nothing about runtime configuration", %{assembled: assembled} do
      # Setting :runtime_config_path to false is what used to stop Mix expanding
      # runtime configuration at all, so that Castle could do it at boot instead.
      refute Keyword.has_key?(assembled.options, :runtime_config_path)
    end

    test "stashes nothing under its own key", %{assembled: assembled} do
      # The accumulator the stripped providers were collected in. Nothing reads
      # it any more, so nothing may write it either: Mix carries release options
      # it does not recognise straight into the assembled release.
      refute Keyword.has_key?(assembled.options, Forecastle)
    end

    test "adds a preboot script that can start Castle", %{assembled: assembled} do
      # The script Castle's peer boots to work out the configuration of the
      # version being installed.
      preboot = assembled.boot_scripts[:preboot]

      assert preboot[:kernel] == :permanent
      assert preboot[:stdlib] == :permanent

      for app <- [:sasl, :compiler, :elixir, :castle] do
        assert preboot[app] == :permanent, "expected #{app} in the preboot script"
      end
    end

    test "leaves the start_clean script alone", %{assembled: assembled} do
      assert assembled.boot_scripts[:start_clean] == [kernel: :permanent, stdlib: :permanent]
    end
  end
end
