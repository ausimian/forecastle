defmodule Forecastle do
  @moduledoc """
  Documentation for `Forecastle`.
  """

  @app Mix.Project.config()[:app]

  @spec steps(maybe_improper_list) :: maybe_improper_list
  def steps(tasks \\ [:assemble, :tar]) when is_list(tasks) do
    if idx = Enum.find_index(tasks, &match?(:assemble, &1)) do
      {pre, [:assemble | post]} = Enum.split(tasks, idx)
      pre ++ [&__MODULE__.pre_assemble/1, :assemble, (&__MODULE__.post_assemble/1) | post]
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
    |> tap(&install_castle_cli/1)
    |> tap(&extend_env_script/1)
    |> tap(&copy_runtime_exs/1)
    |> tap(&copy_relfile/1)
    |> tap(&copy_relup/1)
    |> tap(&warn_unsupported_executables/1)
  end

  defp initialize(%Mix.Release{options: options} = release) do
    %Mix.Release{release | options: [{__MODULE__, []} | options]}
  end

  defp remove_runtime_configuration(%Mix.Release{options: options, version: vsn} = release) do
    if File.exists?(get_runtime_exs()) and Keyword.get(options, :runtime_config_path, true) do
      options =
        options
        |> Keyword.update(__MODULE__, [], &(&1 ++ [runtime_config_provider(vsn)]))
        |> Keyword.put(:runtime_config_path, false)

      %Mix.Release{release | options: options}
    else
      release
    end
  end

  defp runtime_config_provider(vsn) do
    {Config.Reader,
     path: {:system, "RELEASE_ROOT", "/releases/#{vsn}/runtime.exs"}, env: Mix.env()}
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
        {mod, mod.init(arg)}
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

  defp install_castle_cli(%Mix.Release{path: path} = release) do
    if unix_executables?(release) do
      castle = Path.join([path, "bin", "castle"])
      File.write!(castle, render("castle.sh.eex", release))
      File.chmod!(castle, 0o755)
    end
  end

  defp extend_env_script(%Mix.Release{version_path: vp} = release) do
    env_sh = Path.join(vp, "env.sh")

    if unix_executables?(release) and File.exists?(env_sh) do
      File.write!(env_sh, render("env.sh.eex", release), [:append])
    end
  end

  defp unix_executables?(%Mix.Release{} = release) do
    :unix in executables_for(release)
  end

  # Configuration is withheld from Mix and expanded at boot instead, and the
  # integration that expands it is installed into env.sh. There is no env.bat
  # equivalent, so a Windows launcher looks for a sys.config that nothing
  # creates. That has always been true, and assembly still succeeds, so say so
  # rather than let a release that cannot boot leave the build quietly.
  defp warn_unsupported_executables(%Mix.Release{} = release) do
    if :windows in executables_for(release) do
      Mix.shell().error(
        "warning: Forecastle does not support Windows releases, and the .bat " <>
          "launcher this release includes will not boot. Set " <>
          "include_executables_for: [:unix] to stop building one."
      )
    end
  end

  defp executables_for(%Mix.Release{options: options}) do
    Keyword.get(options, :include_executables_for, [:unix, :windows])
  end

  defp render(template, %Mix.Release{} = release) do
    @app
    |> :code.priv_dir()
    |> Path.join(template)
    |> EEx.eval_file(release: release)
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

  defp copy_relup(%Mix.Release{version: vsn, version_path: vp}) do
    relup =
      Mix.Project.project_file()
      |> Path.dirname()
      |> Path.join("relup")

    if File.exists?(relup) do
      verify_relup!(relup, vsn)
      File.cp!(relup, Path.join(vp, "relup"))
    end
  end

  # The relup is produced by a separate `mix forecastle.relup` run, so nothing
  # about being here says it belongs to the release being assembled. Packaging
  # one for another version is worse than packaging none at all: nothing checks
  # it again, and `release_handler` applies it as this version's upgrade plan.
  # `mix forecastle.relup --outdir` makes that reachable - generation succeeds
  # elsewhere and an older relup is left sitting here - and so does a write
  # interrupted partway through. Fail the build instead.
  defp verify_relup!(relup, vsn) do
    wanted = to_charlist(vsn)

    case :file.consult(to_charlist(relup)) do
      {:ok, [{^wanted, _up, _down}]} ->
        :ok

      {:ok, [{other, _up, _down}]} ->
        Mix.raise(
          "#{relup} is an upgrade plan for #{other}, but this release is #{vsn}. " <>
            "Generate the relup for #{vsn} into the project root, or remove the stale one."
        )

      {:ok, terms} ->
        Mix.raise("#{relup} is not an upgrade plan: #{inspect(terms)}")

      {:error, reason} ->
        Mix.raise("#{relup} could not be read as an upgrade plan: #{inspect(reason)}")
    end
  end

  defp get_runtime_exs do
    "../config/runtime.exs"
    |> Path.absname(Mix.Project.project_file())
    |> Path.expand()
  end
end
