defmodule Forecastle.Deployment.Session do
  @moduledoc false

  use GenServer

  alias Forecastle.Deployment

  @enforce_keys [:server, :stop_timeout, :deployment]
  defstruct [:server, :stop_timeout, :deployment, :env_store, :exit_timeout]

  @opaque t :: %__MODULE__{
            server: pid(),
            stop_timeout: timeout(),
            deployment: Deployment.t(),
            env_store: pid(),
            exit_timeout: timeout()
          }

  @call_timeout 5_000
  @launcher_timeout 180_000
  @command_timeout 30_000
  @install_timeout 300_000
  @install_slack 5_000
  @shutdown_timeout 10_000
  @fallback_timeout 10_000
  @stop_slack 5_000
  @exit_timeout 30_000
  @exit_interval 100
  @boot_interval 50

  def start(%Deployment{} = deployment, opts) do
    with {:ok, env_store} <- Agent.start(fn -> new_store(Keyword.get(opts, :env, [])) end) do
      opts = Keyword.put(opts, :env_store, env_store)

      case GenServer.start(__MODULE__, {deployment, opts}) do
        {:ok, server} ->
          exit_timeout = Keyword.get(opts, :exit_timeout, @exit_timeout)

          {:ok,
           %__MODULE__{
             server: server,
             stop_timeout: stop_timeout(deployment, opts),
             deployment: deployment,
             env_store: env_store,
             exit_timeout: exit_timeout
           }}

        {:error, reason} ->
          stop_env_store(env_store)
          {:error, reason}
      end
    end
  end

  def stop(%__MODULE__{} = session) do
    {_env, os_pid} = fallback_details(session.env_store)

    result =
      case claim_stop(session.env_store) do
        :claimed -> finish_stop(session)
        :stopped -> :ok
        :unavailable -> finish_stop(session)
        {:waiting, owner} -> await_stop(session, owner)
      end

    report_stop_result(session, result, os_pid)
    result
  catch
    kind, reason ->
      release_stop(session.env_store)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp finish_stop(session) do
    result = stop_server(session)

    if result in [:ok, :killed] do
      complete_stop(session.env_store)
    else
      release_stop(session.env_store)
    end

    result
  end

  defp await_stop(session, owner) do
    deadline = System.monotonic_time(:millisecond) + session.stop_timeout
    await_stop(session, owner, deadline)
  end

  defp await_stop(session, owner, deadline) do
    case stop_status(session.env_store) do
      :stopped -> :ok
      :active -> stop(session)
      :unavailable -> finish_stop(session)
      {:stopping, current_owner} -> await_stop_owner(session, owner, current_owner, deadline)
    end
  end

  defp await_stop_owner(session, owner, current_owner, deadline) when current_owner != owner,
    do: await_stop(session, current_owner, deadline)

  defp await_stop_owner(session, owner, owner, deadline) do
    cond do
      not Process.alive?(owner) -> reclaim_or_wait(session, owner, deadline)
      System.monotonic_time(:millisecond) >= deadline -> :timeout
      true -> wait_for_stop(session, owner, deadline)
    end
  end

  defp reclaim_or_wait(session, owner, deadline) do
    case reclaim_stop(session.env_store, owner) do
      :claimed -> finish_stop(session)
      {:waiting, next_owner} -> await_stop(session, next_owner, deadline)
      :stopped -> :ok
      :unavailable -> finish_stop(session)
    end
  end

  defp wait_for_stop(session, owner, deadline) do
    Process.sleep(10)
    await_stop(session, owner, deadline)
  end

  @doc false
  def stop_timeout(deployment, opts) do
    call_timeout = Keyword.get(opts, :call_timeout, @call_timeout)
    launcher_timeout = Keyword.get(opts, :launcher_timeout, @launcher_timeout)
    command_timeout = Keyword.get(opts, :command_timeout, @command_timeout)
    install_timeout = Keyword.get(opts, :install_timeout, @install_timeout)
    shutdown_timeout = Keyword.get(opts, :shutdown_timeout, @shutdown_timeout)
    exit_timeout = Keyword.get(opts, :exit_timeout, @exit_timeout)

    worst_case_start =
      exit_timeout + launcher_timeout + deployment.boot_timeout + call_timeout + command_timeout +
        shutdown_timeout

    worst_case_cleanup = install_timeout + @fallback_timeout + exit_timeout
    worst_case_start + worst_case_cleanup + @stop_slack
  end

  defp stop_server(%__MODULE__{server: server, stop_timeout: timeout} = session) do
    if Process.alive?(server) do
      GenServer.call(server, :stop, timeout)
    else
      fallback_session_stop(session)
    end
  catch
    :exit, {:timeout, _call} ->
      kill_server(session)

    :exit, {:noproc, _call} ->
      fallback_session_stop(session)

    :exit, _reason ->
      kill_server(session)
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

  def install(%__MODULE__{server: server}, vsn, env) do
    GenServer.call(server, {:install, vsn, env}, :infinity)
  catch
    :exit, reason ->
      {:error, "deployment session stopped while installing #{vsn}: #{inspect(reason)}"}
  end

  def restart(%__MODULE__{server: server}, env) do
    GenServer.call(server, {:restart, env}, :infinity)
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
      command_timeout: Keyword.get(opts, :command_timeout, @command_timeout),
      install_timeout: Keyword.get(opts, :install_timeout, @install_timeout),
      shutdown_timeout: Keyword.get(opts, :shutdown_timeout, @shutdown_timeout),
      exit_timeout: Keyword.get(opts, :exit_timeout, @exit_timeout),
      env_store: Keyword.fetch!(opts, :env_store),
      peer: nil,
      os_pid: nil,
      last_os_pid: nil,
      down: nil,
      install: nil,
      cleaned: false
    }

    case start_peer(state) do
      {:ok, state} -> {:ok, state}
      {:error, message} -> {:stop, message}
    end
  end

  @impl true
  def handle_call({:call, module, function, args, timeout}, _from, state) do
    timeout = bounded_call_timeout(timeout, state.call_timeout)
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
    {:reply, operation_result(state, operation), state}
  end

  def handle_call(:stop, _from, state) do
    {result, state} = cleanup(state, :wait)
    {:stop, :normal, result, state}
  end

  def handle_call({:install, vsn, _env}, _from, %{down: reason} = state)
      when not is_nil(reason) do
    {:reply,
     {:error,
      "cannot install #{vsn} in #{state.deployment.root}: " <>
        "the session is unusable after #{inspect(reason)}"}, state}
  end

  def handle_call({:install, _vsn, _env}, _from, %{install: install} = state)
      when not is_nil(install) do
    {:reply, {:error, "another install is already running in #{state.deployment.root}"}, state}
  end

  def handle_call({:install, vsn, env}, from, state) when is_binary(vsn) and is_list(env) do
    case install_command_env(state, env) do
      {:ok, command_env} ->
        remember_env(state, state.env ++ env)

        task =
          Task.async(fn ->
            Deployment.castle(state.deployment, ["install", vsn], command_env)
          end)

        timer = Process.send_after(self(), {:install_timeout, task.ref}, state.install_timeout)

        install = %{
          from: from,
          task: task,
          timer: timer,
          vsn: vsn,
          env: env,
          old_os_pid: state.os_pid
        }

        {:noreply, %{state | install: install}}

      {:error, message} ->
        {:reply, {:error, message}, state}
    end
  end

  def handle_call({:restart, _env}, _from, %{install: install} = state)
      when not is_nil(install) do
    {:reply, {:error, "cannot restart #{state.deployment.root} while an install is running"},
     state}
  end

  def handle_call({:restart, _env}, _from, %{down: :install_timeout} = state) do
    {:reply,
     {:error,
      "cannot restart #{state.deployment.root}: the session is unusable after an install timeout"},
     state}
  end

  def handle_call({:restart, env}, _from, state) when is_list(env) do
    old_peer = state.peer
    old_pid = state.os_pid || state.last_os_pid
    state = %{state | env: state.env ++ env}
    remember_env(state, state.env)
    stop_peer(old_peer)

    case await_exit(old_pid, state.exit_timeout) do
      :ok ->
        state = forget_pid(state)

        case start_peer(%{state | peer: nil, down: nil}) do
          {:ok, restarted} ->
            {:reply, {:ok, :restarted}, restarted}

          {:error, message} ->
            {:reply, {:error, message}, %{state | peer: nil, down: message}}
        end

      {:error, message} ->
        {:reply, {:error, message},
         %{state | peer: nil, os_pid: nil, last_os_pid: old_pid, down: message}}
    end
  end

  @impl true
  def handle_info({ref, {output, status}}, %{install: %{task: %{ref: ref}} = install} = state) do
    Process.demonitor(ref, [:flush])
    cancel_timer(install)

    if install.from do
      {reply, state} =
        if status == 0 do
          {{:ok, output}, %{state | env: state.env ++ install.env}}
        else
          {{:error, "bin/castle install #{install.vsn} exited with #{status}\n\n#{output}"},
           state}
        end

      GenServer.reply(install.from, reply)
      {:noreply, %{state | install: nil}}
    else
      {:noreply, %{state | install: nil}}
    end
  end

  def handle_info({:install_timeout, ref}, %{install: %{task: %{ref: ref}} = install} = state) do
    diagnosis = install_diagnosis(install)

    GenServer.reply(
      install.from,
      {:error,
       "bin/castle install #{install.vsn} did not finish within #{state.install_timeout}ms in " <>
         state.deployment.root <> diagnosis}
    )

    {:noreply,
     %{
       state
       | install: %{install | from: nil, timer: nil},
         down: :install_timeout
     }}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{install: %{task: %{ref: ref}} = install} = state
      ) do
    cancel_timer(install)

    if install.from do
      GenServer.reply(
        install.from,
        {:error, "bin/castle install #{install.vsn} could not be run: #{inspect(reason)}"}
      )
    end

    {:noreply, %{state | install: nil}}
  end

  def handle_info({:EXIT, peer, reason}, %{peer: peer, install: nil} = state) do
    {:noreply, %{state | peer: nil, os_pid: nil, last_os_pid: state.os_pid, down: reason}}
  end

  def handle_info({:EXIT, peer, reason}, %{peer: peer, install: install} = state) do
    case expected_reboot(state.deployment, install.vsn) do
      :ok ->
        case await_exit(install.old_os_pid, state.exit_timeout) do
          :ok ->
            replace_after_install(state, install)

          {:error, message} ->
            fail_install(state, message)
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
    unless state.cleaned, do: cleanup(state, :kill)
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
    boot_ref = make_ref()

    options = %{
      connection: {{127, 0, 0, 1}, 0},
      exec: {to_charlist(shell), [to_charlist(adapter)]},
      post_process_args: fn [_adapter | args] ->
        write_private(peer_args, encode_peer_args(args))

        [adapter, launcher, Enum.join(unset, ","), work]
        |> Enum.map(&to_charlist/1)
      end,
      env: Enum.map(env, fn {name, value} -> {to_charlist(name), to_charlist(value)} end),
      # OTP's peer user process reports `started` through
      # `init:notify_when_started/1`. That notification is emitted only after
      # init has finished the boot script, including application startup, so
      # this one synchronous wait necessarily covers both the launcher/preboot
      # work and the application's cold boot. The two allowances are added; a
      # separate readiness poll after this would be asking an already-settled
      # init process the same question again.
      # Use the asynchronous notification form so the adapter's status file can
      # distinguish an env.sh/launcher refusal from a boot that is still in
      # progress. OTP's integer form waits internally and exits `:timeout`, with
      # the detached launcher's status no longer observable.
      wait_boot: {self(), boot_ref},
      shutdown: {:halt, state.shutdown_timeout},
      peer_down: :stop
    }

    try do
      case :peer.start_link(options) do
        {:ok, peer} ->
          await_peer_boot(peer, boot_ref, state, work)

        {:ok, peer, _node} ->
          await_peer_boot(peer, boot_ref, state, work)

        {:error, reason} ->
          {:error,
           "the OTP peer controller for #{deployment.root} could not be started: " <>
             inspect(reason)}
      end
    after
      File.rm_rf(work)
    end
  catch
    :exit, :timeout ->
      {:error,
       "#{state.deployment.root} did not boot through its stock launcher within " <>
         "#{state.launcher_timeout + state.deployment.boot_timeout}ms"}

    kind, reason ->
      {:error,
       "#{state.deployment.root} could not be booted through its stock launcher: " <>
         Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp await_peer_boot(peer, boot_ref, state, work) do
    timeout = state.launcher_timeout + state.deployment.boot_timeout
    deadline = System.monotonic_time(:millisecond) + timeout
    await_peer_boot(peer, boot_ref, state, Path.join(work, "launcher.status"), timeout, deadline)
  end

  defp await_peer_boot(peer, boot_ref, state, status_file, timeout, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^boot_ref, {:started, _node, ^peer}} ->
        peer_started(peer, state)

      {^boot_ref, {:boot_failed, reason, ^peer}} ->
        stop_peer(peer)
        {:error, "the OTP peer for #{state.deployment.root} failed to boot: #{inspect(reason)}"}

      {:EXIT, ^peer, reason} ->
        {:error,
         "the OTP peer controller for #{state.deployment.root} exited while booting: " <>
           inspect(reason)}
    after
      min(left, @boot_interval) ->
        case launcher_status(status_file) do
          {:ok, 0} when left > 0 ->
            # `-detached` makes the stock launcher return after handing the VM
            # off, before OTP's init-started notification reaches us. Zero is
            # therefore progress rather than a completed boot; only a non-zero
            # status is an early refusal.
            File.rm(status_file)
            await_peer_boot(peer, boot_ref, state, status_file, timeout, deadline)

          {:ok, 0} ->
            stop_peer(peer)

            {:error,
             "#{state.deployment.root} did not boot through its stock launcher within " <>
               "#{timeout}ms"}

          {:ok, status} ->
            stop_peer(peer)

            {:error,
             "the stock launcher for #{state.deployment.root} exited with status #{status} " <>
               "before the OTP peer booted"}

          :running when left > 0 ->
            await_peer_boot(peer, boot_ref, state, status_file, timeout, deadline)

          :running ->
            stop_peer(peer)

            {:error,
             "#{state.deployment.root} did not boot through its stock launcher within " <>
               "#{timeout}ms"}
        end
    end
  end

  @doc false
  def launcher_status(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Integer.parse(String.trim(bytes)) do
          {status, ""} -> {:ok, status}
          _ -> :running
        end

      {:error, :enoent} ->
        :running

      {:error, _reason} ->
        :running
    end
  end

  defp peer_started(peer, state) do
    case safe_call(peer, System, :pid, [], state.call_timeout) do
      {:ok, os_pid} ->
        remember_pid(state, os_pid)
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
    case command(fn -> Deployment.castle(state.deployment, args, state.env ++ env) end, state) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, status}} ->
        {:error, "castle #{Enum.join(args, " ")} exited with #{status}\n\n#{output}"}

      {:error, message} ->
        {:error, "castle #{Enum.join(args, " ")} #{message}"}
    end
  end

  defp run_operation(state, {:launcher, args, env}) do
    case command(fn -> Deployment.launcher(state.deployment, args, state.env ++ env) end, state) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, status}} ->
        {:error,
         "#{state.deployment.name} #{Enum.join(args, " ")} exited with #{status}\n\n#{output}"}

      {:error, message} ->
        {:error, "#{state.deployment.name} #{Enum.join(args, " ")} #{message}"}
    end
  end

  defp command(run, state) do
    task = Task.async(run)

    case Task.yield(task, state.command_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      {:exit, reason} -> {:error, "could not be run: #{inspect(reason)}"}
      nil -> {:error, "did not finish within #{state.command_timeout}ms"}
    end
  end

  defp operation_result(state, operation) do
    run_operation(state, operation)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp kill_server(%__MODULE__{server: server} = session) do
    if Process.alive?(server) do
      monitor = Process.monitor(server)
      Process.exit(server, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^server, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end

    case fallback_session_stop(session) do
      :ok -> :killed
      {:error, message} -> {:error, "session controller was killed; " <> message}
    end
  end

  defp claim_stop(nil), do: :claimed

  defp claim_stop(env_store) do
    owner = self()

    Agent.get_and_update(env_store, fn
      %{stop_status: :active} = store ->
        {:claimed, %{store | stop_status: :stopping, stop_owner: owner}}

      %{stop_status: :stopping, stop_owner: owner} = store ->
        {{:waiting, owner}, store}

      %{stop_status: :stopped} = store ->
        {:stopped, store}
    end)
  catch
    :exit, _reason -> :unavailable
  end

  defp reclaim_stop(nil, _owner), do: :claimed

  defp reclaim_stop(env_store, owner) do
    claimant = self()

    Agent.get_and_update(env_store, fn
      %{stop_status: :stopping, stop_owner: ^owner} = store ->
        {:claimed, %{store | stop_owner: claimant}}

      %{stop_status: :stopping, stop_owner: next_owner} = store ->
        {{:waiting, next_owner}, store}

      %{stop_status: :active} = store ->
        {:claimed, %{store | stop_status: :stopping, stop_owner: claimant}}

      %{stop_status: :stopped} = store ->
        {:stopped, store}
    end)
  catch
    :exit, _reason -> :unavailable
  end

  defp release_stop(nil), do: :ok

  defp release_stop(env_store) do
    owner = self()

    Agent.update(env_store, fn
      %{stop_status: :stopping, stop_owner: ^owner} = store ->
        %{store | stop_status: :active, stop_owner: nil}

      store ->
        store
    end)
  catch
    :exit, _reason -> :ok
  end

  defp complete_stop(nil), do: :ok

  defp complete_stop(env_store) do
    Agent.update(env_store, fn store ->
      %{store | env: [], os_pid: nil, stop_status: :stopped, stop_owner: nil}
    end)
  catch
    :exit, _reason -> :ok
  end

  defp stop_status(nil), do: :stopped

  defp stop_status(env_store) do
    Agent.get(env_store, fn
      %{stop_status: :stopping, stop_owner: owner} -> {:stopping, owner}
      %{stop_status: status} -> status
    end)
  catch
    :exit, _reason -> :unavailable
  end

  defp fallback_session_stop(session) do
    {env, os_pid} = fallback_details(session.env_store)
    fallback_stop(session.deployment, env, os_pid, session.exit_timeout)
  end

  defp fallback_details(nil), do: {[], nil}

  defp fallback_details(env_store) do
    Agent.get(env_store, fn store -> {store.env, store.os_pid} end, 1_000)
  catch
    :exit, _reason -> {[], nil}
  end

  defp remember_env(state, env) do
    Agent.update(state.env_store, fn store -> %{store | env: env} end)
  catch
    :exit, _reason -> :ok
  end

  defp remember_pid(state, os_pid) do
    Agent.update(state.env_store, fn store -> %{store | os_pid: os_pid} end)
  catch
    :exit, _reason -> :ok
  end

  defp forget_pid(state) do
    remember_pid(state, nil)
    %{state | os_pid: nil, last_os_pid: nil}
  end

  defp stop_env_store(nil), do: :ok

  defp stop_env_store(env_store) do
    if Process.alive?(env_store), do: Agent.stop(env_store, :normal, 1_000), else: :ok
  catch
    :exit, _reason -> :ok
  end

  defp fallback_stop(deployment, env, os_pid, exit_timeout) do
    launcher = Path.join(deployment.root, "bin/#{deployment.name}")

    if File.regular?(launcher) do
      run_fallback_stop(deployment, env, os_pid, exit_timeout)
    else
      {:error, "fallback launcher does not exist: #{launcher}"}
    end
  rescue
    error -> {:error, "fallback #{deployment.name} stop failed: #{Exception.message(error)}"}
  catch
    kind, reason ->
      {:error,
       "fallback #{deployment.name} stop failed: " <>
         Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp run_fallback_stop(deployment, env, os_pid, exit_timeout) do
    case Deployment.stop(deployment, env) do
      {_output, 0} ->
        confirm_fallback_exit(
          os_pid,
          exit_timeout,
          "fallback #{deployment.name} stop exited successfully"
        )

      {output, status} ->
        prefix =
          "fallback #{deployment.name} stop exited with #{status}: #{String.trim(output)}"

        confirm_fallback_exit(os_pid, exit_timeout, prefix)

      :timeout ->
        confirm_fallback_exit(
          os_pid,
          exit_timeout,
          "fallback #{deployment.name} stop did not finish within its deadline"
        )
    end
  end

  defp confirm_fallback_exit(nil, _timeout, prefix) do
    {:error, prefix <> "; the session had no operating-system pid to verify"}
  end

  defp confirm_fallback_exit(os_pid, timeout, prefix) do
    case await_exit(os_pid, timeout) do
      :ok -> :ok
      {:error, why} -> {:error, prefix <> "; " <> why}
    end
  end

  defp new_store(env) do
    %{env: env, os_pid: nil, stop_status: :active, stop_owner: nil}
  end

  defp report_stop_result(_session, :ok, _os_pid), do: :ok

  defp report_stop_result(session, result, os_pid) do
    IO.puts(
      :stderr,
      "warning: deployment session teardown for #{session.deployment.root} returned " <>
        "#{inspect(result)} (last operating-system pid: #{inspect(os_pid)})"
    )
  end

  defp bounded_call_timeout(:infinity, ceiling), do: ceiling

  defp bounded_call_timeout(timeout, ceiling)
       when is_integer(timeout) and timeout >= 0,
       do: min(timeout, ceiling)

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
    if install.from, do: GenServer.reply(install.from, {:error, message <> diagnosis})

    {:noreply,
     %{
       state
       | install: %{install | from: nil, timer: nil},
         peer: nil,
         os_pid: nil,
         last_os_pid: state.os_pid,
         down: message
     }}
  end

  defp replace_after_install(state, install) do
    state =
      state
      |> Map.put(:env, state.env ++ install.env)
      |> forget_pid()

    case start_peer(%{state | peer: nil, down: nil}) do
      {:ok, restarted} -> {:noreply, %{restarted | install: %{install | env: []}}}
      {:error, message} -> fail_install(state, message)
    end
  end

  defp install_diagnosis(install) do
    "\n\nbin/castle install had not exited; task #{inspect(install.task.pid)} remains " <>
      "tracked until it finishes or session teardown attempts to stop it. A forced task stop " <>
      "cannot guarantee that the operating-system process has exited."
  end

  defp cancel_timer(install) do
    if install.timer && Process.cancel_timer(install.timer) == false do
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

  @doc false
  def encode_peer_args(args) do
    Enum.map_join(args, "\n", fn arg ->
      escaped =
        arg
        |> to_string()
        |> String.replace("'", ~S('"'"'))

      "'#{escaped}'"
    end) <> "\n"
  end

  defp install_command_env(state, env) do
    maximum = state.install_timeout - @install_slack

    supplied =
      final_env_value(state.deployment.env ++ state.env ++ env, "CASTLE_INSTALL_TIMEOUT")

    cond do
      maximum < 1_000 ->
        {:error,
         ":install_timeout must be at least #{@install_slack + 1_000}ms so bin/castle can time out before its session"}

      is_nil(supplied) ->
        seconds = div(maximum, 1_000)
        {:ok, state.env ++ env ++ [{"CASTLE_INSTALL_TIMEOUT", Integer.to_string(seconds)}]}

      true ->
        case Integer.parse(supplied) do
          {seconds, ""} when seconds > 0 and seconds * 1_000 <= maximum ->
            {:ok, state.env ++ env}

          _ ->
            {:error,
             "CASTLE_INSTALL_TIMEOUT must be a positive whole number of seconds no greater than #{div(maximum, 1_000)} for this session"}
        end
    end
  end

  defp final_env_value(env, name) do
    Enum.reduce(env, nil, fn
      {^name, value}, _current -> value
      _entry, current -> current
    end)
  end

  defp cleanup(state, install_mode) do
    install_result = finish_install(state.install, state.install_timeout, install_mode)
    {stop_result, exit_result} = stop_and_confirm(state)

    result =
      cond do
        install_result != :ok or exit_result != :ok -> :timeout
        match?({:error, _message}, stop_result) -> stop_result
        true -> :ok
      end

    {result, %{state | install: nil, peer: nil, os_pid: nil, cleaned: true}}
  end

  defp stop_and_confirm(%{peer: nil} = state) do
    os_pid = state.os_pid || state.last_os_pid

    result =
      fallback_stop(
        state.deployment,
        state.env,
        os_pid,
        state.exit_timeout
      )

    exit_result = if result == :ok, do: :ok, else: await_exit(os_pid, state.exit_timeout)
    {result, exit_result}
  end

  defp stop_and_confirm(state) do
    os_pid = state.os_pid || state.last_os_pid
    stop_peer(state.peer)

    case await_exit(os_pid, state.exit_timeout) do
      :ok ->
        {:ok, :ok}

      {:error, _why} = exit_result ->
        case fallback_stop(state.deployment, state.env, os_pid, state.exit_timeout) do
          :ok -> {:ok, :ok}
          {:error, _message} = stop_result -> {stop_result, exit_result}
        end
    end
  end

  defp finish_install(nil, _timeout, _mode), do: :ok

  defp finish_install(install, timeout, :wait) do
    cancel_timer(install)
    result = Task.yield(install.task, timeout) || Task.shutdown(install.task, :brutal_kill)
    Process.demonitor(install.task.ref, [:flush])
    if result, do: :ok, else: :timeout
  end

  defp finish_install(install, _timeout, :kill) do
    cancel_timer(install)
    Task.shutdown(install.task, :brutal_kill)
    :ok
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

  defp write_private(path, content) do
    File.open!(path, [:write, :exclusive], fn file ->
      File.chmod!(path, 0o600)

      case IO.binwrite(file, content) do
        :ok -> :ok
        {:error, reason} -> raise File.Error, reason: reason, action: "write to", path: path
      end
    end)
  end

  defp operation_name(operation) when is_tuple(operation), do: elem(operation, 0)
  defp operation_name(operation), do: operation
end
