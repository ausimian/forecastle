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
  - A `bin/start` is added, and it does nothing at all. `release_handler`
    composes `$ROOT/bin/start <data file>` and installs it as `heart`'s temporary
    reboot command while preparing an emulator restart, and `heart` really does
    run it. A Castle release is restarted by its supervisor rather than by
    `heart`, so the one correct thing for that script to do is exit 0.
  - The generated `env.sh` is extended with a hook, and everything in it runs
    only for the commands that start the system. On the **first** start of a
    deployment it creates `releases/RELEASES`, which is what lets the system
    manage its own releases — a short-lived VM, once, and only while that file
    is absent. The release root has to be writable for it to succeed; if it is
    not, the start still proceeds, with a warning, and `bin/castle unpack` and
    `bin/castle install` will later refuse — each reading the running system's
    own release records as it acts — rather than upgrade a system that cannot
    record what it is running.

    Every start also runs OTP's `heart`, deliberately configured to do nothing:
    `HEART_NO_KILL`, no `HEART_COMMAND`, a beat timeout at heart's documented
    maximum, and the inert `bin/start` above. It is there for one reason —
    `release_handler` calls `heart:set_cmd/1` while preparing an emulator
    restart, and that raises where no `heart` process exists.

    And a start that follows such a restart selects the version that was
    installed. See *Upgrades that restart the emulator* below.

    Any `env.sh` the project supplies through `rel/env.sh.eex` is preserved, and
    runs first.
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

# Make 0.1.1 the version that is running now. Whether the VM is restarted is a
# property of the relup rather than of this command.
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

Version selection on restart needs nothing from `Forecastle` once a version has
been committed: OTP's `release_handler` records the committed version in
`releases/start_erl.data`, which is exactly where the standard launcher reads it
from.

### Upgrades that restart the emulator

`bin/castle install` is the same command whichever kind of transition the relup
describes, and it exits 0 only once the version it installed is the one running —
across a reboot, if there is one. What differs is what has to be in place around
it.

**Your supervisor owns the restart.** `release_handler` calls `init:reboot()`,
the operating system process exits, and nothing inside the release starts it
again: `bin/start` is inert and `HEART_COMMAND` is unset, on purpose, because two
things starting one service is worse than the problem being solved. Run the
release under systemd, a Docker restart policy, Kubernetes or runit. A release
started by hand from a shell will simply stay down until you start it again.

**Until you commit, a restart takes you back.** `release_handler` writes the
installed version to `releases/new_start_erl.data` and leaves
`releases/start_erl.data` naming the version that is still permanent — only
`bin/castle commit` writes that file. So a provisional release that crashes
before it is committed is followed by an ordinary start of the version you were
on, with nobody intervening. `bin/<release> version` reports that version too,
because what it prints is the version *to be booted*; ask the running system if
you want to know what is running.

**Only the one-stage `restart_emulator` is supported.** `mix forecastle.relup`
never generates the two-stage `restart_new_emulator` and refuses it wherever it
finds one; see below.

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
then refused. The relup itself is never opened for writing: the bytes are staged
in a file beside it and renamed over it once they are all there, so a run that
dies with the file open cannot leave half a plan either. A reader sees the whole
of the old relup or the whole of the new one. Assembly then checks the relup it
is about to package really is this release's upgrade plan - the right target
version, with the upgrade and downgrade sections `release_handler` will read -
and fails if it is not. Between them, a build cannot quietly ship the previous
version's plan.

### Upgrade strategy

Whether a transition can be hot is a property of the edge between two releases,
not of either release, so it is chosen per relup:

```shell
# auto: hot where it can be
> mix forecastle.relup --target ... --fromto ...

# require a hot upgrade, and fail rather than degrade
> mix forecastle.relup --target ... --fromto ... --hot

# force a full emulator restart, with no appups at all
> mix forecastle.relup --target ... --fromto ... --restart
```

`--hot` and `--restart` are mutually exclusive, and each may be given once.

**`auto`**, the default, generates every transition from the applications'
appups - unless something in that transition cannot be hot-upgraded, and then
that transition, and only that one, becomes a restart. Two things do that:

- **an ERTS change**, always. It is not a hot upgrade under any policy and no
  appup could make it one.
- **a version change in an application you do not own** - a dependency, one of
  Elixir's own applications, one of OTP's - when no appup covers that particular
  move. The appup consulted is the one beside the *target* release's copy of the
  application, `lib/<app>-<vsn>/ebin/<app>.appup`, and the from-version is
  matched the way `systools_relup` matches it, which includes the regexes an
  appup may name a from-version with. An entry that matches is an instruction for
  this transition whoever wrote it, so the edge stays hot; nothing matching means
  there is no hot upgrade to be had.

Each *direction* is classified on its own, because an appup's upgrade and
downgrade lists are independent: a relup may carry a hot upgrade from a version
and a restart back down to it. Applications merely added or removed are left
alone, since starting or stopping one is hot. Which transitions were chosen, and
why, is printed once per run. Where the run goes on to succeed that is after the
relup has been generated and inspected, since an appup may itself ask for the
emulator to be restarted and nothing knows that until there is a script to look
at.

`auto` does not fall back to a restart when an appup for an application you *do*
own is missing. A transition it judged hot and `systools` then could not generate
is a failure, so that the default never quietly ships something other than the
upgrade it decided on.

The announcement names every edge that will restart and why — both the ones
classification chose and any `restart_emulator` an appup asked for by name, in one
message, since they are the same transition arrived at two ways. It also says
what that means for reading the install back: `install_release/1` replies
`{ok, Vsn, Descr}` for such a transition, indistinguishably from a completed hot
upgrade, and the emulator then reboots. `--hot` and `--restart` are the ways to
insist on something else.

**`--hot`** requires a genuine hot upgrade of every transition, and exits
non-zero, having written nothing, if one cannot be: a missing appup entry, an
ERTS change, or an appup that asks for the emulator to be restarted. This is
about feasibility rather than policy, and it is not the same question `auto`
asks: `--hot` reads every application's appup, including your own, and takes
whatever they yield, where `auto` reads only those of the applications you do not
own and reads them to decide whether the edge can be hot at all. It is the switch
for a pipeline that promises zero downtime.

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

Performing a one-stage restart transition takes two things the release now
carries: a `heart` process, because `release_handler` calls `heart:set_cmd/1`
while preparing the reboot, and something to select the installed version on the
way back up, because the reboot would otherwise come back on whichever version
`releases/start_erl.data` names. Both are in the `env.sh` hook; see
*Upgrades that restart the emulator* above for what your supervisor has to do.
