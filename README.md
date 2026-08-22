# Forecastle

Build-time support for hot-code upgrades.

`Forecastle` provides build-time support for the generation of releases that correctly support hot-code 
upgrades. This includes:

  - Copying appup and relup files into place.
  - Organising the generated release structure so that it's ready for hot-code upgrades.
  - Adding a `bin/castle` command for unpacking and installing releases, alongside
    the standard Mix launcher.

Additionally, `Forecastle` ships with a appup compiler and a mix task for relup generation.

## Installation

`Forecastle` is not intended to be taken as a direct dependency.  Most applications should prefer to
take a dependency on [Castle](https://hexdocs.pm/castle/readme.html) directly which will, in turn 
take a build-time dependency on `Forecastle`.

For projects that don't define a release, but use the `appup` compiler, it's sufficient to 
bring `Castle` in as a build-time dependency:

```elixir
def deps do
  [
    {:castle, "~> 1.0", runtime: false}
  ]
end
```

For projects that _do_ define one or more releases, `Castle` should be brought in
as a runtime dependency:

```elixir
def deps do
  [
    {:castle, "~> 1.0"}
  ]
end
```

### `Castle` and `Forecastle` are a matched pair

Take `Castle` 1.0 or later with a 1.x `Forecastle`, and do not pair a 1.x
`Forecastle` with an older `Castle`. The two halves divide one job between them
and the boundary moved in 1.0: `Forecastle` no longer intercepts configuration at
build time, and `Castle` works out the configuration of the version being
installed for itself, in a temporary VM running that version's own code. That is
`Castle` 1.0's only path: the branch that read the `build.config` `Forecastle`
used to write is gone, along with the file. So a release assembled by a 1.x
`Forecastle` carries the `sys.config` Mix wrote and nothing else, and an older
`Castle` handed one looks for a file that is not there and refuses the install.

Nothing in the build can enforce this. `Forecastle` is a dependency *of*
`Castle`, so it cannot constrain the version of `Castle` that brought it in, and
`Castle`'s own requirement on `Forecastle` is the only constraint there is. Take
both from the same release series.

## Integration

`Forecastle` integrates into the steps of the release assembly process. It requires
that the `Forecastle.pre_assemble/1` and `Forecastle.post_assemble/1` functions are
placed around the `:assemble` step, e.g.:

```elixir
defp releases do
  [
    myapp: [
      include_executables_for: [:unix],
      steps: [&Forecastle.pre_assemble/1, :assemble, &Forecastle.post_assemble/1, :tar]
    ]
  ]
end
```

## Build Time Support

The following steps shape the release at build-time:

### Pre-assembly

In the pre-assembly step:

  - Any `relup` in the project root is read and checked against the version being
    assembled, so that a stale upgrade plan fails the build rather than being
    packaged as this version's.
  - A 'preboot' boot script is created that starts `:sasl`, `:compiler`,
    `:elixir` and `:castle`, and none of the release's own applications. Castle
    boots a temporary VM on this script to work out the configuration of the
    version being installed.

The system is then assembled under the `:assemble` step as normal. Runtime
configuration is Mix's business and is left entirely alone: the file named by
`:runtime_config_path`, the providers declared through `:config_providers`, the
`sys.config` Mix writes and the expansion the standard launcher performs at boot
all behave exactly as they do without `Forecastle`.

### Post-assembly

In the post-assembly step:

  - A `bin/castle` command is added, providing the commands that manage releases.
    The standard `bin/<release>` launcher that Mix generates is left untouched.
  - The generated `env.sh` is extended with a hook. On the **first** start of a
    deployment it creates `releases/RELEASES`, which is what lets the system
    manage its own releases — a short-lived VM, once, and only while that file
    is absent. The release root has to be writable for it to succeed; if it is
    not, the start still proceeds, with a warning, and `bin/castle unpack` and
    `bin/castle install` will later refuse — each reading the running system's
    own release records as it acts — rather than upgrade a system that cannot
    record what it is running. Every start after the first does nothing at all.
    The
    hook is also where the provisional version marker left by a relup that
    restarts the emulator will be consumed. Any `env.sh` the project supplies
    through `rel/env.sh.eex` is preserved, and runs first.
  - The generated _name.rel_ is copied into the `releases` folder as _name-vsn.rel_,
    which is where `release_handler` looks for it when unpacking a tarball.
  - Any checked `relup` is written into the version path of the release.

## Managing Releases

The release itself is controlled through the standard launcher that Mix generates,
which `Forecastle` does not modify:

```shell
> myapp/bin/myapp start
> myapp/bin/myapp remote
> myapp/bin/myapp rpc "..."
> myapp/bin/myapp stop
```

Moving the running system from one version to the next is done through `bin/castle`:

```shell
# List the releases the system knows about, and their status.
> myapp/bin/castle releases

# Ask whether this system can be upgraded from at all. Silence means it can.
> myapp/bin/castle upgradable

# Unpack myapp-0.1.1.tar.gz, which you have placed in myapp/releases.
> myapp/bin/castle unpack 0.1.1

# Make 0.1.1 the version that is running now, without restarting the VM.
> myapp/bin/castle install 0.1.1

# Make it the version that runs on restart too. With no version given, this
# commits whichever version is running.
> myapp/bin/castle commit

# Or, having decided against it, remove it again.
> myapp/bin/castle remove 0.1.1
```

`unpack` and `install` refuse a system that cannot be upgraded from — one that
started without a readable `releases/RELEASES`, and so is running from a release
record OTP made up out of its boot script. Each asks the system itself, as it
acts, rather than trusting an answer given earlier; the refusal names the remedy,
which is a restart.

Version selection on restart needs nothing from `Forecastle`: OTP's
`release_handler` records the committed version in `releases/start_erl.data`,
which is exactly where the standard launcher reads it from.

## The Appup Compiler

You are responsible for writing the [appup](https://www.erlang.org/doc/man/appup.html)
scripts for your application, but `Forecastle` will copy the appup into the `ebin` folder
for you. The steps are as follows:

1. Write a file, in _Elixir form_, describing the application upgrade. e.g.:
   ```elixir
   # You can call the file what you like, e.g. appup.exs,
   {
    '0.1.1', # Code is eval'd so can also: to_charlist(Mix.Project.config[:version]),
     [
      {'0.1.0', [
        {:update, MyApp.Server, {:advanced, []}}
      ]}
     ],
     [
      {'0.1.0', [
        {:update, MyApp.Server, {:advanced, []}}
      ]}
     ]
   }
   ```
   This file will typically be checked in to SCM.
2. Add the appup file to the Mix project definition in mix.exs and add the
   `:appup` compiler.
   ```elixir
   # Mix.exs
   def project do
     [
       appup: "appup.exs", # Relative to the project root.
       compilers: Mix.compilers() ++ [:appup]
     ]
   end
   ```

The compiler owns `<app>.appup` for the whole of its life. It rewrites it on every
build, and deletes it again if the source goes away or the `:appup` key is dropped,
so that an incremental build cannot ship upgrade instructions belonging to an
earlier version. Naming a file that does not exist is a compilation error: the
project asked for an appup and cannot have one.

That housekeeping only happens while the compiler is registered. To turn an appup
off for some environments, leave `:appup` in `:compilers` and let the `:appup` key
be `nil` - the output is removed and nothing further is reported. Taking the
compiler out of `:compilers` instead stops it running, and an output an earlier
build wrote stays where it is.

## Relup Generation

Forecastle contains a mix task, `forecastle.relup`, that simplifies the generation of
the relup file. Assuming you have two _unpacked_ releases e.g. `0.1.0` and `0.1.1` 
and you wish to generate a relup between them:

```shell
> mix forecastle.relup --target myapp/releases/0.1.1/myapp --fromto myapp/releases/0.1.0/myapp
```

If the generated file is in the project root, it will be copied during
post-assembly to the release. That is where the task writes it by default;
`--outdir` sends it somewhere else, which post-assembly will not find, and a
relative `--outdir` is resolved from the directory the task is run in rather
than from the project root. The directory has to exist already: a mistyped one
that sprang into existence is how a relup ends up somewhere nothing looks for.

At least one of `--fromto`, `--upfrom` and `--downto` is required: a relup with
no transitions in it is not an upgrade plan.

The task fails if it could not generate the relup, so a build pipeline can tell,
and a failure writes nothing at all - so any earlier relup is still sitting where
post-assembly looks for one, rather than having been replaced by a plan that was
then refused. Assembly then checks the relup it is about to package really is
this release's upgrade plan - the right target version, with the upgrade and
downgrade sections `release_handler` will read - and fails if it is not. Between
them, a build cannot quietly ship the previous version's plan.

### Upgrade strategy

Whether a transition can be hot is a property of the edge between two releases,
not of either release, so it is chosen per relup:

```shell
# auto: hot where it can be, restart where it cannot
> mix forecastle.relup --target ... --fromto ...

# require a hot upgrade, and fail rather than degrade
> mix forecastle.relup --target ... --fromto ... --hot

# force a full emulator restart, with no appups at all
> mix forecastle.relup --target ... --fromto ... --restart
```

`--hot` and `--restart` are mutually exclusive, and each may be given once.

**`auto`**, the default, generates every transition from the applications'
appups - unless something in that transition cannot be hot-upgraded, and then
that transition, and only that one, becomes a restart. A transition becomes a
restart when the ERTS version changed, or when the version of an application the
project does not own changed: a dependency, one of Elixir's own applications, or
one of OTP's. None of those carries appups written for your transitions.
Applications merely added or removed are left alone, since starting or stopping
one is hot. Which transitions were chosen, and why, is printed.

`auto` does not fall back to a restart when an appup is missing. A transition it
judged hot and `systools` then could not generate is a failure, so that the
default never quietly ships something other than the upgrade it decided on.

**`--hot`** requires a genuine hot upgrade of every transition, and exits
non-zero, having written nothing, if one cannot be: a missing appup entry, an
ERTS change, or an appup that asks for the emulator to be restarted. This is
about feasibility rather than policy, so unlike `auto` it will happily upgrade a
dependency whose appup covers the transition. It is the switch for a pipeline
that promises zero downtime.

**`--restart`** makes every transition a single `restart_emulator` instruction.
No appup is read - not for your own applications either - and `systools` is not
involved at all. Use it when the upgrade instructions a change would need are
not worth writing or maintaining.

### Which restart, and what the operator sees

OTP has two emulator-restart instructions and they are different transitions,
not two spellings of one. Forecastle generates only the first:

| | `restart_emulator` | `restart_new_emulator` |
| --- | --- | --- |
| Where in the script | last | first |
| Relup evaluated | in full, before the reboot | partly; continues on the way up |
| Hybrid temporary release | no | yes - new ERTS, kernel, stdlib, sasl over the old applications |
| `install_release/1` replies | `{ok, Vsn, Descr}` | `{continue_after_restart, Vsn, Descr}` |

The reply differs, and automation reads the reply, which is why the task says
which strategy it chose for each transition.

`restart_new_emulator` is not a strategy here, and is refused wherever it turns
up. That is also why `auto` decides the ERTS case for itself rather than asking
`systools` and taking what comes: `systools` inserts `restart_new_emulator` on
its own whenever the ERTS version differs between two releases, so a default
that simply generated a relup would ship the two-stage transition without
anybody having chosen it.

Note that a restart transition can be *generated* but not yet *performed*: the
reboot comes back up on whichever version `releases/start_erl.data` names, and
nothing writes the installed version there until it is committed. Until
[castle#14](https://github.com/ausimian/castle/issues/14) and
[#10](https://github.com/ausimian/forecastle/issues/10) land, treat a restart
relup as something to generate and inspect rather than to deploy.
