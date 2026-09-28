defmodule Mix.Tasks.Test.Parallel do
  @shortdoc "Runs the test files across concurrent mix test workers"

  @moduledoc """
  Runs the test suite as several `mix test` processes at once.

      mix test.parallel [--workers <n>] [mix test options]

  Everything except `--workers` is handed to every `mix test` unchanged, so
  `mix test.parallel --include e2e` is the whole suite. Test files are chosen by
  the task rather than passed in; to run one file, use `mix test`. The number of
  workers defaults to the number of schedulers, which is the number of cores.

  **Why.** Nearly all of the suite is synchronous. The assembling suites shell
  out to `mix release` against one shared fixture workspace, and the end-to-end
  suites boot the release it produces, so none of them can be `async: true`, and
  a plain `mix test` runs them one module at a time on one core.

  **What keeps it sound.** A worker is a series of separate operating-system
  processes that all carry the same `MIX_TEST_PARTITION`, and
  `Forecastle.Fixture` gives each partition number a workspace and a
  distribution port of its own. So two workers share no state. Within one worker
  the files run one after another, in one workspace, exactly as they do under a
  plain `mix test`. What this does not share with a plain `mix test` is the
  order: the modules of one file still run in ExUnit's random order, but which
  files follow which in a workspace is decided here.

  **Scheduling.** Files are taken from one queue, largest first, by whichever
  worker is free. Size is only a rough stand-in for duration, but a queue lets a
  worker that drew fast files go back for more. Mix's own `--partitions` splits
  files round-robin up front, which left one partition running for twice as
  long as another.

  Each file's output is printed whole when it finishes, so two files never
  interleave. The task ends with the time each file took and exits non-zero if
  any file failed.

  This is test support rather than part of the package: it is compiled only in
  the test environment, and `mix.exs` makes that the task's preferred one.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {workers, test_args} = workers(args, [])

    # Compiled once here rather than by every worker at the same moment.
    Mix.Task.run("compile")

    mix = System.find_executable("mix") || Mix.raise("could not find mix on the PATH")
    files = test_files()
    workers = min(workers, length(files))
    {:ok, queue} = Agent.start_link(fn -> files end)
    started = System.monotonic_time(:millisecond)

    Mix.shell().info("Running #{length(files)} test files on #{workers} workers")

    results =
      1..workers//1
      |> Task.async_stream(&drain(queue, mix, &1, test_args, []),
        max_concurrency: workers,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, results} -> results end)

    summarise(results, div(System.monotonic_time(:millisecond) - started, 1000))
  end

  defp workers(["--workers", n | rest], acc) do
    case Integer.parse(n) do
      {n, ""} when n > 0 -> {n, Enum.reverse(acc, rest)}
      _ -> Mix.raise("--workers expects a positive integer, got: #{inspect(n)}")
    end
  end

  defp workers([arg | rest], acc), do: workers(rest, [arg | acc])
  defp workers([], acc), do: {System.schedulers_online(), Enum.reverse(acc)}

  # The files `mix test` would run with no paths given, largest first.
  defp test_files do
    config = Mix.Project.config()
    ignore = config[:test_ignore_filters] || []

    (config[:test_paths] || ["test"])
    |> Mix.Utils.extract_files(config[:test_pattern] || "*_test.exs")
    |> Enum.reject(fn file -> Enum.any?(ignore, &ignored?(&1, file)) end)
    |> Enum.sort_by(&{-File.stat!(&1).size, &1})
  end

  defp ignored?(%Regex{} = regex, file), do: Regex.match?(regex, file)
  defp ignored?(fun, file) when is_function(fun, 1), do: fun.(file)
  defp ignored?(path, file) when is_binary(path), do: path == file

  defp drain(queue, mix, worker, test_args, acc) do
    case Agent.get_and_update(queue, &take/1) do
      nil -> acc
      file -> drain(queue, mix, worker, test_args, [run_file(mix, worker, file, test_args) | acc])
    end
  end

  defp take([]), do: {nil, []}
  defp take([file | rest]), do: {file, rest}

  defp run_file(mix, worker, file, test_args) do
    started = System.monotonic_time(:millisecond)

    {output, status} =
      System.cmd(mix, ["test", file | test_args],
        env: [{"MIX_ENV", "test"}, {"MIX_TEST_PARTITION", Integer.to_string(worker)}],
        stderr_to_stdout: true
      )

    elapsed = div(System.monotonic_time(:millisecond) - started, 1000)

    Mix.shell().info("""

    ==> #{file} (worker #{worker}): exited #{status} after #{elapsed}s

    #{output}\
    """)

    {file, status, elapsed}
  end

  defp summarise(results, elapsed) do
    timings =
      results
      |> Enum.sort_by(fn {_file, _status, seconds} -> -seconds end)
      |> Enum.map_join("\n", fn {file, status, seconds} ->
        "  #{String.pad_leading(Integer.to_string(seconds), 4)}s  #{file}" <>
          if(status == 0, do: "", else: "  (exited #{status})")
      end)

    Mix.shell().info("\nTime per test file:\n\n#{timings}\n")

    case Enum.reject(results, fn {_file, status, _seconds} -> status == 0 end) do
      [] ->
        Mix.shell().info("All #{length(results)} test files passed in #{elapsed}s")

      failed ->
        Mix.raise(
          "#{length(failed)} of #{length(results)} test files failed, in #{elapsed}s: " <>
            Enum.map_join(failed, ", ", &elem(&1, 0))
        )
    end
  end
end
