defmodule Forecastle do
  @moduledoc """
  Documentation for `Forecastle`.
  """

  @app Mix.Project.config[:app]

  @spec steps(maybe_improper_list) :: maybe_improper_list
  def steps(tasks \\ [:assemble, :tar]) when is_list(tasks) do
    if idx = Enum.find_index(tasks, &match?(:assemble, &1)) do
      {pre, [:assemble | post]} = Enum.split(tasks, idx)
      pre ++ [&pre_assemble/1, :assemble, &post_assemble/1 | post]
    else
      tasks
    end
  end

  def pre_assemble(%Mix.Release{} = release) do
    release
    |> initialize()
    |> remove_runtime_configuration()
    |> remove_config_providers()
    |> create_preboot_scripts()
  end

  def post_assemble(%Mix.Release{} = release) do
    release
    |> tap(&add_config_providers/1)
    |> tap(&rename_sys_config/1)
    |> tap(&restructure_bin_dir/1)
    |> tap(&copy_runtime_exs/1)
    |> tap(&copy_relfile/1)
    |> tap(&copy_relup/1)
  end

  defp initialize(%Mix.Release{options: options} = release) do
    %Mix.Release{release | options: [{__MODULE__, []} | options]}
  end

  defp remove_runtime_configuration(%Mix.Release{options: options, version: vsn} = release) do
    runtime_exs = get_runtime_exs()

    if File.exists?(runtime_exs) do
      if Keyword.get(options, :runtime_config_path, true) do
        options =
          Keyword.update(options, __MODULE__, [], fn providers ->
            providers ++
              [
                {Config.Reader,
                 path: {:system, "RELEASE_ROOT", "/releases/#{vsn}/runtime.exs"}, env: Mix.env()}
              ]
          end)

        %Mix.Release{release | options: Keyword.put(options, :runtime_config_path, false)}
      end
    end || release
  end

  defp remove_config_providers(%Mix.Release{} = release) do
    providers =
      release.config_providers
      |> Enum.map(fn {mod, arg} -> if is_list(arg), do: {mod, arg}, else: {mod, path: arg} end)
      |> Enum.map(fn {mod, args} -> {mod, Keyword.put(args, :env, Mix.env())} end)

    options =
      Keyword.update(release.options, __MODULE__, [], fn existing ->
        existing ++ providers
      end)

    %Mix.Release{release | config_providers: [], options: options}
  end

  defp create_preboot_scripts(%Mix.Release{boot_scripts: scripts} = release) do
    preboot =
      scripts[:start_clean]
      |> Keyword.merge(for app <- [:sasl, :compiler, :elixir, :castle], do: {app, :permanent})

    %Mix.Release{release | boot_scripts: Map.put(scripts, :preboot, preboot)}
  end

  defp add_config_providers(%Mix.Release{options: options, version_path: vp}) do
    provider_states =
      for {mod, arg} <- Keyword.get(options, __MODULE__, []) do
        {mod, apply(mod, :init, [arg])}
      end

    sys_config_path = Path.join(vp, "sys.config")
    {:ok, [sys_config]} = :file.consult(to_charlist(sys_config_path))

    new_sys_config =
      Keyword.update(
        sys_config,
        :castle,
        [config_providers: provider_states],
        &Keyword.put(&1, :config_providers, provider_states)
      )

    File.write!(sys_config_path, :io_lib.format(~c"~tp.~n", [new_sys_config]))
  end

  defp rename_sys_config(%Mix.Release{version_path: vp}) do
    File.rename(Path.join(vp, "sys.config"), Path.join(vp, "build.config"))
  end

  defp restructure_bin_dir(%Mix.Release{name: name, path: path} = release) do
    bin_path = Path.join(path, "bin")
    invoked  = Path.join(bin_path, "#{name}")
    template = Path.join(:code.priv_dir(@app), "script.sh")
    File.write!(invoked, EEx.eval_file(template, release: release))
  end

  defp copy_runtime_exs(%Mix.Release{version_path: vp}) do
    runtime_exs = get_runtime_exs()

    if File.exists?(runtime_exs) do
      File.cp!(runtime_exs, Path.join(vp, "runtime.exs"))
    end
  end

  defp copy_relfile(%Mix.Release{name: name, version: vsn, path: path, version_path: vp}) do
    File.cp!(Path.join(vp, "#{name}.rel"), Path.join([path, "releases", "#{name}-#{vsn}.rel"]))
  end

  defp copy_relup(%Mix.Release{version_path: vp}) do
    relup =
      Mix.Project.project_file()
      |> Path.dirname()
      |> Path.join("relup")

    if File.exists?(relup) do
      File.cp!(relup, Path.join(vp, "relup"))
    end
  end

  defp get_runtime_exs do
    "../config/runtime.exs"
    |> Path.absname(Mix.Project.project_file())
    |> Path.expand()
  end
end
