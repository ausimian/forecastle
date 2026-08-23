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

  # Nothing here touches configuration. Mix decides which file configures a
  # release at runtime, initialises the providers a project declares, and writes
  # the `sys.config` its own launcher boots from - and all of that is left
  # exactly as Mix leaves it. Forecastle used to intercept the lot: it set
  # `runtime_config_path: false`, installed a substitute `Config.Reader` of its
  # own, rewrote every provider's init argument into a keyword list with an
  # `:env` key added, and renamed `sys.config` to `build.config` so that only
  # Castle could expand it at boot. That existed to give the version being
  # upgraded *to* a configuration resolved by its own providers, which
  # castle#13 now does properly, in a `:peer` running the target's own code, for
  # every version and by the only route Castle has left - there is no
  # `build.config` and nothing that would read one, so renaming what Mix wrote
  # would leave the standard launcher with no configuration to boot from.
  def pre_assemble(%Mix.Release{} = release) do
    release
    |> stage_relup()
    |> create_preboot_scripts()
  end

  def post_assemble(%Mix.Release{} = release) do
    release
    |> tap(&install_castle_cli/1)
    |> tap(&install_start_program/1)
    |> tap(&extend_env_script/1)
    |> tap(&copy_relfile/1)
    |> tap(&copy_relup/1)
    |> tap(&warn_unsupported_executables/1)
  end

  # Before `:assemble`, deliberately. Checking the relup afterwards meant a
  # stale one failed the build only once the version directory existed, and Mix
  # does not tidy up after a step of its own that raised. A corrected retry
  # without `--overwrite` then finds that directory, declines to overwrite it,
  # and exits 0 having assembled nothing - a worse outcome than the one the
  # check exists to prevent. The checked bytes are carried through so that what
  # lands in the release is exactly what was read and checked here.
  defp stage_relup(%Mix.Release{version: vsn, options: options} = release) do
    relup = project_relup()

    # Dropped unconditionally first. Mix keeps release options it does not
    # recognise, so a project that had set this key - for whatever reason -
    # would otherwise have its value written out as the release's upgrade plan
    # without any of this having looked at it.
    options = Keyword.delete(options, :forecastle_relup)

    if File.exists?(relup) do
      staged = relup |> verify_relup!(vsn) |> encode_relup()
      %Mix.Release{release | options: Keyword.put(options, :forecastle_relup, staged)}
    else
      %Mix.Release{release | options: options}
    end
  end

  defp project_relup do
    Mix.Project.project_file() |> Path.dirname() |> Path.join("relup")
  end

  # The script `Castle.Peer` boots. It is `start_clean` plus the applications
  # needed to run a release's own `Config.Provider` pipeline - and Castle - and
  # notably *not* the release's own applications, which must not be started a
  # second time in a VM that only exists to answer what the configuration is.
  # Its final `path` instruction is still the release's whole code path, so a
  # provider module belonging to one of those applications is loadable.
  #
  # It was written to expand configuration at boot, which is gone. It stays
  # because it is what the peer that replaced that expansion boots from, and it
  # has to be in the release being installed rather than in the one installing
  # it: only the target can say what the target's configuration is.
  defp create_preboot_scripts(%Mix.Release{boot_scripts: scripts} = release) do
    preboot =
      scripts[:start_clean]
      |> Keyword.merge(for app <- [:sasl, :compiler, :elixir, :castle], do: {app, :permanent})

    %Mix.Release{release | boot_scripts: Map.put(scripts, :preboot, preboot)}
  end

  defp install_castle_cli(%Mix.Release{path: path} = release) do
    if unix_executables?(release) do
      castle = Path.join([path, "bin", "castle"])
      File.write!(castle, render("castle.sh.eex", release))
      File.chmod!(castle, 0o755)
    end
  end

  # `bin/start` is the path `release_handler` hands to `heart:set_cmd/1` while
  # preparing an emulator restart, and it does nothing. The script itself says
  # why; what belongs here is why it is at *this* path.
  #
  # `init/1` resolves the start program as `{do_check, Configured}` when
  # `{sasl, start_prg}` is set and `{no_check, filename:join([Root, "bin",
  # "start"])}` otherwise, and `check_start_prg/2` returns the second
  # unexamined. So the default needs no configuration at all, whereas naming a
  # path of our own would mean injecting `:sasl` application configuration into
  # the release - which is exactly the interception
  # [#6](https://github.com/ausimian/forecastle/issues/6) removed and which
  # nothing here may reintroduce. `Root` is `code:root_dir()`, which for a Mix
  # release that brought its own ERTS is the release root; a release that did not
  # is refused by Castle's ERTS guard long before any of this.
  defp install_start_program(%Mix.Release{path: path} = release) do
    if unix_executables?(release) do
      start = Path.join([path, "bin", "start"])
      File.write!(start, render("start.sh.eex", release))
      File.chmod!(start, 0o755)
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

  # `bin/castle` is a POSIX shell script and is written only for a release that
  # asks for unix executables, so there is nothing on a Windows deployment to
  # drive an upgrade with. The .bat launcher itself does now boot - Mix writes
  # the `sys.config` it reads and expands configuration in the booting VM, which
  # it did not while Forecastle was withholding both - so what is missing is
  # release management rather than the release. Assembly succeeds either way, so
  # say so rather than let a deployment that cannot be upgraded leave the build
  # quietly.
  defp warn_unsupported_executables(%Mix.Release{} = release) do
    if :windows in executables_for(release) do
      Mix.shell().error(
        "warning: Forecastle does not support Windows releases. The .bat " <>
          "launcher this release includes will boot, but bin/castle is a POSIX " <>
          "shell script, so nothing on a Windows deployment can unpack, install " <>
          "or commit an upgrade. Set include_executables_for: [:unix] to stop " <>
          "building one."
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

  defp copy_relfile(%Mix.Release{name: name, version: vsn, path: path, version_path: vp}) do
    File.cp!(Path.join(vp, "#{name}.rel"), Path.join([path, "releases", "#{name}-#{vsn}.rel"]))
  end

  # Checked in `pre_assemble/1`, before Mix has created anything, so all that is
  # left here is to put the bytes that were checked into the release.
  # Re-emitted from the term that was checked rather than copied from the file
  # again: `:file.consult/1` reopens the path, and a `mix forecastle.relup`
  # running alongside the build can replace it in between, so a second read is
  # not necessarily the bytes that were checked. The format is the one
  # `systools` writes and `release_handler` reads - a UTF-8 coding comment and
  # a single term.
  defp encode_relup(plan) do
    case :unicode.characters_to_binary(:io_lib.format(~c"%% coding: utf-8~n~tp.~n", [plan])) do
      bytes when is_binary(bytes) -> bytes
      _not_encodable -> Mix.raise("#{project_relup()} cannot be encoded as UTF-8")
    end
  end

  defp copy_relup(%Mix.Release{options: options, version_path: vp}) do
    case Keyword.fetch(options, :forecastle_relup) do
      {:ok, bytes} -> File.write!(Path.join(vp, "relup"), bytes)
      :error -> :ok
    end
  end

  # The relup is produced by a separate `mix forecastle.relup` run, so nothing
  # about being here says it belongs to the release being assembled. Packaging
  # one for another version is worse than packaging none at all: nothing checks
  # it again, and `release_handler` applies it as this version's upgrade plan.
  # `mix forecastle.relup --outdir` makes that reachable - generation succeeds
  # elsewhere and an older relup is left sitting here - and so does anything that
  # left a partial one behind: the task itself publishes by renaming a staging
  # file over the relup, and so cannot, but a copy or an editor interrupted
  # partway through can. Fail the build instead.
  defp verify_relup!(relup, vsn) do
    wanted = to_charlist(vsn)

    case :file.consult(to_charlist(relup)) do
      # The outer contract `systools_make:check_relup/1` enforces when OTP packs
      # a tarball: one term, a non-empty version string, and list-valued upgrade
      # and downgrade sections. Mix packs its own tarball, so nothing applies
      # that check on the way into a release, and `release_handler` reaches
      # straight into those two lists during an upgrade. The pinned version is
      # a non-empty charlist by construction, so matching it covers the rest.
      {:ok, [{^wanted, up, down} = plan]} when is_list(up) and is_list(down) ->
        plan

      {:ok, [{[_ | _] = other, up, down}]} when is_list(up) and is_list(down) ->
        Mix.raise(
          "#{relup} is an upgrade plan for #{other}, but this release is #{vsn}. " <>
            "Generate the relup for #{vsn} into the project root, or remove the stale one."
        )

      {:ok, terms} ->
        Mix.raise(
          "#{relup} is not an upgrade plan. Expected a single {version, upgrade, " <>
            "downgrade} tuple with a version string and two lists, which is what " <>
            "systools writes and release_handler reads, but got: #{inspect(terms)}"
        )

      {:error, reason} ->
        Mix.raise("#{relup} could not be read as an upgrade plan: #{inspect(reason)}")
    end
  end
end
