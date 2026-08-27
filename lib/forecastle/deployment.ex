defmodule Forecastle.Deployment do
  @moduledoc """
  A release on disk, and everything an upgrade test does to one.

  Assembling a release proves it builds. Only starting one and moving it to the
  next version proves the upgrade *works*, and that is what this is for: it
  starts a release under its own stock Mix launcher, drives `bin/castle` against
  it, asks the running node questions over `rpc`, and stands in for the external
  supervisor a transition that restarts the emulator needs.

  It is deliberately not a test of anything. What "the upgrade worked" means is
  the project's to say - a counter that survived, a socket still open, a job
  still in flight - so nothing here asserts it. See `Forecastle.UpgradeCase` for
  the case template this is the other half of, and for what a whole upgrade test
  looks like.

  ## The two ways to get one

  `new/3` names a release tree that is already where it should be, which is what
  a project's own `mix release --path` produces.

  `deploy!/3` takes a *baseline spec* - the same `rel:`, `tar:` and `ref:`
  grammar `mix castle.relup` reads, see `Forecastle.Baseline` - and lays the
  release it names out in a directory of its own. That is what makes an upgrade
  test from the artefact that actually shipped a single line, and `tar:` is the
  spec to reach for: a relup is selected by from-version *string* and never
  checked against the code that is running, so a baseline rebuilt from source
  today is a release that was never deployed.

  **It copies rather than deploying in place, and that is not tidiness.**
  `Forecastle.Baseline` resolves `tar:` and `ref:` into an immutable cache under
  `_build/castle/baselines`, keyed on what the entry was built from. Starting a
  release writes `releases/RELEASES` into it, unpacking one puts another release
  beside it and installing rewrites `start_erl.data` - so a deployment run in the
  cache would leave every later resolution of that spec holding a half-upgraded
  system, with nothing to say so.

  ## The environment a release is started with

  Every command runs with `scrubbed_env/1` applied, which unsets the variables
  that would otherwise leak from the shell running the tests into the release
  being tested. That is not hygiene either: `ELIXIR_ERL_OPTIONS` and its four
  siblings carry flags to the emulator, so a `-heart` in a developer's shell or a
  CI image ends up in every release these tests start, and a release that already
  supplies one is then given two - which leaves `heart:check_start_heart/0` with
  no clause to match and hangs the boot having printed nothing.

  `RELEASE_VM_ARGS` and `RELEASE_REMOTE_VM_ARGS` are worse than an extra flag:
  they redirect the launcher to a different args file entirely, so one set in the
  environment would have every release booting on some other project's `vm.args`
  and presenting as a bug in the release rather than as a leaked variable.

  Anything a caller passes is applied after the scrub, so a test that wants one
  of these set says so and gets it.
  """

  # `flunk/1` only. A deployment that never answers is a test failure and wants
  # to be reported as one, but nothing here decides whether an upgrade worked, so
  # nothing here needs the rest of the assertions.
  import ExUnit.Assertions, only: [flunk: 1]

  alias Forecastle.Baseline

  @enforce_keys [:root, :name, :cd]
  defstruct [:root, :name, :cd, env: []]

  @typedoc """
  Environment for a command, in the shape `System.cmd/3` takes it: a `nil` value
  unsets the variable rather than setting it to an empty string.
  """
  @type env :: [{binary(), binary() | nil}]

  @typedoc """
  A release tree, the name of the release inside it, the directory commands are
  run from, and the environment every one of them carries.
  """
  @type t :: %__MODULE__{
          root: Path.t(),
          name: binary(),
          cd: Path.t(),
          env: env()
        }

  # How long `daemon` itself is given to return. Generous, because on a first
  # start it sources `env.sh`, which runs a preboot VM to create
  # `releases/RELEASES` and waits for it.
  @start_timeout 180_000

  # How long `bin/castle install` is given once the release has been started
  # again. It polls the system for the version it installed, so this only has to
  # outlast a reboot and a cold boot.
  @install_timeout 300_000

  # How long an operating system process is given to go away, and how often it
  # is asked. Thirty seconds, which is a reboot rather than a boot: what starts
  # the release again is the caller.
  @exit_attempts 300
  @exit_interval 100

  # Mix variables that would otherwise redirect a build's output, and release
  # variables that would leak into a launcher a test invokes.
  #
  # `ERL_AFLAGS`, `ERL_FLAGS` and `ERL_ZFLAGS` are here alongside
  # `ELIXIR_ERL_OPTIONS` because all four carry flags to the emulator - erlexec
  # prepends the first and appends the other two to the command line it builds -
  # so any of them set in a developer's shell or a CI image would put a `-heart`
  # into every start made here.
  #
  # `ERL_OTP<major>_FLAGS` is a fifth such variable - erlexec prepends it too -
  # and it leaks the same way, but it cannot be written into this list because
  # its name carries the emulator's OTP major. It is appended in
  # `scrubbed_env/1` instead.
  #
  # `MIX_ENV` is here for a milder reason than the rest and a real one:
  # a deployed release is started with no Mix and no `MIX_ENV`, while a release
  # started from a test run inherits `test` - measured, on the generated
  # launcher. Nothing Forecastle or Mix writes reads it, so what it changes is
  # whatever the *project's* `config/runtime.exs` makes of it, and that file is
  # the one place a project routinely shares between a Mix run and a release. A
  # deployment that answered differently there than a deployment would is the
  # whole failure this list exists to prevent, arrived at through the one
  # variable a project is most likely to read.
  @scrubbed ~w(MIX_ENV MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_TARGET
               MIX_QUIET MIX_DEBUG ERL_LIBS ELIXIR_ERL_OPTIONS ERL_AFLAGS
               ERL_FLAGS ERL_ZFLAGS RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS
               RELEASE_ROOT RELEASE_NAME
               RELEASE_VSN RELEASE_COOKIE RELEASE_NODE RELEASE_TMP)

  @doc """
  Names a release tree that is already laid out where it is wanted.

  `root` is the directory holding `bin/`, `lib/` and `releases/` - what
  `mix release --path` was pointed at - and `name` is the release inside it, so
  that `bin/<name>` is the launcher.

  Options:

    * `:cd`  - the directory commands are run from. Defaults to the current one,
      which for a test run is the project root rather than the release, and
      deliberately: a launcher invoked from somewhere other than the release root
      is the ordinary case, and running from inside the release would stop these
      tests from covering it.
    * `:env` - environment carried by every command this deployment runs, on top
      of `scrubbed_env/1` and underneath anything a call passes for itself.
  """
  @spec new(Path.t(), binary(), keyword()) :: t()
  def new(root, name, opts \\ []) when is_binary(root) and is_binary(name) do
    %__MODULE__{
      root: Path.expand(root),
      name: name,
      cd: Path.expand(Keyword.get(opts, :cd, File.cwd!())),
      env: Keyword.get(opts, :env, [])
    }
  end

  @doc """
  Resolves a baseline spec and lays the release it names out in `into`.

  The spec is the grammar `Forecastle.Baseline` reads - `rel:` an assembled
  release, `tar:` a shipped artefact, `ref:` a git ref built in a worktree - and
  a value with no prefix is a `rel:` path. `tar:` is the one to prefer, for the
  reason `Forecastle.Baseline` gives: it is the release that shipped rather than
  one rebuilt from the same source with today's toolchain.

  `into` is emptied first and the release copied into it, so the deployment is
  this test's to write to and the resolved baseline stays exactly as it was
  resolved. Options are `new/3`'s.

  Refuses a spec that does not resolve to a release, and a destination that
  overlaps the one it does. Both are asked *before* the destination is emptied:
  everything that can be found out about the source is found out while there is
  still nothing to lose by saying so.
  """
  @spec deploy!(binary(), Path.t(), keyword()) :: t()
  def deploy!(spec, into, opts \\ []) when is_binary(spec) and is_binary(into) do
    baseline = Baseline.resolve!(spec, :release)

    root = Path.expand("../../..", baseline.rel_path)
    into = Path.expand(into)

    refuse_unusable!(spec, baseline.rel_path, root)
    refuse_overlap!(spec, root, into)

    File.rm_rf!(into)
    File.mkdir_p!(Path.dirname(into))
    File.cp_r!(root, into)

    new(into, Path.basename(baseline.rel_path), opts)
  end

  # **The release root is three directories above the `.rel`, and nothing on the
  # way in checks that there are three.** `Forecastle.Baseline` deliberately
  # reads no filesystem for a `rel:` spec - it leaves that to whatever is about
  # to use the path - and `Path.expand/2` climbing past the top of an absolute
  # path stops at `/` rather than failing. So `rel:/tmp/missing` resolves to a
  # root of `/`, and what used to happen next was `File.rm_rf!/1` on the
  # destination followed by a recursive copy of the whole filesystem into it.
  #
  # Two questions close that, and both are about the spec rather than about the
  # caller. The `.rel` has to be a file, which is the same thing
  # `mix castle.relup` finds out a moment later and the reason the resolver
  # leaves it alone. And it has to sit under `releases/<vsn>/`, because
  # `<root>/releases/<vsn>/<name>` is the whole of what makes "three directories
  # above" mean anything: a path shaped some other way has no root to climb to,
  # only a directory that happens to be three levels up.
  defp refuse_unusable!(spec, rel_path, root) do
    cond do
      not File.regular?(rel_path <> ".rel") ->
        Mix.raise(
          "#{spec} names a release file at #{rel_path}.rel, and there is no such file. " <>
            "A `rel:` baseline is the path to a `.rel` without its extension, so " <>
            "`rel:<root>/releases/<vsn>/<name>` is the spec that deploys `<root>`."
        )

      Path.basename(Path.dirname(Path.dirname(rel_path))) != "releases" ->
        Mix.raise(
          "#{spec} names #{rel_path}.rel, which is not under a `releases/<vsn>/` " <>
            "directory, so there is no release root above it to deploy. Climbing out " <>
            "of it anyway reaches #{root}, which is a directory rather than a release."
        )

      true ->
        :ok
    end
  end

  # A destination inside the release, or a release inside the destination, is
  # `File.rm_rf!/1` deleting what is about to be copied. Cheap to check and
  # unrecoverable to get wrong - `rel:` names a directory the project built, and
  # `tar:` and `ref:` name one in a cache every later resolution reads.
  defp refuse_overlap!(spec, root, into) do
    if contains?(root, into) or contains?(into, root) do
      Mix.raise(
        "cannot deploy #{spec} into #{into}: that path and the release at #{root} " <>
          "are the same directory or one is inside the other, and deploying empties " <>
          "the destination first. Name a directory of its own."
      )
    end
  end

  # Compared as path *segments*, because a textual prefix test gets two cases
  # wrong in opposite directions. `<root>-next` reads as being inside `<root>`,
  # which refuses a perfectly good sibling; and a root of `/` matches nothing at
  # all, because `/` with a separator appended is `//`, which no absolute path
  # begins with. The second is the one that mattered - it is what a spec with
  # too few directories in it resolves to.
  #
  # A list is a prefix of itself, so this answers the two paths being the same
  # directory as well.
  defp contains?(outer, inner) do
    List.starts_with?(Path.split(inner), Path.split(outer))
  end

  @doc """
  The release version an ordinary start of this deployment would boot.

  Read from `releases/start_erl.data`, which is `<erts vsn> <release vsn>`, and
  read the way the launcher reads it: `bin/<name>` takes `RELEASE_VSN` from
  `cut -d' ' -f2`, so this takes the second space-separated field. **Not the
  last one**, which is what it took while it was a private helper here. The two
  answers differ only for a version that itself contains a space - which Castle
  permits, since its rule is valid UTF-8 with no control characters - and for
  one of those the launcher's answer is the one that is true about what starts.

  That file is written by Mix at assembly and afterwards only by
  `release_handler:make_permanent/1`, so between an install and the commit that
  follows it this still names the version being upgraded *from* - which is the
  rollback target, and is right rather than stale.
  """
  @spec version(t()) :: binary()
  def version(%__MODULE__{} = deployment) do
    file = path(deployment, "releases/start_erl.data")

    case file |> File.read!() |> String.split(" ") do
      [_erts, vsn | _rest] -> String.trim(vsn)
      _no_version -> Mix.raise("#{file} does not name a release version.")
    end
  end

  @doc """
  Puts a release tarball where `bin/castle unpack` will find it.

  `release_handler` looks for `releases/<name>-<vsn>.tar.gz` under the release
  root, which is the name `mix release` gives the archive it packs, so the
  archive is copied under the name it already has. Returns where it was put.
  """
  @spec stage!(t(), Path.t()) :: Path.t()
  def stage!(%__MODULE__{} = deployment, tarball) do
    staged = path(deployment, Path.join("releases", Path.basename(tarball)))
    File.cp!(tarball, staged)
    staged
  end

  @doc """
  Starts the release as a daemon and waits for it to answer.

  Returns what the launcher printed, which is how a test gets at what `env.sh`
  said on the way past - the two streams merged. `launcher!/3` raises if the
  start itself failed, so a caller that ignores the return value still gets that.

  **The launcher is given a deadline, and that is not belt-and-braces.** A boot
  that hangs is a real failure mode here - two `-heart` flags leave
  `heart:check_start_heart/0` with no clause for `{ok, [[], []]}` and the node
  never finishes starting, having printed nothing - and it hangs *inside*
  `daemon` rather than after it, because `env.sh` runs a preboot VM synchronously
  on a first start and that VM inherits the same options. `System.cmd/3` has no
  deadline of its own and `setup_all` has no ExUnit timeout, so without this a
  regression in the `-heart` guard stops the suite for as long as whatever is
  running it will wait. Measured, by putting the guard back the way it was.
  """
  @spec start!(t(), env()) :: binary()
  def start!(%__MODULE__{} = deployment, env \\ []) do
    started = Task.async(fn -> launcher!(deployment, ["daemon"], env) end)

    output =
      case Task.yield(started, @start_timeout) do
        {:ok, output} -> output
        _no_answer -> abandoned!(started, deployment)
      end

    await_boot!(deployment)
    output
  end

  defp abandoned!(started, deployment) do
    Task.shutdown(started, :brutal_kill)

    flunk(
      "#{deployment.root} did not finish starting within #{div(@start_timeout, 1000)}s. " <>
        "A launcher that never returns is a boot that hung rather than one that " <>
        "failed, and the usual cause is the VM being given two -heart flags: " <>
        "init:get_argument(heart) reports {ok, [[], []]}, which heart's own " <>
        "startup check has no clause for. Nothing is printed when that happens, " <>
        "so there is no output to report here."
    )
  end

  @doc """
  Stops the release, tolerating a system that is not running.

  Returns `{output, status}` rather than raising, because the place this belongs
  is an `on_exit` callback: a suite that failed part way through may have left
  nothing to stop, and a teardown that raised there would report itself instead
  of the failure that got it here.
  """
  @spec stop(t()) :: {binary(), non_neg_integer()}
  def stop(%__MODULE__{} = deployment), do: launcher(deployment, ["stop"])

  @doc """
  The operating system pid of the running release, as the release reports it.

  `bin/<name> pid` is an rpc, so this is the beam's own `System.pid/0` rather
  than anything about the process that asked - which is what makes it usable both
  for telling one incarnation of the node from another and for waiting on the
  first to go away.
  """
  @spec os_pid(t()) :: binary()
  def os_pid(%__MODULE__{} = deployment), do: launcher!(deployment, ["pid"])

  @doc "Waits until the release accepts an rpc, or fails the test."
  @spec await_boot!(t(), non_neg_integer()) :: :ok
  def await_boot!(deployment, attempts \\ 100)

  def await_boot!(%__MODULE__{} = deployment, 0) do
    flunk("#{deployment.root} did not accept an rpc within the timeout")
  end

  def await_boot!(%__MODULE__{} = deployment, attempts) do
    case launcher(deployment, ["rpc", "IO.puts(:booted)"]) do
      {_output, 0} -> :ok
      {_output, _} -> Process.sleep(200) && await_boot!(deployment, attempts - 1)
    end
  end

  @doc """
  Waits until the operating system process `pid` is gone, or fails the test.

  Asked of the operating system rather than of the node: a node that has stopped
  answering rpc is not necessarily a process that has exited, and starting the
  replacement while the old beam still holds the distribution port is how a
  supervised restart turns into a name clash instead of a boot.
  """
  @spec await_exit!(binary(), non_neg_integer()) :: :ok
  def await_exit!(pid, attempts \\ @exit_attempts)

  def await_exit!(pid, 0), do: flunk("process #{pid} was still running at the timeout")

  def await_exit!(pid, attempts) do
    if running?(pid) do
      Process.sleep(@exit_interval) && await_exit!(pid, attempts - 1)
    else
      :ok
    end
  end

  defp running?(pid) do
    match?({_output, 0}, System.cmd("ps", ["-o", "pid=", "-p", pid], stderr_to_stdout: true))
  end

  @doc """
  Installs `vsn` through `bin/castle` while acting as the release's supervisor,
  returning `{output, status}`.

  **This is the call for a transition that restarts the emulator, and the reason
  there is no single one that covers both kinds.** Such a transition applies the
  relup and then reboots, and nothing inside the release starts it again - that
  is the design rather than a gap: `bin/start` is inert, `HEART_COMMAND` is
  unset, and systemd, Docker or runit owns the restart. So a test of one has to
  be the supervisor. `bin/castle install` is run in a task, because it keeps
  asking the system what it is running until the version it installed answers;
  this waits for the old *operating system process* to go, starts the release
  again, and then collects what the install made of it.

  A hot upgrade never leaves that process, so this would wait for an exit that is
  not coming. Use `castle/3` or `castle!/3` with `["install", vsn]` for one.

  For a test that wants the failure rather than the tuple, `install_supervised!/3`
  raises on a non-zero status the way every other bang here does.
  """
  @spec install_supervised(t(), binary(), env()) :: {binary(), non_neg_integer()}
  def install_supervised(%__MODULE__{} = deployment, vsn, env \\ []) do
    pid = os_pid(deployment)

    installing = Task.async(fn -> castle(deployment, ["install", vsn], env) end)

    await_reboot!(installing, pid, @exit_attempts)
    start!(deployment, env)

    Task.await(installing, @install_timeout)
  end

  @doc """
  `install_supervised/3`, raising on a non-zero exit.

  The install can fail on either side of the reboot, and the far side is the
  one a bang name is doing work for: `bin/castle install` polls for the version
  it installed *after* the release has come back, so an upgrade that rolled back
  on the way up is reported here and nowhere earlier. Returning the tuple under
  a bang name left that for a caller to notice, and a test written the way the
  documentation suggests - substituting this for `castle!/3` - would not have.
  """
  @spec install_supervised!(t(), binary(), env()) :: binary()
  def install_supervised!(%__MODULE__{} = deployment, vsn, env \\ []) do
    deployment |> install_supervised(vsn, env) |> ok!("castle", ["install", vsn])
  end

  # The old process going away is what says the install really rebooted. What
  # this *also* watches for is the install answering first, and that is not belt
  # and braces: `bin/castle install` polls the system for the version it
  # installed, and on this path the system cannot answer until the release has
  # been started again - which happens after this returns. So a task that has
  # already finished has finished about a failure, and it is holding the only
  # account of it.
  #
  # Waiting on the process alone, which is what this did while it was private to
  # this repository's suites, spent the whole timeout and then said that a
  # process was still running: true about the symptom, with Castle's statement
  # of the cause collected a moment later and thrown away.
  defp await_reboot!(installing, pid, attempts) do
    if running?(pid) do
      still_running!(installing, pid, attempts)
    else
      :ok
    end
  end

  defp still_running!(installing, pid, attempts) do
    case Task.yield(installing, 0) do
      nil when attempts > 0 ->
        Process.sleep(@exit_interval)
        await_reboot!(installing, pid, attempts - 1)

      nil ->
        Task.shutdown(installing, :brutal_kill)

        flunk(
          "bin/castle install has neither finished nor taken process #{pid} with it, " <>
            "#{div(@exit_attempts * @exit_interval, 1000)}s after it was asked for. " <>
            "A transition that restarts the emulator reboots the node, so this is an " <>
            "install that is neither failing nor rebooting."
        )

      {:ok, {output, status}} ->
        flunk(
          "bin/castle install exited #{status} without the release rebooting - process " <>
            "#{pid} is still the one running. Either the install was refused, or the " <>
            "transition is a hot upgrade and wanted castle!/3 rather than " <>
            "install_supervised!/3. This is what the install said.\n\n#{output}"
        )

      {:exit, reason} ->
        flunk("bin/castle install could not be run: #{inspect(reason)}")
    end
  end

  @doc "Runs the stock Mix launcher, returning `{output, status}`."
  @spec launcher(t(), [binary()], env()) :: {binary(), non_neg_integer()}
  def launcher(%__MODULE__{name: name} = deployment, args, env \\ []) do
    cmd(deployment, path(deployment, "bin/#{name}"), args, env)
  end

  @doc "Runs the stock Mix launcher, raising on a non-zero exit."
  @spec launcher!(t(), [binary()], env()) :: binary()
  def launcher!(%__MODULE__{} = deployment, args, env \\ []) do
    deployment |> launcher(args, env) |> ok!(deployment.name, args)
  end

  @doc "Runs `bin/castle`, returning `{output, status}`."
  @spec castle(t(), [binary()], env()) :: {binary(), non_neg_integer()}
  def castle(%__MODULE__{} = deployment, args, env \\ []) do
    cmd(deployment, path(deployment, "bin/castle"), args, env)
  end

  @doc "Runs `bin/castle`, raising on a non-zero exit."
  @spec castle!(t(), [binary()], env()) :: binary()
  def castle!(%__MODULE__{} = deployment, args, env \\ []) do
    deployment |> castle(args, env) |> ok!("castle", args)
  end

  @doc "Evaluates an expression in the running release."
  @spec rpc!(t(), binary(), env()) :: binary()
  def rpc!(%__MODULE__{} = deployment, expression, env \\ []) do
    launcher!(deployment, ["rpc", expression], env)
  end

  @doc """
  The caller's environment with everything that leaks into a release unset, and
  `extra` applied on top.

  Public because a project builds the releases it upgrades between as well as
  running them, and the same variables redirect a `mix release` as redirect a
  launcher. Anything in `extra` wins, so a test that wants one of the scrubbed
  variables set - which is how you give a release a hostile environment to boot
  in - simply names it.
  """
  @spec scrubbed_env(env()) :: env()
  def scrubbed_env(extra \\ []) do
    scrubbed = ["ERL_OTP#{:erlang.system_info(:otp_release)}_FLAGS" | @scrubbed]

    Enum.map(scrubbed, &{&1, nil}) ++ extra
  end

  defp path(%__MODULE__{root: root}, relative), do: Path.join(root, relative)

  defp cmd(%__MODULE__{} = deployment, exe, args, env) do
    System.cmd(exe, args,
      cd: deployment.cd,
      stderr_to_stdout: true,
      env: scrubbed_env(deployment.env ++ env)
    )
  end

  defp ok!({output, 0}, _program, _args), do: String.trim(output)

  defp ok!({output, status}, program, args) do
    raise """
    #{program} #{Enum.join(args, " ")} exited with #{status}

    #{output}
    """
  end
end
