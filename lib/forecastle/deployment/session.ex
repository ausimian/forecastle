defmodule Forecastle.Deployment.Session do
  @moduledoc false

  use GenServer

  alias Forecastle.Deployment

  @enforce_keys [:server, :stop_timeout]
  defstruct [:server, :stop_timeout]

  @opaque t :: %__MODULE__{server: pid(), stop_timeout: timeout()}

  @call_timeout 5_000
  @launcher_timeout 180_000
  @install_timeout 300_000
  @shutdown_timeout 10_000
  @exit_timeout 30_000
  @exit_interval 100

  def start(%Deployment{} = deployment, opts) do
    with {:ok, server} <- GenServer.start(__MODULE__, {deployment, opts}) do
      shutdown_timeout = Keyword.get(opts, :shutdown_timeout, @shutdown_timeout)
      {:ok, %__MODULE__{server: server, stop_timeout: shutdown_timeout + 1_000}}
    end
  end

  def stop(%__MODULE__{server: server, stop_timeout: timeout}) do
    if Process.alive?(server), do: GenServer.stop(server, :normal, timeout), else: :ok
  catch
    :exit, {:timeout, _call} -> :timeout
    :exit, {:noproc, _call} -> :ok
    :exit, _reason -> :timeout
  end

  def call(%__MODULE__{server: server}, module, function, args, timeout) do
    GenServer.call(server, {:call, module, function, args, timeout}, :infinity)
  catch
    :exit, reason ->
      {:error,
       "deployment session stopped while calling #{inspect(module)}.#{function}/#{length(args)}: #{inspect(reason)}"}
  end

  def operation(%__MODULE__{server: server}, operation) do
    GenServer.call(server, {:operation, operation}, :infinity)
  catch
    :exit, reason ->
      {:error,
       "deployment session stopped during #{operation_name(operation)}: #{inspect(reason)}"}
  end

  def install(%__MODULE__{server: server}, vsn) do
    GenServer.call(server, {:install, vsn}, :infinity)
  catch
    :exit, reason ->
      {:error, "deployment session stopped while installing #{vsn}: #{inspect(reason)}"}
  end

  def restart(%__MODULE__{server: server}) do
    GenServer.call(server, :restart, :infinity)
  catch
    :exit, reason -> {:error, "deployment session stopped while restarting: #{inspect(reason)}"}
  end

  @impl true
  def init({deployment, opts}) do
    Process.flag(:trap_exit, true)

    state = %{
      deployment: deployment,
      env: Keyword.get(opts, :env, []),
      call_timeout: Keyword.get(opts, :call_timeout, @call_timeout),
      launcher_timeout: Keyword.get(opts, :launcher_timeout, @launcher_timeout),
      install_timeout: Keyword.get(opts, :install_timeout, @install_timeout),
      shutdown_timeout: Keyword.get(opts, :shutdown_timeout, @shutdown_timeout),
      exit_timeout: Keyword.get(opts, :exit_timeout, @exit_timeout),
      peer: nil,
      os_pid: nil,
      last_os_pid: nil,
      down: nil,
      install: nil
    }

    case start_peer(state) do
      {:ok, state} -> {:ok, state}
      {:error, message} -> {:stop, message}
    end
  end

  @impl true
  def handle_call({:call, module, function, args, timeout}, _from, state) do
    {:reply, peer_call(state, module, function, args, timeout), state}
  end

  def handle_call({:operation, operation}, _from, %{down: reason} = state)
      when not is_nil(reason) do
    {:reply,
     {:error,
      "cannot run #{operation_name(operation)} in #{state.deployment.root}: " <>
        "the session is unusable after #{inspect(reason)}"}, state}
  end

  def handle_call({:operation, operation}, _from, state) do
    {:reply, run_operation(state, operation), state}
  end

  def handle_call({:install, vsn}, _from, %{down: reason} = state) when not is_nil(reason) do
    {:reply,
     {:error,
      "cannot install #{vsn} in #{state.deployment.root}: " <>
        "the session is unusable after #{inspect(reason)}"}, state}
  end

  def handle_call({:install, _vsn}, _from, %{install: install} = state)
      when not is_nil(install) do
    {:reply, {:error, "another install is already running in #{state.deployment.root}"}, state}
  end

  def handle_call({:install, vsn}, from, state) when is_binary(vsn) do
    task = Task.async(fn -> Deployment.castle(state.deployment, ["install", vsn], state.env) end)
    timer = Process.send_after(self(), {:install_timeout, task.ref}, state.install_timeout)

    install = %{
      from: from,
      task: task,
      timer: timer,
      vsn: vsn,
      old_os_pid: state.os_pid
    }

    {:noreply, %{state | install: install}}
  end

  def handle_call(:restart, _from, %{install: install} = state) when not is_nil(install) do
    {:reply, {:error, "cannot restart #{state.deployment.root} while an install is running"},
     state}
  end

  def handle_call(:restart, _from, %{down: :install_timeout} = state) do
    {:reply,
     {:error,
      "cannot restart #{state.deployment.root}: the session is unusable after an install timeout"},
     state}
  end

  def handle_call(:restart, _from, state) do
    old_peer = state.peer
    old_pid = state.os_pid || state.last_os_pid
    stop_peer(old_peer)

    with :ok <- await_exit(old_pid, state.exit_timeout),
         {:ok, restarted} <-
           start_peer(%{state | peer: nil, os_pid: nil, last_os_pid: nil, down: nil}) do
      {:reply, {:ok, :restarted}, restarted}
    else
      {:error, message} ->
        {:reply, {:error, message},
         %{state | peer: nil, os_pid: nil, last_os_pid: old_pid, down: message}}
    end
  end

  @impl true
  def handle_info({ref, {output, status}}, %{install: %{task: %{ref: ref}} = install} = state) do
    Process.demonitor(ref, [:flush])
    cancel_timer(install)

    reply =
      if status == 0 do
        {:ok, output}
      else
        {:error, "bin/castle install #{install.vsn} exited with #{status}\n\n#{output}"}
      end

    GenServer.reply(install.from, reply)
    {:noreply, %{state | install: nil}}
  end

  def handle_info({:install_timeout, ref}, %{install: %{task: %{ref: ref}} = install} = state) do
    diagnosis = install_diagnosis(install)

    GenServer.reply(
      install.from,
      {:error,
       "bin/castle install #{install.vsn} did not finish within #{state.install_timeout}ms in " <>
         state.deployment.root <> diagnosis}
    )

    {:noreply, %{state | install: nil, down: :install_timeout}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{install: %{task: %{ref: ref}} = install} = state
      ) do
    cancel_timer(install)

    GenServer.reply(
      install.from,
      {:error, "bin/castle install #{install.vsn} could not be run: #{inspect(reason)}"}
    )

    {:noreply, %{state | install: nil}}
  end

  def handle_info({:EXIT, peer, reason}, %{peer: peer, install: nil} = state) do
    {:noreply, %{state | peer: nil, os_pid: nil, last_os_pid: state.os_pid, down: reason}}
  end

  def handle_info({:EXIT, peer, reason}, %{peer: peer, install: install} = state) do
    case expected_reboot(state.deployment, install.vsn) do
      :ok ->
        with :ok <- await_exit(install.old_os_pid, state.exit_timeout),
             {:ok, restarted} <-
               start_peer(%{state | peer: nil, os_pid: nil, last_os_pid: nil, down: nil}) do
          {:noreply, %{restarted | install: install}}
        else
          {:error, message} -> fail_install(state, message)
        end

      {:error, why} ->
        fail_install(
          state,
          "the peer running #{state.deployment.root} exited during install (#{inspect(reason)}), " <>
            "but no matching restart evidence was present: #{why}"
        )
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.install, do: Task.shutdown(state.install.task, :brutal_kill)
    stop_peer(state.peer)
    :ok
  end

  defp start_peer(state) do
    deployment = state.deployment
    {env, unset} = peer_env(deployment.env ++ state.env)
    adapter = Path.join(:code.priv_dir(:forecastle), "peer.sh")
    shell = System.find_executable("sh") || "/bin/sh"
    launcher = Path.join(deployment.root, "bin/#{deployment.name}")
    work = peer_work_dir(deployment)
    peer_args = Path.join(work, "peer.args")

    options = %{
      connection: {{127, 0, 0, 1}, 0},
      exec: {to_charlist(shell), [to_charlist(adapter)]},
      post_process_args: fn [_adapter | args] ->
        File.write!(peer_args, Enum.join(args, "\n") <> "\n")
        File.chmod!(peer_args, 0o600)

        [adapter, launcher, Enum.join(unset, ","), work]
        |> Enum.map(&to_charlist/1)
      end,
      env: Enum.map(env, fn {name, value} -> {to_charlist(name), to_charlist(value)} end),
      wait_boot: state.launcher_timeout + deployment.boot_timeout,
      shutdown: {:halt, state.shutdown_timeout},
      peer_down: :stop
    }

    try do
      case :peer.start_link(options) do
        {:ok, peer} ->
          peer_started(peer, state)

        {:ok, peer, _node} ->
          peer_started(peer, state)

        {:error, reason} ->
          {:error,
           "#{deployment.root} did not boot through its stock launcher within " <>
             "#{state.launcher_timeout + deployment.boot_timeout}ms: #{inspect(reason)}"}
      end
    after
      File.rm_rf(work)
    end
  catch
    kind, reason ->
      {:error,
       "#{state.deployment.root} could not be booted through its stock launcher: " <>
         Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp peer_started(peer, state) do
    case safe_call(peer, System, :pid, [], state.call_timeout) do
      {:ok, os_pid} ->
        {:ok, %{state | peer: peer, os_pid: os_pid, last_os_pid: nil, down: nil}}

      {:error, message} ->
        stop_peer(peer)

        {:error,
         "#{state.deployment.root} booted but did not report its operating-system pid: #{message}"}
    end
  end

  defp peer_call(
         %{deployment: deployment, down: reason},
         module,
         function,
         args,
         _timeout
       )
       when not is_nil(reason) do
    {:error,
     "cannot call #{inspect(module)}.#{function}/#{length(args)} in #{deployment.root}: " <>
       "the session is unusable after #{inspect(reason)}"}
  end

  defp peer_call(state, module, function, args, timeout) do
    safe_call(state.peer, module, function, args, timeout)
  end

  defp safe_call(peer, module, function, args, timeout) do
    {:ok, :peer.call(peer, module, function, args, timeout)}
  catch
    :exit, {:timeout, _} ->
      {:error,
       "#{inspect(module)}.#{function}/#{length(args)} did not answer within #{timeout}ms"}

    kind, reason ->
      {:error,
       "#{inspect(module)}.#{function}/#{length(args)} failed: " <>
         Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp run_operation(state, {:stage, tarball}),
    do: {:ok, Deployment.stage!(state.deployment, tarball)}

  defp run_operation(state, :version), do: {:ok, Deployment.version(state.deployment)}
  defp run_operation(state, :os_pid), do: {:ok, state.os_pid}

  defp run_operation(state, {:castle, args, env}) do
    case Deployment.castle(state.deployment, args, state.env ++ env) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        {:error, "castle #{Enum.join(args, " ")} exited with #{status}\n\n#{output}"}
    end
  end

  defp run_operation(state, {:launcher, args, env}) do
    case Deployment.launcher(state.deployment, args, state.env ++ env) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, status} ->
        {:error,
         "#{state.deployment.name} #{Enum.join(args, " ")} exited with #{status}\n\n#{output}"}
    end
  end

  defp expected_reboot(deployment, vsn) do
    pending = Path.join(deployment.root, "releases/castle-restart-pending")
    provisional = Path.join(deployment.root, "releases/new_start_erl.data")

    with {:ok, pending_vsn} <- first_line(pending),
         {:ok, provisional_line} <- first_line(provisional),
         [_erts, provisional_vsn] <- String.split(provisional_line, " ", parts: 2),
         true <- pending_vsn == vsn and provisional_vsn == vsn do
      :ok
    else
      _ -> {:error, "#{pending} and #{provisional} do not both name #{inspect(vsn)}"}
    end
  end

  defp first_line(path) do
    with {:ok, bytes} <- File.read(path), [line | _] <- String.split(bytes, "\n") do
      {:ok, line}
    else
      _ -> {:error, path}
    end
  end

  defp fail_install(state, message) do
    install = state.install
    diagnosis = install_diagnosis(install)
    cancel_timer(install)
    GenServer.reply(install.from, {:error, message <> diagnosis})

    {:noreply,
     %{
       state
       | install: nil,
         peer: nil,
         os_pid: nil,
         last_os_pid: state.os_pid,
         down: message
     }}
  end

  defp install_diagnosis(install) do
    result = Task.yield(install.task, 100) || Task.shutdown(install.task, :brutal_kill)

    case result do
      {:ok, {output, status}} ->
        "\n\nbin/castle install exited with #{status}:\n\n#{output}"

      {:exit, reason} ->
        "\n\nbin/castle install task exited: #{inspect(reason)}"

      nil ->
        "\n\nbin/castle install had not exited; its operating-system process may still be running."
    end
  end

  defp cancel_timer(install) do
    if Process.cancel_timer(install.timer) == false do
      receive do
        {:install_timeout, ref} when ref == install.task.ref -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp await_exit(nil, _timeout), do: :ok

  defp await_exit(pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_exit(pid, timeout, deadline)
  end

  defp await_exit(pid, timeout, deadline) do
    case System.cmd("ps", ["-o", "pid=", "-p", pid], stderr_to_stdout: true) do
      {_output, 0} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@exit_interval)
          await_exit(pid, timeout, deadline)
        else
          {:error, "process #{pid} was still running #{timeout}ms later"}
        end

      _ ->
        :ok
    end
  end

  defp stop_peer(nil), do: :ok

  defp stop_peer(peer) do
    :peer.stop(peer)
  catch
    :exit, _reason -> :ok
  end

  defp peer_env(extra) do
    extra
    |> Deployment.scrubbed_env()
    |> Enum.reduce(%{}, fn {name, value}, env -> Map.put(env, name, value) end)
    |> Enum.split_with(fn {_name, value} -> is_nil(value) end)
    |> then(fn {unset, set} ->
      {Enum.map(set, fn {name, value} -> {name, value} end), Enum.map(unset, &elem(&1, 0))}
    end)
  end

  defp peer_work_dir(deployment) do
    parent = Path.join(deployment.root, "tmp")
    File.mkdir_p!(parent)
    work = Path.join(parent, "forecastle-peer-#{System.unique_integer([:positive])}")
    File.mkdir!(work)
    File.chmod!(work, 0o700)

    if File.ls!(work) != [] do
      raise "peer working directory was not empty after it was made: #{work}"
    end

    work
  end

  defp operation_name({name, _args}), do: name
  defp operation_name(operation), do: operation
end
