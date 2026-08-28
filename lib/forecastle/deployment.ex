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

  **Every variable the generated launcher reads as a default is unset**, and that
  is a rule rather than a list: `bin/<name>` takes `RELEASE_VM_ARGS`,
  `RELEASE_BOOT_SCRIPT`, `RELEASE_MODE`, `RELEASE_DISTRIBUTION` and the rest from
  the environment where they are set, so one of them inherited from a shell or a
  CI image does not merely add a flag - it points the release at a different args
  file, a different boot script, a different configuration or a different
  distribution mode. What that produces is a test of a release materially unlike
  the one that would be deployed, presenting as a bug in the release rather than
  as a leaked variable. `Forecastle.DownstreamUpgradeTest` measures the rule
  against the launcher Mix actually generated, so a variable a later Elixir adds
  shows up as a failure rather than as a hole.

  Anything a caller passes is applied after the scrub, so a test that wants one
  of these set says so and gets it.
  """

  # `flunk/1` only. A deployment that never answers is a test failure and wants
  # to be reported as one, but nothing here decides whether an upgrade worked, so
  # nothing here needs the rest of the assertions.
  import ExUnit.Assertions, only: [flunk: 1]

  alias Forecastle.Baseline

  @enforce_keys [:root, :name, :cd]
  defstruct [:root, :name, :cd, env: [], boot_timeout: 20_000]

  @typedoc """
  Environment for a command, in the shape `System.cmd/3` takes it: a `nil` value
  unsets the variable rather than setting it to an empty string.
  """
  @type env :: [{binary(), binary() | nil}]

  @typedoc """
  A release tree, the name of the release inside it, the directory commands are
  run from, the environment every one of them carries, and how long the release
  is given to answer after it has been started.
  """
  @type t :: %__MODULE__{
          root: Path.t(),
          name: binary(),
          cd: Path.t(),
          env: env(),
          boot_timeout: pos_integer()
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
  @exit_timeout 30_000
  @exit_interval 100

  # How often a starting release is asked whether it answers yet. The deadline
  # is the deployment's, since only the project knows what its own cold start
  # costs; this is only the granularity.
  @boot_interval 200

  # How long a deployment already in the destination is given to say whether it
  # is running. It is either up and answers at once or absent and fails at once,
  # so this is only a bound on the third case - wedged - and refusing is what
  # happens when it is reached.
  @probe_timeout 10_000

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
  # The `RELEASE_*` half is every variable the generated launcher takes from the
  # environment where it is set, which is a longer list than the obvious one. The
  # args files are the sharpest - they carry emulator flags, so an inherited one
  # boots the release on another project's `vm.args` - but a boot script, a
  # configuration file, `embedded` versus `interactive`, and `sname` versus
  # `name` each change what the release *is* rather than what it prints, and none
  # of them announces itself. Kept as a rule rather than as a list somebody
  # remembers to extend: `Forecastle.DownstreamUpgradeTest` reads the defaults
  # out of the launcher Mix generated and requires this to cover them.
  @scrubbed ~w(MIX_ENV MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_TARGET
               MIX_QUIET MIX_DEBUG ERL_LIBS ELIXIR_ERL_OPTIONS ERL_AFLAGS
               ERL_FLAGS ERL_ZFLAGS RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS
               RELEASE_ROOT RELEASE_NAME RELEASE_PROG RELEASE_MODE
               RELEASE_DISTRIBUTION RELEASE_BOOT_SCRIPT
               RELEASE_BOOT_SCRIPT_CLEAN RELEASE_SYS_CONFIG
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
    * `:boot_timeout` - how long, in milliseconds, the release is given to answer
      an rpc after `daemon` has returned. Defaults to 20 seconds, which is a
      description of a release that does nothing on the way up: an application
      that runs migrations, warms a cache or waits on a dependency takes longer,
      and its project is the only thing that knows how much longer.
  """
  @spec new(Path.t(), binary(), keyword()) :: t()
  def new(root, name, opts \\ []) when is_binary(root) and is_binary(name) do
    %__MODULE__{
      root: Path.expand(root),
      name: name,
      cd: Path.expand(Keyword.get(opts, :cd, File.cwd!())),
      env: Keyword.get(opts, :env, []),
      boot_timeout: Keyword.get(opts, :boot_timeout, 20_000)
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

    deployment = new(into, release_name!(spec, baseline.rel_path), opts)
    refuse_running!(deployment)

    File.rm_rf!(into)
    File.mkdir_p!(Path.dirname(into))
    File.cp_r!(root, into)

    deployment
  end

  # **A destination that is still running is the one deletion that comes back as
  # a passing test.** A deployment is a stable path, so a run that was
  # interrupted before its `on_exit` - Ctrl-C, a killed CI job - leaves a daemon
  # running out of this exact tree. Emptying it does not stop that node: it goes
  # on holding the release's distribution name, and the next `start!/2` either
  # loses the name to it or, worse, `await_boot!/1` gets an answer from it. The
  # test then reads a system running the previous run's code out of a directory
  # that no longer exists, and the from-version assertions pass.
  #
  # Refused rather than stopped. Something is running here that this run did not
  # start, and taking it down on a guess is a bigger decision than declining to
  # delete it.
  #
  # **The question is asked of the destination's own releases, not of the one
  # being deployed.** What is at risk is whatever is running *there*, and a
  # previous run may have put a different release in this directory - or the same
  # one under a name the project has since changed. Asking `bin/<incoming name>`
  # answers about a launcher that may not even be present. The caller's `:env` is
  # carried into the probe for the same reason: a deployment started with a node
  # name or cookie of its own is only reachable with them.
  defp refuse_running!(%__MODULE__{} = deployment) do
    deployment
    |> deployed_names()
    |> Enum.each(&refuse_running_release!(deployment, &1))
  end

  # Listed rather than globbed, because the destination is a path somebody chose
  # and `Path.wildcard/1` would read it as a pattern. A workspace called
  # `build[1]` makes `[1]` a character class matching `build1`, so the glob finds
  # none of the releases that are really there, the check below is asked about
  # nothing, and a live deployment is deleted - which is the failure this guard
  # exists to prevent, reintroduced through the guard itself. There is no
  # escaping helper for `Path.wildcard/1`, and there is nothing here a glob was
  # buying: two `File.ls/1` calls say it literally.
  defp deployed_names(%__MODULE__{root: into}) do
    releases = Path.join(into, "releases")

    releases
    |> entries()
    |> Enum.flat_map(&entries(Path.join(releases, &1)))
    |> Enum.filter(&(Path.extname(&1) == ".rel"))
    |> Enum.map(&Path.rootname/1)
    |> Enum.uniq()
  end

  defp entries(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      {:error, _not_a_directory} -> []
    end
  end

  # Through `cmd/4`, so the probe runs from the directory this deployment runs
  # its commands from and with the environment it carries. Neither is
  # decoration: a release started from a working directory of its own may have
  # been given a *relative* `RELEASE_VM_ARGS` - which is a case
  # `Forecastle.UpgradeTest` covers on purpose - and a probe made from somewhere
  # else cannot resolve it. The launcher fails, that reads as "nothing running",
  # and the live deployment is deleted.
  defp refuse_running_release!(%__MODULE__{root: into} = deployment, name) do
    launcher = Path.join(into, "bin/#{name}")

    if File.regular?(launcher) do
      case within(deployment, launcher, ["pid"], [], @probe_timeout) do
        {output, 0} -> refuse_deployment!(into, name, launcher, String.trim(output))
        :timeout -> refuse_unanswered!(into, name, launcher)
        _not_running -> :ok
      end
    end
  end

  defp refuse_deployment!(into, name, launcher, pid) do
    Mix.raise(
      "#{into} already holds a #{name} deployment, and it is running as process " <>
        "#{pid}. Deploying would empty the directory underneath it without stopping " <>
        "it, leaving a node that still answers to this release's name. Stop it " <>
        "first - `#{launcher} stop`."
    )
  end

  # **A question that timed out is not an answer of "no".** The launcher's `rpc`
  # reaches `:erpc.call/4` with no timeout, so a node that accepts a distribution
  # connection and then wedges - suspended, stuck in its own `start/2` - never
  # replies. Unbounded that hangs `deploy!/3` outright, and treating the timeout
  # as "nothing running" would delete the wedged node's tree underneath it, which
  # is the case this check exists for. So the deadline refuses.
  defp refuse_unanswered!(into, name, launcher) do
    Mix.raise(
      "#{into} already holds a #{name} deployment, and it did not answer within " <>
        "#{div(@probe_timeout, 1000)}s. A node that accepts a connection and does not " <>
        "reply is wedged rather than absent, and deploying would empty the directory " <>
        "underneath it. Stop it first - `#{launcher} stop`."
    )
  end

  # **Out of the term, not off the filename**, because an unpacked release holds
  # two `.rel` files and the filenames are not both the release's name.
  # `release_handler:do_unpack_release/4` copies `releases/<name>-<vsn>.rel` into
  # the version directory beside Mix's own `<name>.rel`, byte-identical - see
  # *An unpacked release holds two `.rel` files* in `AGENTS.md` - and
  # `Forecastle.Baseline` may hand back either, since it de-duplicates on the
  # consulted term and `Path.wildcard/1` sorts `my_app-1.0.0.rel` ahead of
  # `my_app.rel`. Taking the basename of that one names the launcher
  # `bin/my_app-1.0.0`, which does not exist, and every command this deployment
  # makes fails on it.
  #
  # The term says what the release is called and the filename only sometimes
  # does, so the term is what is read.
  defp release_name!(spec, rel_path) do
    case :file.consult(to_charlist(rel_path <> ".rel")) do
      {:ok, [{:release, {name, _vsn}, _erts, _apps} | _]} ->
        to_string(name)

      _unreadable ->
        Mix.raise(
          "#{spec} resolved to #{rel_path}.rel, which does not read as a release: " <>
            "expected a `{release, {Name, Vsn}, {erts, _}, _}` term."
        )
    end
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
  #
  # **On the physical paths, because `Path.expand/2` is lexical.** It collapses
  # `.` and `..` and stops there, so two names for one directory - `/tmp/x` and
  # `/private/tmp/x` on a Mac, anything reached through a symlinked parent - come
  # out as different segment lists and read as no overlap at all. What that
  # permits is the deletion this check exists to prevent: `File.rm_rf!/1` follows
  # an aliased parent perfectly well, so the source release is removed and the
  # copy that was to follow it fails on a directory that is no longer there.
  defp contains?(outer, inner) do
    List.starts_with?(Path.split(physical(inner)), Path.split(physical(outer)))
  end

  # `pwd -P` prints the directory with every symlink resolved, and it is POSIX.
  # Run through `System.cmd/3`'s `:cd`, which moves nothing outside the child -
  # `File.cd/1` moves the whole operating system process, and this repository
  # refuses that on principle (see `Forecastle.BaselineTest`'s moduledoc). A
  # destination usually does not exist yet, so what is resolved is its nearest
  # existing ancestor with the rest of the name put back on.
  #
  # A host with no `pwd` falls back to the lexical path, which is what this
  # compared before and is a check that still answers every case not reached
  # through a link. Refusing every deployment on a missing `pwd` would be the
  # worse trade for a harness whose job is to run other people's tests.
  defp physical(path) do
    {existing, rest} = deepest_existing(path, [])

    case System.cmd("pwd", ["-P"], cd: existing, stderr_to_stdout: true) do
      {output, 0} -> Path.join([String.trim(output) | rest])
      _no_pwd -> path
    end
  end

  defp deepest_existing(path, rest) do
    parent = Path.dirname(path)

    cond do
      File.dir?(path) -> {path, rest}
      parent == path -> {path, rest}
      true -> deepest_existing(parent, [Path.basename(path) | rest])
    end
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

  **What the deadline does is fail the test, and that is all it does.** Nothing
  here can reach the operating system process behind `System.cmd/3` - closing
  the port does not terminate the program on the other end of it - so a launcher
  that hung is still hung when the failure is reported, and a boot that was
  merely slow may finish afterwards and leave a node running. The same goes for
  the install in `install_supervised/3`. Both are already-failing situations
  that somebody is about to look at, and killing a real deployment on a guess
  would take away what they came to look at; what would not be acceptable is the
  harness leaving the impression that it had tidied up, so it says here that it
  has not. `:boot_timeout` is where a release that is slow rather than stuck
  belongs.
  """
  @spec start!(t(), env()) :: binary()
  def start!(%__MODULE__{} = deployment, env \\ []) do
    started = Task.async(fn -> launcher!(deployment, ["daemon"], env) end)

    # `nil` and nothing else is the deadline. `Task.async/1` links, so a launcher
    # that exits non-zero normally takes this process down with `launcher!/3`'s
    # message before `Task.yield/2` returns at all - measured: `setup_all` does
    # not trap exits, and the raise arrives as an `(EXIT from ...)` carrying the
    # launcher's own output. But a caller that *does* trap them gets
    # `{:exit, reason}` here, and a wildcard called that a 180-second hang and
    # said there was no output to report, which is a description of a different
    # failure entirely.
    output =
      case Task.yield(started, @start_timeout) do
        {:ok, output} -> output
        nil -> abandoned!(started, deployment)
        {:exit, reason} -> flunk("#{deployment.root} could not be started: #{inspect(reason)}")
      end

    # The same environment the start was given, because it may be what says
    # which node this is: `RELEASE_NODE` and `RELEASE_COOKIE` are both scrubbed,
    # so a start carrying its own would come up under that identity and then be
    # asked for by the default one - a release that started perfectly, reported
    # as one that never answered.
    await_boot!(deployment, env)
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

  **It is bounded, and of all the rpcs here this is the one that has to be.**
  `bin/<name> stop` is an rpc to `System.stop/0`, so a node that accepted a
  distribution connection and then wedged never answers it - and the reason that
  matters more here than elsewhere is *where* this is called from. Every other
  command runs inside a test, under the module's ExUnit timeout; a teardown runs
  after one, and what it would bury is the failure that had just been reported.
  A suite whose `await_boot!/2` correctly timed out would sit in teardown for the
  whole module timeout and then finish with an `on_exit callback` error, which
  says nothing about the boot.

  Answers `:timeout` in that case, which is neither a stop nor a failure to find
  anything to stop, and should not be mistaken for either.
  """
  @spec stop(t(), env()) :: {binary(), non_neg_integer()} | :timeout
  def stop(%__MODULE__{name: name} = deployment, env \\ []) do
    within(deployment, Path.join(deployment.root, "bin/#{name}"), ["stop"], env, @probe_timeout)
  end

  @doc """
  The operating system pid of the running release, as the release reports it.

  `bin/<name> pid` is an rpc, so this is the beam's own `System.pid/0` rather
  than anything about the process that asked - which is what makes it usable both
  for telling one incarnation of the node from another and for waiting on the
  first to go away.
  """
  @spec os_pid(t(), env()) :: binary()
  def os_pid(%__MODULE__{name: name} = deployment, env \\ []) do
    deployment
    |> within(Path.join(deployment.root, "bin/#{name}"), ["pid"], env, @probe_timeout)
    |> answered!(deployment, "pid")
    |> only_pid!(deployment)
  end

  # **Bounded, because this is the harness asking a node whose health it does not
  # know.** `install_supervised/3` reads the pid *before* it starts the install
  # task or the reboot wait, so an unbounded read there is a wedged node stalling
  # the whole upgrade before any of that function's own deadlines exist.
  #
  # That is the line: the rpcs this module makes on its own account -
  # `await_boot!/2`'s probe, `deploy!/3`'s liveness check, `stop/1`, and this -
  # are bounded, because each of them can meet a node that accepts a connection
  # and never replies. The ones a *project* makes through `rpc!/3`, `castle!/3`
  # or `launcher!/3` are not, because their duration is the project's business -
  # an install legitimately takes minutes - and the module's own ExUnit timeout
  # is the backstop for them.
  defp answered!(:timeout, deployment, command) do
    flunk(
      "bin/#{deployment.name} #{command} did not answer within " <>
        "#{div(@probe_timeout, 1000)}s. A node that accepts a distribution connection " <>
        "and then does not reply is wedged rather than absent."
    )
  end

  defp answered!(result, deployment, command), do: ok!(result, deployment.name, [command])

  # **What the launcher printed is not only the answer.** Every command here runs
  # with `stderr_to_stdout`, so a project's own `env.sh` writing a line on the way
  # past arrives in front of the pid - Forecastle's fragment says nothing on a
  # `pid`, but nothing stops a project's from saying something on every
  # invocation.
  #
  # That matters because of what this value is *for*: `install_supervised/3`
  # waits on it with `ps -p`. Handed a warning and a number, `ps` rejects the
  # whole string, which reads here as "the process has gone" - so the wait ends
  # at once and a second node is started beside one that still holds the
  # distribution name. The stale-node failure, reached through the reading of a
  # pid.
  #
  # The pid is the last thing printed and is entirely digits. Anything else is
  # refused rather than guessed at, because a guess here is that failure again.
  defp only_pid!(output, deployment) do
    answer =
      output |> String.split("\n", trim: true) |> List.last() |> to_string() |> String.trim()

    if Regex.match?(~r/\A\d+\z/, answer) do
      answer
    else
      flunk(
        "bin/#{deployment.name} pid did not report an operating system pid. " <>
          "It printed:\n\n#{output}"
      )
    end
  end

  @doc """
  Waits until the release accepts an rpc, or fails the test.

  The deadline is the deployment's `:boot_timeout`. A release that does nothing
  on the way up answers in a second or two; one that runs migrations or waits on
  a dependency does not, and how long it should be given is a property of the
  project rather than of this harness.

  It is a budget for waiting rather than a stopwatch, and is approximate to
  within one probe: a probe already in flight is allowed to finish, and one is
  always made even when the whole deadline is shorter than the polling interval.
  Erring on the side of patience is deliberate - the alternative is failing a
  release that answered a fraction of a second after an arbitrary number.

  `env` is the environment the rpc is made with, and it is not decoration: it is
  how a release started under a node name or cookie of its own is reached again.
  """
  @spec await_boot!(t(), env()) :: :ok
  def await_boot!(%__MODULE__{} = deployment, env \\ []) do
    timeout = deployment.boot_timeout

    booted!(deployment, env, timeout, deadline(timeout))
  end

  # A wall-clock deadline rather than a count of attempts, and the probe is asked
  # before the deadline is consulted - so a `:boot_timeout` shorter than the
  # polling interval still gets one real question rather than being answered
  # from arithmetic.
  defp booted!(deployment, env, timeout, deadline) do
    case probe(deployment, env, deadline) do
      {_output, 0} ->
        :ok

      _not_yet ->
        keep_waiting!(deadline, fn -> booted!(deployment, env, timeout, deadline) end, fn ->
          flunk("#{deployment.root} did not accept an rpc within #{div(timeout, 1000)}s")
        end)
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  # Sleep and go round again while there is budget, and hand over to the caller's
  # own account of the failure when there is not. Never *past* the deadline: a
  # probe that failed quickly with 10ms left should not sleep a whole interval
  # and ask again a tenth of a second late.
  defp keep_waiting!(deadline, again, give_up) do
    left = remaining(deadline)

    if left > 0 do
      Process.sleep(min(@boot_interval, left))
      again.()
    else
      give_up.()
    end
  end

  # **Each probe is bounded, not merely the number of them.** `bin/<name> rpc` is
  # `elixir --rpc-eval`, which reaches `:erpc.call/4` - the arity with no timeout
  # argument, so `:infinity`. A node that has come up far enough to accept a
  # distribution connection and then wedged therefore answers nothing, for ever,
  # and distribution is up long before the application is: a project whose own
  # `start/2` blocks is an ordinary way to get there. Without a bound the loop
  # below never runs a second time, `:boot_timeout` is never consulted again, and
  # the suite stops instead of failing - which is the hang `start!/2` puts a
  # deadline on one layer up, arrived at from underneath.
  #
  # At least one interval, so that a very short deadline still buys a real
  # attempt.
  defp probe(%__MODULE__{name: name} = deployment, env, deadline) do
    within(
      deployment,
      Path.join(deployment.root, "bin/#{name}"),
      ["rpc", "IO.puts(:booted)"],
      env,
      max(remaining(deadline), @boot_interval)
    )
  end

  # A command with a deadline, answering `:timeout` when it has one. Every rpc
  # this module makes needs this: `bin/<name> rpc` is `elixir --rpc-eval`, which
  # reaches `:erpc.call/4` - the arity with no timeout argument - so a node that
  # accepts a connection and never replies is answered forever.
  #
  # `Task.shutdown/2` reaches the Elixir process and not the launcher behind it,
  # for the reason `start!/2` records.
  defp within(deployment, exe, args, env, timeout) do
    asking = Task.async(fn -> cmd(deployment, exe, args, env) end)

    case Task.yield(asking, timeout) || Task.shutdown(asking, :brutal_kill) do
      {:ok, answer} -> answer
      _no_answer -> :timeout
    end
  end

  @doc """
  Waits until the operating system process `pid` is gone, or fails the test.

  Asked of the operating system rather than of the node: a node that has stopped
  answering rpc is not necessarily a process that has exited, and starting the
  replacement while the old beam still holds the distribution port is how a
  supervised restart turns into a name clash instead of a boot.
  """
  @spec await_exit!(binary(), pos_integer()) :: :ok
  def await_exit!(pid, timeout \\ @exit_timeout) when is_integer(timeout) do
    exited!(pid, timeout, deadline(timeout))
  end

  # A wall-clock deadline, like every other wait here. An attempt count of
  # `div(timeout, @exit_interval)` throws the remainder away, so a 250ms budget
  # gave up after 200 and a process that exited at 220 was reported as still
  # running - and a budget under one interval gave up without looking at all.
  # Asked before the deadline is consulted, so the question always happens.
  defp exited!(pid, timeout, deadline) do
    if running?(pid) do
      keep_waiting!(deadline, fn -> exited!(pid, timeout, deadline) end, fn ->
        flunk("process #{pid} was still running #{div(timeout, 1000)}s later")
      end)
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
    pid = os_pid(deployment, env)

    installing = Task.async(fn -> castle(deployment, ["install", vsn], env) end)

    await_reboot!(installing, pid, div(@exit_timeout, @exit_interval))
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
            "#{div(@exit_timeout, 1000)}s after it was asked for. " <>
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
    Enum.map(erl_otp_flag_vars() ++ @scrubbed, &{&1, nil}) ++ extra
  end

  # `ERL_OTP<major>_FLAGS` cannot be written into the list, because its name
  # carries an OTP major - and **not necessarily this one**. A `tar:` baseline is
  # the artefact that shipped, which may well have been built against a different
  # OTP than the VM running the tests, and the `erlexec` inside that release
  # reads its own major's variable. Asking `:erlang.system_info/1` what this VM
  # is therefore scrubs the wrong name for exactly the cross-ERTS deployment this
  # harness exists to make testable.
  #
  # So the environment is asked which of them are set, rather than the VM being
  # asked what it is. This VM's own name is included whether or not it is set, so
  # that the guarantee does not depend on the variable happening to be there.
  defp erl_otp_flag_vars do
    current = "ERL_OTP#{:erlang.system_info(:otp_release)}_FLAGS"

    System.get_env()
    |> Map.keys()
    |> Enum.filter(&Regex.match?(~r/\AERL_OTP\d+_FLAGS\z/, &1))
    |> Enum.concat([current])
    |> Enum.uniq()
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
