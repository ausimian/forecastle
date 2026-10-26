# Forecastle

Forecastle prepares Elixir releases for hot-code upgrades. It adds Castle's
release commands, places appups and relups, and generates relups during release
assembly.

Forecastle also provides:

- `mix compile.appup`, which compiles appup source into an application's `ebin`
  directory.
- `mix castle.appup`, which checks whether an appup covers the modules that
  changed.
- `mix castle.appup.gen`, which drafts missing appup entries.
- `mix castle.relup`, which generates and checks relups.
- `Forecastle.UpgradeCase` and `Forecastle.Deployment` for upgrade tests.

The tasks use the Castle name because applications depend on Castle. Forecastle
is its build-time dependency.

## Installation

Applications should depend on
[Castle](https://hexdocs.pm/castle/readme.html), which brings in Forecastle.

Projects that only compile appups can exclude Castle from the runtime release:

```elixir
def deps do
  [
    {:castle, "~> 1.0", runtime: false}
  ]
end
```

Projects that build Castle-managed releases need the runtime dependency:

```elixir
def deps do
  [
    {:castle, "~> 1.0"}
  ]
end
```

Use Castle and Forecastle from the same release series. Forecastle 1.x leaves
Mix's `sys.config` in place; Castle 1.x resolves target configuration at install
time. Older Castle releases expect the removed `build.config` path and cannot
manage this release layout.

## Integration

Define each release lazily and pass its options to `Castle.customize/1`:

```elixir
defp releases do
  [
    myapp: fn ->
      [include_executables_for: [:unix]]
      |> Castle.customize()
    end
  ]
end
```

`Castle.customize/1` calls `Forecastle.steps/1`, which adds pre-assembly and
post-assembly hooks around `:assemble`, places relup generation before `:tar`,
and adds a final check for late changes to `upgrade_from:`.

Custom release steps keep their order. Generate the relup after every step that
changes the release and immediately before the step that packages it. The
default `[:assemble, :tar]` satisfies this rule.

If a custom step packages the release without `:tar`, place
`&Forecastle.generate_relup/1` immediately before that step. Forecastle keeps an
explicitly placed generator and does not add another. It rejects generation
after `:tar` when `upgrade_from:` is set.

Set or compute `upgrade_from:` in the release definition, or in a step before
`:assemble`. Forecastle resolves the option during pre-assembly and rejects
later changes.

### Build-time changes

Before assembly, Forecastle:

- validates a project-root `relup` and rejects it when `upgrade_from:` is also
  present;
- rejects `require_relup: true` without `upgrade_from:`;
- resolves the baselines named by `upgrade_from:`;
- validates appup sources under `rel/appups`;
- creates a preboot script containing `:sasl`, `:compiler`, `:elixir` and
  `:castle`, which Castle uses to resolve target configuration.

After assembly, Forecastle:

- adds `bin/castle` and an inert `bin/start` used during emulator restarts;
- puts a `CASTLE_ENV_FILE` fragment at the start of `env.sh` and appends
  Castle's startup hook to the end, without changing the standard Mix launcher;
- copies the release's `.rel` file and any staged relup into the release;
- installs dependency appups under `lib/<app>-<vsn>/ebin`.

The startup hook creates `releases/RELEASES` on the first start when the file is
absent, using a short-lived helper VM. If the release root is read-only, the
start warns and continues; the node can run and restart but cannot unpack or
install upgrades until the error is fixed and the node restarted.

The hook also starts OTP heart with no restart command and selects a pending
restart target. Forecastle adds its own `-heart` only after the helper exits,
and never beside a `-heart` the deployment already supplies. A `-heart` in
`rel/vm.args.eex` reaches only the system VM. One in `ELIXIR_ERL_OPTIONS` or
`ERL_*FLAGS` also reaches the helper, which then prints heart's lifecycle
messages on the first start.

Projects may supply `rel/env.sh.eex`. Its contents run after the
`CASTLE_ENV_FILE` fragment and before the startup hook.

### Environment file

A deployment whose `runtime.exs` reads environment variables can keep them in
a file per version and name it in `CASTLE_ENV_FILE`. A start then reads the
file through `env.sh`. A Castle that supports the file
([castle#56](https://github.com/ausimian/castle/issues/56)) reads it too, when a
hot install or a commit resolves the new version's configuration, so both
configure the release from the same values. Set `CASTLE_ENV_FILE` where the
supervisor starts the release, for example in a systemd unit or a container
spec. It stays the same from one version to the next, and changing it requires
a restart.

```ini
# systemd unit
Environment=CASTLE_ENV_FILE=castle.env
```

```sh
# releases/1.4.0/castle.env, written by the deployment after unpacking 1.4.0
DATABASE_URL=ecto://db.internal/myapp
FEATURE_X=on
unset LEGACY_FLAG
```

- A relative path names a file in the version's own directory under the
  release root, `releases/<vsn>/`, where its `env.sh` is. Each version reads
  its own file, so a rollback reads the file the version it returns to was
  installed with, and removing a version removes its file. The file is not part
  of the release tarball: whatever deploys a version writes it after
  `bin/castle unpack` and before `bin/castle install`.
- An absolute path names one file that every version reads. When the variable
  is unset or empty, nothing happens.
- The file is a shell script, run by `/bin/sh` with `set -a`, so each plain
  `KEY=value` line is exported.
- It runs before the project's own `env.sh` content, which can use the values,
  and it runs for every launcher command: `start`, `daemon`, `eval`, `rpc`,
  `remote` and `stop`. A file that sets `RELEASE_COOKIE` or `RELEASE_NODE`
  therefore reaches the commands that connect to the node.
- If the file is missing or unreadable, the command stops with
  `ERROR: CASTLE_ENV_FILE names <path>, which is not a readable file`. A command
  in the file that fails also stops it. That includes `bin/<app> stop` and every
  `bin/castle` command. A Castle that supports the file refuses an install or
  commit in the same cases.
- To remove a variable that an earlier version's file set, write `unset NAME`.
  That removes it at boot, even when the supervisor set it, and at a hot
  install. Leaving the line out is not enough: the running node holds the old
  value from its own file, Castle reads the new file over the node's
  environment, and a restart into a pending version reads the pending version's
  file over the replaced version's. The value survives until a plain restart.
- So a file can be read over an environment that already holds values from it,
  or from another version's. Write assignments and `unset`, and do not append
  to an existing value, as `PATH=$PATH:/opt/bin` does.
- Do not set `RELEASE_ROOT`, `RELEASE_VSN`, `RELEASE_COMMAND`, `RELEASE_NAME` or
  `CASTLE_ENV_FILE` in it. The launcher has already acted on them, which is also
  true of a project's own `env.sh`.

The fragment is in releases built by this version of Forecastle onwards. Until
the permanent version is one of those, `bin/castle` and other `rpc` commands do
not read the file, and neither does the first pass of a restart into a pending
version. The pending version's own `env.sh` reads it before the node boots.
`rpc` commands, `bin/castle` among them, read the permanent version's file.
There is no equivalent for the Windows `.bat` launcher.

Forecastle does not alter runtime configuration. Mix retains control of
`:runtime_config_path`, `:config_providers`, `sys.config`, and normal boot-time
configuration expansion.

## Managing releases

Use the standard Mix launcher to control the running node:

```shell
myapp/bin/myapp start
myapp/bin/myapp remote
myapp/bin/myapp rpc "..."
myapp/bin/myapp stop
```

Use `bin/castle` to manage versions:

```shell
# List known releases and their status.
myapp/bin/castle releases

# Check whether this node can be upgraded. Success prints nothing.
myapp/bin/castle upgradable

# Stage and install myapp-0.1.1.tar.gz from myapp/releases.
myapp/bin/castle unpack 0.1.1
myapp/bin/castle install 0.1.1

# Make the installed version permanent.
myapp/bin/castle commit

# Remove an unused version.
myapp/bin/castle remove 0.1.1
```

`unpack` and `install` refuse a node using the fallback release record created
by `:release_handler`. Fix the reported `RELEASES` problem and restart before
trying again. Replacing the file does not change the record already loaded by a
running node.

### Emulator restarts

`bin/castle install` handles hot upgrades and one-stage `restart_emulator`
transitions. For a restart transition, it waits until the target release has
restarted and finished booting.

Run the release under an external supervisor such as systemd, Docker,
Kubernetes or runit. The release process exits during the upgrade; Castle's
`bin/start` and heart configuration do not restart it.

The installed version remains provisional until `bin/castle commit`. The
installation restart boots the target, but a later ordinary restart returns to
the previous permanent release until commit.

Forecastle does not generate or accept the two-stage `restart_new_emulator`
transition.

## Appup compiler

Write the appup as an Elixir expression:

```elixir
{
  ~c"0.1.1",
  [
    {~c"0.1.0", [{:update, MyApp.Server, {:advanced, []}}]}
  ],
  [
    {~c"0.1.0", [{:update, MyApp.Server, {:advanced, []}}]}
  ]
}
```

Configure the source and compiler in `mix.exs`:

```elixir
def project do
  [
    appup: "appup.exs",
    compilers: Mix.compilers() ++ [:appup]
  ]
end
```

The compiler writes `<app>.appup` into `ebin` on every build. It removes stale
output when the source or `:appup` setting disappears. To disable an appup for
an environment, keep `:appup` in `:compilers` and set the project key to `nil`.

## Checking and drafting appups

`mix castle.appup` compares two builds and reports changed modules that the
appup does not load or remove:

```shell
mix castle.appup --from tar:artifacts/myapp-1.0.0.tar.gz
```

`--to` defaults to the current build. Both switches accept the baseline specs
described below. Repeat `--app` to select applications; by default the task
checks owned applications and umbrella children.

The command exits non-zero when it finds a coverage error, including:

- a changed or added module that no instruction loads;
- a removed module that no instruction deletes;
- a module that an edge both loads and deletes;
- duplicate instructions for a module;
- a changed module missing from the application's `.app` file;
- an invalid instruction or a missing from-version entry;
- changed application code without an application version change.

An instruction for an unchanged module produces a warning. An emulator-restart
edge needs no module-level coverage.

The check verifies coverage, not full appup validity. Relup generation remains
the authority on whether `:systools` accepts the script. Module comparisons use
the BEAM md5 and persisted attributes, avoiding differences caused only by
stripping or documentation.

Use `mix castle.appup.gen` to draft missing entries:

```shell
mix castle.appup.gen --from tar:artifacts/myapp-1.0.0.tar.gz
```

Review the generated source before committing it. The task identifies changed
modules but cannot choose the correct state-transition instructions for an
application.

## Appups for dependencies

Projects may supply appups for dependencies under `rel/appups`:

```text
rel/appups/jason-1.4.0-1.4.2.exs
```

The file uses the same appup form:

```elixir
{~c"1.4.2", [{~c"1.4.0", [{:load_module, Jason.Encoder}]}],
 [{~c"1.4.0", [{:load_module, Jason.Encoder}]}]}
```

Draft one with:

```shell
mix castle.appup.gen --app jason --from <spec>
```

Forecastle validates these sources before assembly and writes them to
`lib/<app>-<vsn>/ebin/<app>.appup`. It never changes `deps/`.

The build rejects stale filenames, owned applications, malformed appups,
missing entries, ambiguous version matches, unreadable appups supplied by the
dependency, and non-`.exs` files other than dotfiles. It also rejects overlays
that replace the assembled appup and applications with no target `ebin`
directory. Retry post-assembly failures with `mix release --overwrite`.

When a dependency ships its own appup, Forecastle merges the project entries
before the dependency's entries. Project entries therefore override matching
transitions while preserving the rest of the dependency appup.

To check the installed dependency appup, point `mix castle.appup --app <dep>` at
an assembled `rel:` or `tar:` target.

## Relup generation

### During assembly

Set `upgrade_from:` to a list of supported baselines:

```elixir
defp releases do
  [
    myapp: fn ->
      [
        include_executables_for: [:unix],
        upgrade_from: ["tar:artifacts/myapp-1.0.0.tar.gz"]
      ]
      |> Castle.customize()
    end
  ]
end
```

Forecastle resolves the baselines before assembly, then generates both upgrade
and downgrade instructions immediately before `:tar`. The strategy is `auto`.
One `mix release` therefore produces a tarball containing its relup.

Omitting `upgrade_from:` skips generation. Forecastle rejects an empty or
malformed value, duplicate options, unresolved baselines, late changes, and a
project-root `relup` supplied at the same time.

A project that ships hot upgrades can require a relup with `require_relup: true`.
Forecastle then rejects a build without `upgrade_from:` before assembly, rather
than producing a release that only fails at `bin/castle install`. A project-root
`relup` does not satisfy the requirement. Set it conditionally so that local
builds and `ref:` baseline builds can still leave `upgrade_from:` out:

```elixir
require_relup: System.get_env("CI") != nil and System.get_env("CASTLE_BASELINE") == nil
```

`require_relup:` takes `true` or `false`, and reads `nil` as `false`; any other
value is an error.

A failure after assembly leaves the target directory in place. Retry with
`mix release --overwrite`.

A `ref:` baseline builds that revision. Set no `upgrade_from:` while
`CASTLE_BASELINE` is present, or Forecastle will reject the recursive baseline
build. Leave `require_relup:` false there too: the baseline build inherits the
environment, so a requirement keyed on `CI` alone would reject it for having no
`upgrade_from:`.

### For an existing target

Generate a relup for an assembled target with `mix castle.relup`:

```shell
mix castle.relup \
  --target myapp/releases/0.1.1/myapp \
  --fromto myapp/releases/0.1.0/myapp
```

`--target` names the target `.rel` file without its extension. Supply at least
one of `--fromto`, `--upfrom` and `--downto`. The task writes `relup` to the
project root by default; `--outdir` selects an existing directory.

### Baseline specs

Relup generation, appup tasks and the test harness share one baseline grammar:

| Spec | Source |
| --- | --- |
| `rel:path/to/release` | An assembled release, named by its `.rel` path without the extension |
| `tar:path/to/release.tar.gz` | A release tarball |
| `ref:git-ref` | A git revision built in a temporary worktree |

A path without a prefix means `rel:`. `--target` is always a path, not a
baseline spec.

Prefer `tar:` when the shipped artifact is available. Relups select a transition
by version string; a baseline rebuilt with different dependencies or tools may
not match the deployed code.

Forecastle caches resolved `tar:` and `ref:` baselines under
`_build/castle/baselines`. Tar entries use the artifact digest. Git entries use
the resolved commit, Mix environment and target, and the Elixir and ERTS
versions. Cache this directory in CI.

Writes are staged and renamed into place. A failed generation leaves an older
relup untouched, and assembly checks that a staged relup targets the release
being built.

### Strategies

`mix castle.relup` supports three strategies:

```shell
# Use hot upgrades where possible.
mix castle.relup --target ... --fromto ...

# Require every transition to remain hot.
mix castle.relup --target ... --fromto ... --hot

# Restart the emulator for every transition.
mix castle.relup --target ... --fromto ... --restart
```

`auto`, the default, generates hot transitions unless the ERTS changes or an
unowned application changes version without a matching appup. It classifies
upgrade and downgrade directions separately. A missing appup for an owned
application remains an error.

`--hot` rejects any transition that requires a restart. `--restart` emits one
`restart_emulator` instruction per transition and does not read appups.

Forecastle prints every restart edge and its reason. It rejects
`restart_new_emulator`, including instructions inserted by an appup.

### Dry runs

Add `--dry-run` to generate and validate the plan without writing the relup:

```shell
mix castle.relup --target ... --fromto ... --hot --dry-run
```

The exit status reports whether generation succeeded. A dry run cannot detect
write failures at the destination. It still resolves and caches baselines, so
`tar:` may unpack an artifact and `ref:` may build a revision.

## Testing an upgrade

Test an upgrade by starting the shipped release, installing the next version,
and asserting that application state and code both moved as expected.

`Forecastle.UpgradeCase` provides a scratch path for each test module.
`Forecastle.Deployment` deploys baselines, controls the release, and runs Castle
commands.

```elixir
defmodule MyApp.UpgradeTest do
  use Forecastle.UpgradeCase

  @moduletag :upgrade

  @shipped "tar:artifacts/myapp-1.0.0.tar.gz"
  @next "_build/prod/myapp-1.1.0.tar.gz"

  setup_all %{scratch: scratch} do
    deployment = Deployment.deploy!(@shipped, Path.join(scratch, "deploy"))
    on_exit(fn -> Deployment.stop(deployment) end)

    Deployment.start!(deployment)
    Deployment.rpc!(deployment, "IO.puts(MyApp.Counter.bump())")

    Deployment.stage!(deployment, @next)
    Deployment.castle!(deployment, ["unpack", "1.1.0"])
    Deployment.castle!(deployment, ["install", "1.1.0"])
    Deployment.castle!(deployment, ["commit"])

    {:ok, deployment: deployment}
  end

  test "moves to 1.1.0 without losing the count", %{deployment: deployment} do
    assert Deployment.rpc!(deployment, "IO.puts(inspect(MyApp.Counter.info()))") ==
             ~s({"1.1.0", 1})

    assert Deployment.version(deployment) == "1.1.0"
  end
end
```

Mark these tests so the ordinary suite can exclude them; each test starts a
release. Always stop a deployment in `on_exit/1`.

Assert the code version as well as retained state. A missing appup instruction
can leave old code serving calls while the release reports the new version.

Use `Deployment.install_supervised!/3` for a `restart_emulator` transition. It
acts as the external supervisor while `bin/castle install` waits for the release
to return. Use `Deployment.castle!/3` for hot installs.

`deploy!/3` copies the baseline into a separate destination and refuses to
replace a running deployment. `start!/2` and `:boot_timeout` bound launcher and
boot waits but do not stop a process that outlives a timeout. Increase
`:boot_timeout` for applications that perform slow startup work.

Deployment commands remove inherited release-launcher and emulator variables so
the test does not accidentally use the developer's shell configuration.
