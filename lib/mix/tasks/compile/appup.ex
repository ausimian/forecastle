defmodule Mix.Tasks.Compile.Appup do
  @moduledoc """
  Compiles appup files into the application's ebin folder.

  The `:appup` project key names a file, relative to the project file, that is
  evaluated for its value. It must not introduce top-level bindings. Whatever it
  returns is written to `<app>.appup` alongside the application's beams.

  The output is removed again whenever the project stops asking for it, either
  because the source is gone or because the `:appup` key was dropped. Leaving it
  in place would let an incremental build - which is what a CI cache produces -
  ship upgrade instructions from an earlier version of the application, and
  `release_handler` would then apply that obsolete plan during a hot upgrade.

  A configured but missing source is a compilation error: the project asked for
  an appup and cannot have one, and the alternative is a release that only fails
  later, in `:systools.make_relup/4` or during the upgrade itself.
  """
  @shortdoc "Compiles appup files"
  use Mix.Task.Compiler

  @recursive true

  @impl true
  def run(_args) do
    dst = destination()

    case source() do
      nil -> discard(dst, report(:warning, "No appup specified in project"))
      src -> build(src, dst)
    end
  end

  # `mix clean` also removes the application's whole build directory, so the
  # appup goes with it either way. This is the callback the behaviour asks any
  # compiler that writes output to define, and it keeps removing the artefact
  # the responsibility of the task that created it.
  @impl true
  def clean do
    _ = File.rm(destination())
    :ok
  end

  # No manifests/0: the appup is regenerated on every build, so its timestamp
  # always advances, and advertising it as a manifest would tell everything that
  # consults `Mix.Task.Compiler.manifests/1` that the build changed every time.
  # Regenerating unconditionally is deliberate - the source is arbitrary code
  # whose result need not be a function of the source's own mtime.

  defp build(src, dst) do
    if File.exists?(src) do
      write(src, dst)
    else
      abort(discard(dst, report(:error, "Appup file not found: #{src}")))
    end
  end

  defp write(src, dst) do
    {appup, []} = Code.eval_file(src)

    case File.write(dst, :io_lib.format(~c"~tp.~n", [appup])) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, report(:error, "Could not write #{dst}: #{:file.format_error(reason)}")}
    end
  end

  # Removes an earlier build's output, carrying whatever diagnostic explains why
  # the project no longer wants one. Leaving the output behind is the whole bug,
  # so failing to remove it is a compilation error in its own right. `:noop`
  # only when there was nothing there, so that a project which never had an
  # appup does not report work on every compile.
  defp discard(dst, diagnostics) do
    case File.rm(dst) do
      :ok ->
        {:ok, diagnostics}

      {:error, :enoent} ->
        {:noop, diagnostics}

      {:error, reason} ->
        failure = report(:error, "Could not remove #{dst}: #{:file.format_error(reason)}")
        {:error, diagnostics ++ failure}
    end
  end

  # The project asked for an appup and cannot have one, whatever removing the
  # previous one had to say about it.
  defp abort({_status, diagnostics}), do: {:error, diagnostics}

  # Relative to the project file rather than the working directory. The compiler
  # is recursive, so Mix runs it from each umbrella child's own directory, but
  # nothing guarantees the working directory for a `mix compile` invoked from
  # elsewhere - and the answer now decides whether the output is deleted.
  defp source do
    if src = Mix.Project.config()[:appup] do
      Path.expand(src, Path.dirname(Mix.Project.project_file()))
    end
  end

  defp destination do
    Path.join(Mix.Project.compile_path(), "#{Mix.Project.config()[:app]}.appup")
  end

  # Diagnostics returned from a compiler are for editors to display inline;
  # nothing on the command line prints them, and a compiler that fails without
  # saying why is worse than one that does not fail at all. Say it on stderr as
  # well, the way the rest of Forecastle reports build problems.
  defp report(severity, message) do
    Mix.shell().error("#{severity}: #{message}")
    [diagnostic(severity, message)]
  end

  defp diagnostic(severity, message) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "Appup",
      file: Mix.Project.project_file(),
      position: nil,
      severity: severity,
      message: message
    }
  end
end
