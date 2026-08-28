# Forecastle

Build-time support for hot-code upgrades.

`Forecastle` provides build-time support for the generation of releases that correctly support hot-code 
upgrades. This includes:

  - Copying appup and relup files into place.
  - Organising the generated release structure so that it's ready for hot-code upgrades.
  - Adding a `bin/castle` command for unpacking and installing releases, alongside
    the standard Mix launcher.

Additionally, `Forecastle` ships with an appup compiler and two mix tasks:
`mix castle.relup`, which generates a relup, and `mix castle.appup`, which
checks that an appup actually covers the modules that changed. Both are named
for `Castle` rather than for the package that implements them, because where the
build-time code lives is a packaging decision and what a developer types is not.

The compiler is named for neither package. It is `mix compile.appup`, reached
through the project's `:compilers` list rather than invoked by name. So the two
similar names are two different jobs: `mix compile.appup` *writes* the appup into
`ebin` from the source you committed, and `mix castle.appup` *reads* it back and
says whether it covers the modules that moved.

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
placed around the `:assemble` step, with `Forecastle.generate_relup/1` immediately
before `:tar` and `Forecastle.refuse_late_upgrade_from/1` last of all, e.g.:

```elixir
defp releases do
  [
    myapp: [
      include_executables_for: [:unix],
      steps: [
        &Forecastle.pre_assemble/1,
        :assemble,
        &Forecastle.post_assemble/1,
        &Forecastle.generate_relup/1,
        :tar,
        &Forecastle.refuse_late_upgrade_from/1
      ]
    ]
  ]
end
```

`Castle.customize/1` builds that list for you, through `Forecastle.steps/1`;
spelling the steps out by hand is only needed where a project wants its own steps
interleaved with them.

**A step of your own between `:assemble` and `:tar` keeps its place, and relup
generation happens after it.** `mix release` documents such a step as the way to
customise an assembled release, so it can change what a relup would be generated
from — an appup rewritten, something copied into `lib/`. Generating first would
describe the tree as it was while `:tar` packaged the tree as it became. Where
there is no `:tar` step, generation is appended last; if you pack your own
archive in a step of your own, place `&Forecastle.generate_relup/1` before it
yourself, because nothing here can tell which of your steps does the packing.

**A `&Forecastle.generate_relup/1` you placed yourself keeps its place, and no
second one is added.** `Forecastle.steps/1` splices generation in only where the
list does not already have it, so the arrangement above — generation in front of
the step that packs — is honoured rather than duplicated. A step placed *before*
`:assemble` does not count: it cannot generate anything there, because the
release file it reads has not been written yet, and it fails naming that file.

**Generation placed *after* `:tar` is refused, for a release that asks for a
relup.** `mix release` allows a function step on either side of `:tar`, but
`:tar` packs the version directory — so a relup generated afterwards can never be
in the archive, and the build would announce the plan it had generated and exit 0
having shipped an artefact with none in it. Move the step in front of `:tar`, or
drop `:tar` and pack your own archive in a step with generation ahead of it. The
refusal happens before anything is assembled, and again immediately before `:tar`
in case a step of your own added `:upgrade_from` in between — so no archive is
ever packed without it. A release that sets no `:upgrade_from` is unaffected:
generation does nothing there, so the placement costs nothing.

**`:upgrade_from` itself is settled before `:assemble`, and a step that changes
it afterwards is refused.** `&Forecastle.pre_assemble/1` reads the option and
resolves the baselines, and what your release asks for is not re-read after
that. A step setting it later can be too late for a relup to be generated from
it — and one that sets it after `:tar` reaches a build that has already packed
an archive with no upgrade plan in it, at exit 0, which is what this closes. If
your baselines are worked out at build time, put that step *before* `:assemble`:
`Forecastle.steps/1` adds nothing in front of your own pre-assembly steps, so
what it sets is resolved with the rest.

`&Forecastle.refuse_late_upgrade_from/1` is what checks, and it goes last in the
list — after any step of your own that follows `:tar`, since that is the only
position from which such a step is visible at all. It compares against the record
`&Forecastle.pre_assemble/1` leaves behind, so a release naming baselines with no
record beside them is refused too: not because they are known to be different,
but because nothing there can tell whether they are. Have a step of your own
*rewrite* the keyword list it is handed rather than replacing it, since a fresh
list drops what `Forecastle` put there. A release that names no `:upgrade_from`
is left alone either way, and assembles exactly as it did before any of this
existed.

`generate_relup/1` does nothing at all unless the release sets `:upgrade_from`,
so adding it to a release that generates no relup changes nothing and costs
nothing.

## Build Time Support

The following steps shape the release at build-time:

### Pre-assembly

In the pre-assembly step:

  - Any `relup` in the project root is read and checked against the version being
    assembled, so that a stale upgrade plan fails the build rather than being
    packaged as this version's.
  - A `relup` in the project root **and** an `:upgrade_from` option together are
    refused, naming both. They are two upgrade plans for one release and only one
    file can be packaged, so this is a refusal rather than a rule about which
    wins. A malformed `:upgrade_from` is refused here too — before `:assemble`
    has created anything, so a corrected retry has nothing in its way.
  - Any appup source in `rel/appups` is read, evaluated and checked against the
    versions this release carries — see *Appups for Dependencies* below. One
    naming a transition this release is not part of fails the build here, before
    anything has been created.
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
    is absent. That helper finishes before Forecastle adds its own `-heart`, so
    its normal exit cannot look like the daemon stopped and tried to reboot. If
    the release root is read-only, the start warns and carries on; the system can
    run and restart but cannot unpack or install upgrades. If the root is
    intended to be writable, fix the reported error and restart before
    upgrading.

    Every start also runs OTP's `heart`, deliberately configured to do nothing:
    `HEART_NO_KILL`, no `HEART_COMMAND`, a beat timeout at heart's documented
    maximum, and the inert `bin/start` above. It is there for one reason —
    `release_handler` calls `heart:set_cmd/1` while preparing an emulator
    restart, and that raises where no `heart` process exists.

    If your deployment already asks for `-heart` — in `rel/vm.args.eex`, in
    `ELIXIR_ERL_OPTIONS`, in one of `ERL_AFLAGS`, `ERL_FLAGS` and `ERL_ZFLAGS`,
    or in `ERL_OTP<major>_FLAGS` — that is fine, and nothing is added beside it:
    two of the flag make `init:get_argument(heart)` answer `{ok, [[], []]}`,
    which heart's own startup check has no clause for, so the boot would hang
    having printed nothing. The hook settles it by asking `erl` what argument
    list it would build, so quoting and escaping in those values are read the way
    `erl` reads them, and all six places a flag can come from are covered at
    once. It asks on every start, which costs one short-lived `erl` that exits
    without booting anything; commands that do not start the system — `eval`,
    `rpc`, `remote` — ask nothing.

    Those three are **assigned**, and `HEART_COMMAND` is **unset**, rather than
    defaulted — so a deployment that already has any of them in its environment
    still gets a heart that does nothing. There is no opting out of that while
    this hook is in use: your supervisor owning the restart is what the rest of
    it depends on. A start that displaces one of your settings says so on
    standard error, naming what it displaced, rather than failing the boot over a
    configuration conflict or losing the setting silently. A deployment that sets
    none of them says nothing at all.

    And a start that follows such a restart selects the version that was
    installed. See *Upgrades that restart the emulator* below.

    Any `env.sh` the project supplies through `rel/env.sh.eex` is preserved, and
    runs first.
  - The generated _name.rel_ is copied into the `releases` folder as _name-vsn.rel_,
    which is where `release_handler` looks for it when unpacking a tarball.
  - Any checked `relup` is written into the version path of the release.
  - Any appup read from `rel/appups` is written to
    `lib/<app>-<vsn>/ebin/<app>.appup`, and each one is named on standard output.
    Nothing is ever written into `deps/`.

### Relup generation

Between post-assembly and `:tar`, `Forecastle.generate_relup/1` generates this
release's relup from its `:upgrade_from` option and writes it into the version
path — see *Relup Generation* below. It is the only point in a build where
everything `:systools` needs exists at once, and `:tar` packs the version
directory afterwards, so a single `mix release` produces a tarball with its own
upgrade plan in it.

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

# Make the provisional release permanent. With no version given, this commits
# the release awaiting commit and exits non-zero if there is none.
> myapp/bin/castle commit

# Or, having decided against it, remove it again.
> myapp/bin/castle remove 0.1.1
```

`unpack` and `install` exit non-zero when OTP is using its fallback release
record instead of one loaded from `releases/RELEASES`. Each asks the system as
it acts rather than trusting an earlier answer. Resolve the reported `RELEASES`
problem, then restart; changing the file while the system is running does not
replace the record already loaded.

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
again: `bin/start` is inert and `HEART_COMMAND` is unset — unset by the hook on
every start, even where the environment supplies one — because two things
starting one service is worse than the problem being solved. Run the release
under systemd, a Docker restart policy, Kubernetes or runit. A release started by
hand from a shell will simply stay down until you start it again.

**Until you commit, a restart takes you back.** `release_handler` writes the
installed version to `releases/new_start_erl.data` and leaves
`releases/start_erl.data` naming the version that is still permanent — only
`bin/castle commit` writes that file. So a provisional release that crashes
before it is committed is followed by an ordinary start of the version you were
on, with nobody intervening. `bin/<release> version` reports that version too,
because what it prints is the version *to be booted*; ask the running system if
you want to know what is running.

**Only the one-stage `restart_emulator` is supported.** `mix castle.relup`
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

## Checking the Appup

The compiler cannot tell you whether your appup is *right*, because it only ever
sees one version of your code. Nothing else will tell you either:
`:systools.make_relup/4` fails when an appup has no **entry** for the version
being upgraded from, but it does not - and cannot - notice that an entry is
**incomplete**.

That matters more than it sounds. If `MyApp.A` and `MyApp.B` both changed and
your appup mentions only `A`, the relup generates, the upgrade succeeds,
`release_handler` swaps the code path, and `B` is still running the code that was
loaded before. The new code is on disk, on the code path, and unused - until the
next restart loads it underneath a system nobody was upgrading.

`mix castle.appup` is the check for that:

```shell
> mix castle.appup --from tar:artifacts/myapp-1.0.0.tar.gz
myapp 1.0.0 -> 1.1.0
  upgrade from 1.0.0
    MyApp.B changed, and no instruction loads it
  downgrade to 1.0.0
    MyApp.B changed, and no instruction loads it
```

It exits non-zero when it finds a gap, so it can be a pipeline gate. It writes
nothing at all.

**What it does not do** is tell you the appup is *valid*. It asks whether the
appup names everything that moved; it does not ask whether the resulting script
is one `:systools` will accept. Those are different questions, and only the first
needs help - `make_relup/4` already fails loudly on a malformed script, at the
moment a relup is generated. What it cannot see is an entry that is
*incomplete*, which is the whole of what this is for. Some invalid scripts are
reported here anyway, because an instruction `:systools` will not accept covers
nothing and crediting one would overstate coverage, but that is a side effect
rather than a promise: a green run means your coverage is complete, not that a
relup will build.

`--from` takes a [baseline spec](#naming-the-baseline), the same grammar
`mix castle.relup` takes, so the baseline can be an assembled release, the
artefact that shipped or a git ref. `--to` defaults to **the current build**, so
the everyday question - *what has changed since 1.0.0, and does my appup cover
it?* - needs only `mix compile`; give it a spec to compare two things that
already exist, and then nothing is compiled at all, so comparing two shipped
artefacts does not need your working tree to build. `--app` may be repeated and
defaults to your own applications plus any umbrella children, so naming a
dependency is how you check its appup.

Each direction is reported on its own, because an appup's upgrade and downgrade
lists are independent. What makes the run fail:

- a module that changed or was added and that no instruction *loads*, or was
  removed and that no instruction *deletes*. What an instruction does matters
  rather than which module it names: `update`, `load_module` and `add_module`
  load, while `delete_module` removes and loads nothing;
- a module a `delete_module` names that is still in the target build, which
  would take working code out of the running release;
- a module the same edge both loads and removes. Which one wins depends on the
  order `:systools` translates the instructions into, and that is not the order
  you wrote them in — it hoists dependency-connected instructions past
  independent ones — so this is reported rather than guessed at;
- a module defined by more than one instruction, which `:systools` refuses
  outright as `muldef_module`. An application-level instruction counts, so a
  `restart_application` beside an explicit `update` of one of that application's
  own modules is refused;
- a module that moved but that the application's own `.app` does not list, which
  `:systools` cannot resolve object code for, so no instruction could carry it;
- an instruction whose shape is not one `:systools` accepts. It is refused as a
  `bad_instruction` before anything is translated, so the edge produces no relup
  at all - and it covers nothing here, whatever module it appears to name;
- no entry at all for the from-version;
- an application whose modules moved while its version did not, since
  `release_handler` compares versions and no appup is consulted for an
  application that did not change.

A module an instruction names that *did not* change is reported and does not fail
the run. It is usually a leftover naming the wrong module - and then the module
that really changed is covered by nothing and fails on its own account - while an
instruction that loads identical code is simply inert.

Nothing is reported about an edge that ends by restarting the emulator:
module-level instructions are moot when a new VM is going to load the code from
scratch. That exemption is per application, so a restart supplied by an
application `--app` did not name, or inserted for an ERTS change, is not visible
here; `mix castle.relup` is what decides restarts, having both releases to do it
with.

Modules are compared by `:beam_lib.md5/1` together with their persisted
attributes, not by a digest of the file bytes - so a stripped release compares
correctly against an unstripped build, a change to a `@doc` is not mistaken for a
change to the code, and a change to an explicit `@vsn`, which the md5 does not
cover, is not missed.

The check is deliberately not part of `mix precommit`: it needs a baseline, and
`precommit` has not got one.

## Appups for Dependencies

Most hot upgrades die on a dependency. It bumped a patch version, it ships no
appup, and `auto` degrades the whole edge to a restart — correctly, because there
is no hot upgrade to be had. But the missing piece is usually small, and you are
in a position to supply it.

Put one in `rel/appups`, beside `rel/env.sh.eex`, named for the transition it is
for:

```
rel/appups/jason-1.4.0-1.4.2.exs
```

The file is an appup source like the one the `:appup` key names — arbitrary
Elixir evaluated for its value, and source you review and commit:

```elixir
{~c"1.4.2", [{~c"1.4.0", [{:load_module, Jason.Encoder}]}],
 [{~c"1.4.0", [{:load_module, Jason.Encoder}]}]}
```

`mix castle.appup.gen --app jason --from <spec>` drafts one for you and writes it
there, with the same comments it writes beside an owned application's
instructions. A dependency whose modules are all stateless yields a
`load_module`-only appup, which is the common and useful case. It asks whether
the transition is already covered across *every* source for that application, not
just the one it would write — so a sibling whose from-version is a regular
expression that already matches leaves it a no-op rather than a second entry the
next build would refuse.

`mix release` writes each of them into the assembled release at
`lib/<app>-<vsn>/ebin/<app>.appup`, and says so. **Nothing is ever written into
`deps/`**: that checkout is shared by every release built from the tree, and by
other projects where the build cache is shared, so an appup there would be one
project's upgrade instructions in builds that never asked for them.

`auto` then reads it exactly as it reads an appup a dependency shipped for itself
— the entry matches this from-version, so it *is* an instruction for this
transition — and the edge stays hot.

### What fails the build

The name is read against the release rather than parsed, so both ends are exact
whatever the versions contain: for every application the release carries at
version `V`, `<app>-<from>-V` matches by anchoring the application at the front
and `V` at the back. Everything else is a refusal, and every one of them happens
before `:assemble`, so a corrected retry has no half-built release in its way:

- a name that matches no application in the release, or matches one at a version
  the release does not carry. That is the stale case — you bumped the dependency
  and the file stayed behind — and packaging it would hand `release_handler`
  instructions for a transition this release is not part of;
- an application you own. Its appup comes from the `:appup` compiler, and a file
  here would be written over the compiled one after the compiler produced it;
- a file that does not evaluate to an appup, or whose version tag is not the
  version the release carries, or that holds something which is not a
  `{from_version, instructions}` entry;
- a file whose own appup has no entry for the from-version its name claims;
- two entries for one application that can both be *selected* for one version.
  Several files for one application are merged, in the order the names sort,
  because a release upgradeable from several baselines needs an entry per
  baseline — but `appup_search_for_version/2` takes the *first* entry that
  matches, so two entries competing for one version would be settled by a
  filename sort. A binary key is a regular expression to that function, so this
  is not only two identical keys: the question is asked with the function that
  selects, at the versions your file names and your entries name;
- an appup the application ships for itself that cannot be read, since a
  project-supplied one is about to be placed alongside it;
- anything in `rel/appups` that is not a `.exs` file. Dotfiles are the exception,
  so `.gitkeep` and `.DS_Store` are ignored.

Two refusals come *after* assembly, because nothing before it can be sure. Both
leave the release directory behind, so the corrected retry needs
`mix release --overwrite` — without it `mix release` assembles nothing and exits
zero:

- an appup at `lib/<app>-<vsn>/ebin/<app>.appup` that is not the copy Mix made of
  the build's own, or that is not a regular file at all. `mix release` copies the
  applications and then copies the release's overlays over them — preserving
  symlinks — so a `rel/overlays/lib/<app>-<vsn>/ebin/<app>.appup` is a second
  answer to what that application's upgrade instructions are, and writing over it
  is how the other one disappears. Take the overlay out, or move its entries into
  `rel/appups`;
- an application named by a source that has no `lib/<app>-<vsn>/ebin` in the
  assembled release, which is what a release built with `include_erts: false`
  does with OTP's own applications: the deployment takes those from the host, so
  there is nothing in the release to place an appup in.

A file covering only one direction is *not* refused: an appup with an upgrade
entry and no downgrade is a legitimate thing to write, and `auto` classifies each
direction on its own and announces the restart it makes of the other.

### If the dependency ships an appup of its own

It is merged into, not written over. Your entries go first — so where both
describe the same transition, yours is the one `release_handler` selects, which
is how you correct an appup that is wrong or incomplete — and everything the
dependency shipped is still in the placed file behind them. The build names the
shipped file, says how many of its entries were kept, and names every one your
entries override.

One boundary worth knowing: `mix castle.appup --app <dep>` reads the appup out of
the build you point `--to` at, and a project-supplied one is only ever in an
assembled release. Point `--to` at a `rel:` or `tar:` baseline to check it.

## Relup Generation

### During the build, with `upgrade_from:`

Name the releases this one can be upgraded from, and a single `mix release`
produces a tarball with the relup already in it:

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

`:upgrade_from` is an ordinary release option, which `Forecastle` reads out of
the assembled release — Mix carries options it does not recognise through
untouched, and `Castle.customize/1` leaves everything but `:steps` alone.

The value is a list of *baseline specs* — the grammar described below — and each
one gets both directions, which is what `--fromto` gives a transition: a plan
that cannot be rolled back is not much of an upgrade plan. The strategy is
`auto`.

`Forecastle.generate_relup/1` does this after post-assembly and immediately
before `:tar` — after any step of your own, so the relup describes the tree that
is actually packaged. That interval is the only point in a build where the
target's `<name>.rel` and its populated `lib/` both exist. Before this,
generating a relup for a release meant building it, running `mix castle.relup`
against what came out, and building it again to package the result — a mandatory
double build, with a mutable file in the project root as the hand-off between
the two.

How it behaves when it is given nothing, or something malformed, is a set of
decisions rather than an accident:

  - **No `upgrade_from:` at all** is a no-op. The release assembles exactly as it
    would without the step.
  - **`upgrade_from: []`** is refused. It is a build asking for an upgrade plan
    and naming nothing to generate one against — a list read from the environment,
    or computed down to nothing — and assembling it in silence would hand you a
    release with no relup and no complaint.
  - **A malformed spec** — `""`, `"tar:"`, a prefix naming no source — is refused
    before `:assemble` runs, so nothing is left half-built for the corrected retry
    to trip over.
  - **A repeated `upgrade_from:`** is refused rather than resolved by taking the
    first. Mix keeps every occurrence of a release option it does not recognise,
    so a definition built by joining lists can carry two.
  - **An `upgrade_from:` a step of your own changed** after pre-assembly resolved
    it is refused, naming what the release said then, what it says now, and where
    to say it instead. Work your baselines out in a step placed before
    `:assemble`, where they are resolved and honoured like any others.
  - **A baseline that cannot be resolved** — a `tar:` that is not there, a `ref:`
    that does not build — is refused before `:assemble` too. Resolution is the
    largest thing this can fail at, so it happens while failing is still free.
  - **A baseline that resolves to nothing** — a spec pointing at no release, or at
    a directory with no applications in it — fails the build, naming what could
    not be read. It is never treated as "nothing changed".

A hand-written `relup` in the project root and `upgrade_from:` together are
refused, naming both, rather than one taking precedence over the other.

**What is left that can only fail after assembly** is reading the target's
`.rel` and asking `:systools` for a script, both of which need the assembled
release. If one of those fails, the release stays on disk without a relup and the
build has to be retried with `--overwrite`: `mix release` decides whether to run
its steps at all before any step is reached, so a plain retry into a directory
that already holds a release assembles nothing.

**`ref:` has one sharp edge here that the other two sources do not.** Resolving
one checks the commit out and builds it, so an ordinary `mix release` waits for a
build of a previous version as a side effect — `tar:` is both the fast source and
the recommended one. And building that commit runs *its* `mix.exs`, which sets
this option again, so a baseline would want a baseline: `Forecastle.Baseline`
refuses that outright rather than recursing, and the environment variable it
refuses on is `CASTLE_BASELINE`. A `mix.exs` that names a `ref:` baseline should
leave the option out when that variable is set.

### Against a target that already exists, with `mix castle.relup`

`Forecastle` provides the mix task `castle.relup`, which generates a relup for a
target release that has already been built — it does not have to be a release
this build is producing. Assuming you have two _unpacked_ releases e.g. `0.1.0`
and `0.1.1` and you wish to generate a relup between them:

```shell
> mix castle.relup --target myapp/releases/0.1.1/myapp --fromto myapp/releases/0.1.0/myapp
```

The baseline takes the same three specs as `upgrade_from:`, and only two of them
are read rather than made: `rel:` and `tar:` name something already built, while
`ref:` checks the commit out and runs its build. So whether anything is rebuilt
is a property of the spec you write, not of the task.

It is also where a build insists on a strategy: `--hot` and `--restart` are the
task's, and `upgrade_from:` always generates under `auto`. So is `--dry-run`,
which reports what the relup would be and writes nothing - an assembly step whose
job is to put a relup into a release has no use for a mode that produces none.

If the generated file is in the project root, it will be copied during
post-assembly to the release. That is where the task writes it by default;
`--outdir` sends it somewhere else, which post-assembly will not find, and a
relative `--outdir` is resolved from the directory the task is run in rather
than from the project root. The directory has to exist already: a mistyped one
that sprang into existence is how a relup ends up somewhere nothing looks for.

At least one of `--fromto`, `--upfrom` and `--downto` is required: a relup with
no transitions in it is not an upgrade plan.

### Naming the baseline

The value those three switches take, and the value `upgrade_from:` takes, is a
*baseline spec* - one grammar for the three places the release being upgraded
from can come from:

```shell
# an assembled release, named by its .rel file without the extension
> mix castle.relup --target ... --fromto rel:_build/prod/rel/myapp/releases/1.0.0/myapp

# the artefact that shipped
> mix castle.relup --target ... --fromto tar:artifacts/myapp-1.0.0.tar.gz

# a git ref, checked out into a worktree and built
> mix castle.relup --target ... --fromto ref:v1.0.0
```

A value with no prefix is a `rel:` path, so anything written before specs
existed means what it always meant. The direction stays on the switch name and
the source stays in the value. `--target` is *not* a spec: it names the release
being generated for, which has just been assembled, so it is always a path.

**Prefer `tar:`, for correctness rather than convenience.** `release_handler`
picks a relup entry by from-version *string*, and never checks that the code
running is the code the relup was generated against. A baseline rebuilt from
source gets today's Elixir, today's OTP and today's hex tarballs for anything
the lock does not fully pin - so if the module set that comes out differs from
what is deployed, the relup's instructions miss modules, and the upgrade loads
part of the new code over a system still running the rest of the old. A relup
generated against a rebuilt baseline describes a transition from a release that
never existed.

`ref:` is the right answer for development, for testing an upgrade path before
anything ships, and for the common case where nobody kept the artefact. It says
on every use that what it produced was rebuilt rather than deployed. The commit
is checked out into a git worktree, built, and the worktree removed. A shallow
clone that does not hold the ref is told to `git fetch --tags --unshallow` rather
than being left with an unknown revision from `git worktree add`, and
`CASTLE_BASELINE` is set while a baseline is being built so that a build which
asks for a baseline of its own is refused rather than going round again.

What `tar:` unpacks and what `ref:` builds are both kept under
`_build/castle/baselines` and reused. An entry is written in a staging directory
and renamed into place, so it exists only once it is whole: an interrupted run
leaves nothing behind that a later one would treat as usable, and two runs
resolving the same baseline at once each build their own with the first to finish
winning. A `tar:` entry is keyed on a digest of the artefact's bytes rather than
on its path, so a pipeline that rewrites the same filename is never served the
previous build's release. A `ref:` entry is keyed on the resolved commit together
with the Mix environment and target and the Elixir and ERTS versions it was built
with, so a toolchain upgrade produces a fresh baseline rather than serving one
compiled by the version before it.

Only worktree registrations inside that cache are ever cleaned up.
`git worktree prune` is not used: it clears every stale registration in the
repository, and a checkout on a disk that is not mounted today is
indistinguishable from a dead one.

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
> mix castle.relup --target ... --fromto ...

# require a hot upgrade, and fail rather than degrade
> mix castle.relup --target ... --fromto ... --hot

# force a full emulator restart, with no appups at all
> mix castle.relup --target ... --fromto ... --restart
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
message, since they are the same transition arrived at two ways. It says that
each uses `restart_emulator`, reboots into the installed release, and leaves it
provisional until committed. `--hot` and `--restart` are the ways to insist on
something else.

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

### Asking the question without writing the answer

`--dry-run` does everything an ordinary run does except write the relup:

```shell
# can 1.0.0 be upgraded to 1.1.0 hot, and if not, which edge and why?
> mix castle.relup --target ... --fromto ... --dry-run
```

It does everything the same invocation without the switch would have done, and
then discards the plan. Nothing is written where the relup would have gone,
including when one is already sitting there: the run does not touch that file,
and leaves no staging file beside it.

It costs nothing extra because the announcement already waits for the generated
plan - an appup may ask for the emulator to be restarted by name, and nothing
knows that until there is a script to look at. So what a dry run reports is what
an ordinary run reports, per edge and per direction, arrived at by the same code.

**What "everything" amounts to depends on the strategy**, and a dry run is worth
exactly what the run it stands in for is worth. The baselines are resolved under
all three. `auto` then classifies each edge and asks `systools` for whatever half
it judged hot; `--hot` asks `systools` for the whole relup; `--restart` reads no
appup at all and never reaches `systools`, because writing the entries by hand is
the whole of what it does. So `--restart --dry-run` tells you the releases could
be read and the entries built, and nothing whatever about appups.

**The exit status is the other half of the answer, and it is about generation:**
zero when the relup could have been generated, non-zero when generation would
have failed. A dry run that cannot generate fails rather than reporting success
with a caveat. Generation ends at the encoded bytes, which is the last step that
is a property of the plan rather than of the destination.

That is not quite "the status the same command without `--dry-run` would have
had", and the gap is one-sided. Everything that refuses before the write refuses
here too - an `--outdir` that is not a directory, a baseline that cannot be
resolved, two baselines for one version, a `systools` failure, `--hot` over a
transition that cannot be hot - so a dry run never reports success where an
ordinary run would have refused the *plan*. What it cannot see is a failure to
*publish* one: a directory standing where the relup goes, a destination that
cannot be written, no space left. Those are found by writing, and writing is the
one thing this mode does not do.

It is orthogonal to the strategy and combines with either switch.
`--hot --dry-run` is the pipeline's question asked before the pipeline runs.
`--hot` announces nothing of its own on success, which is why the dry run prints
a line at all - without it that run is a silent exit 0. It is not necessarily the
*only* line, though: `systools` warnings still reach standard error under
`--dry-run`, exactly as they would without it. Read the exit status, not the
number of lines.

"Writes nothing" is a promise about the relup and the directory it would have
gone in, not about the run as a whole. A dry run still resolves its baselines,
and resolving one writes: `tar:` unpacks the artefact into
`_build/castle/baselines` and `ref:` checks the commit out and builds it into the
same place, while `rel:` names a release already on disk and costs nothing. A
baseline that cannot be resolved is a generation that would have failed, and
saying so means resolving it.

### Which restart, and what the operator sees

OTP has two emulator-restart instructions and they are different transitions,
not two spellings of one. Forecastle generates only the first:

| | `restart_emulator` | `restart_new_emulator` |
| --- | --- | --- |
| Where in the script | last | first |
| Relup evaluated | in full, before the reboot | partly; continues on the way up |
| Hybrid temporary release | no | yes - new ERTS, kernel, stdlib, sasl over the old applications |
| `install_release/1` replies | `{ok, Vsn, Descr}` | `{continue_after_restart, Vsn, Descr}` |

The transitions differ operationally, which is why the task keeps the exact
strategy name in its output.

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

## Testing an Upgrade

A release that assembles is a release that builds. Whether it can be *upgraded*
is a different question, and the only thing that answers it is starting one
version, installing the next, and looking at what survived.

`Forecastle.UpgradeCase` and `Forecastle.Deployment` are the half of that you do
not have to write. They are ordinary `lib` code, so `mix test` runs them like any
other test — and because Castle takes Forecastle as `runtime: false`, they are
there at build and test time and never enter a release.

**There is no `mix castle.upgrade.test`, deliberately.** A task would have to
hardcode what "the upgrade worked" means, and only your project knows: for one it
is a counter that kept counting, for another a socket still open or a job still
in flight. As a case template it composes with tags, with CI and with your own
assertions instead.

### What it looks like

Name the artefact you shipped, so a single `mix release` produces a tarball with
the relup already in it:

```elixir
defp releases do
  [
    myapp: fn ->
      [upgrade_from: ["tar:artifacts/myapp-1.0.0.tar.gz"]]
      |> Castle.customize()
    end
  ]
end
```

Then deploy that same artefact, start it, and install the tarball the build just
produced:

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

  test "moved to 1.1.0 and took the count with it", %{deployment: deployment} do
    assert Deployment.rpc!(deployment, "IO.puts(inspect(MyApp.Counter.info()))") ==
             ~s({"1.1.0", 1})

    assert Deployment.version(deployment) == "1.1.0"
  end
end
```

`castle!/3` raises on a non-zero exit, so an `unpack`, `install` or `commit` that
failed is a failure of the setup rather than something an assertion further down
has to notice. `@moduletag :upgrade` and an `ExUnit.start(exclude: [:upgrade])`
keep it out of the ordinary `mix test` run; it boots a node, so it does not
belong there.

### Assert the code as well as the state

**A count that survived is not evidence that anything moved.** An appup that does
not mention a module leaves that module's *old* code serving calls, with the new
code sitting on disk beside it — the failure `mix castle.appup` exists to catch,
and the one an upgrade test asserting only the count would pass, because
unchanged code preserves a count perfectly.

So `info/0` above reports the version alongside the count, and reports it from a
literal the module carries:

```elixir
defmodule MyApp.Counter do
  use GenServer

  @vsn_tag Mix.Project.config()[:version]

  @doc "`{the version compiled into the code serving this call, count}`"
  def info, do: GenServer.call(__MODULE__, :info)

  def handle_call(:info, _from, state), do: {:reply, {@vsn_tag, state.count}, state}
end
```

`@vsn_tag` is compiled into whichever copy of the module is executing the call,
so an old one says this process is still running old code. Reading the version
from `Application.spec/2` — or from `Deployment.version/1`, which is what the
second assertion does — answers about the *release*, and a release moves whether
or not any particular module did. That is why the example asserts both: they are
different questions, and only the first is about the code.

`mix castle.appup` catches the same failure before an upgrade is ever attempted.
This catches it afterwards, in a system that took one.

### Where the release under test comes from

`Deployment.deploy!/3` takes the same baseline grammar as `upgrade_from:` and
`mix castle.relup` — `rel:` an assembled release, `tar:` the artefact that
shipped, `ref:` a git ref built in a worktree — so the release you upgrade can be
the one that is actually running in production.

**Prefer `tar:`, for the reason relup generation prefers it.** `release_handler`
selects a relup entry by from-version *string* and never checks it against the
code that is running, so an upgrade tested from a baseline rebuilt today is an
upgrade tested from a release nobody ever deployed — which is the question the
test was written to settle.

It copies rather than deploying in place. `tar:` and `ref:` resolve into an
immutable cache under `_build/castle/baselines`, and a system started in the
cache would leave every later resolution of that spec holding a booted,
half-upgraded release with nothing to say so.

### The two transitions are installed differently

The example above is a hot upgrade. A transition that restarts the emulator needs
`Deployment.install_supervised!/3` in place of the `install` above, because
nothing inside the release starts it again after the reboot: `bin/start` is
inert, `HEART_COMMAND` is unset, and your supervisor owns the restart — so a test
of one has to *be* the supervisor.

There is no call that covers both. A hot upgrade never leaves its operating
system process, so waiting for that process to exit would be waiting for
something that is not coming. Which of the two a transition is comes from the
relup, and `auto` decides it at generation time; `mix castle.relup --hot` fails
rather than degrading, which puts the failure on the build instead of on an
assertion much further down.

`install_supervised!/3` raises the way `castle!/3` does, and what it is usually
raising about is on the far side of the reboot: `bin/castle install` polls for
the version it installed *after* the release has come back, so a provisional
release that rolled back on the way up is reported there and nowhere earlier.
`Deployment.install_supervised/3` returns `{output, status}` for a test that
wants to assert on the status itself.

### What it does for you, and what it does not

`setup_all` puts a `:scratch` directory in the context, one per test module,
under `_build/castle/deployments`. It is a *path*: nothing creates it and nothing
clears it. `Deployment.deploy!/3` empties its own destination, so what survives
there is whatever nothing redeployed — which is exactly the evidence a failed
upgrade left behind.

`deploy!/3` **refuses a destination whose release is still running**, rather than
deleting underneath it. A deployment lives at a stable path, so a run interrupted
before its `on_exit` leaves a daemon there; emptying the directory would not stop
that node, and the next start would come up beside one that still answers to the
release's name — with the readiness rpc as likely to reach the old system as the
new one.

`Deployment.start!/2` gives the launcher a deadline and `:boot_timeout` gives the
release one, and **both of them fail the test rather than stopping anything**:
nothing in Elixir can reach the operating system process behind `System.cmd/3`,
so a launcher that hung is still hung when the failure is reported. A release
that is merely *slow* is what `:boot_timeout` is for — the default of 20 seconds
describes a release that does nothing on the way up, and an application that runs
migrations or waits on a dependency should say so:

```elixir
Deployment.deploy!(@shipped, Path.join(scratch, "deploy"), boot_timeout: 90_000)
```

Every command a deployment runs is given an environment with the variables that
leak into a release unset. Two kinds, and both matter:

- **Emulator flags** — `ELIXIR_ERL_OPTIONS`, `ERL_AFLAGS`, `ERL_FLAGS`,
  `ERL_ZFLAGS`, `ERL_OTP<major>_FLAGS`. A `-heart` in a developer's shell or a CI
  image would otherwise reach every release the tests start, and a release that
  already supplies one is then given two, which hangs the boot having printed
  nothing.
- **Everything `bin/<name>` takes as a default** — `RELEASE_VM_ARGS`,
  `RELEASE_BOOT_SCRIPT`, `RELEASE_SYS_CONFIG`, `RELEASE_MODE`,
  `RELEASE_DISTRIBUTION`, `RELEASE_NODE` and the rest. Each is
  `${NAME:-default}` in the generated launcher, so an inherited value wins: a
  different args file, a different boot script, a different configuration,
  `interactive` instead of `embedded`. What that produces is a test of a release
  materially unlike the one you would deploy, presenting as a bug in the release
  rather than as a leaked variable.

`MIX_ENV` is there for a milder reason and a real one: a deployed release is
started with no Mix at all, while one started from a test run inherits `test`,
and `config/runtime.exs` is the one file a project routinely shares between the
two. `Deployment.scrubbed_env/1` is the same list, for the `mix release` that
builds the versions being tested.

Deployments are not stopped for you: a running release outlives the test that
started it, so `on_exit(fn -> Deployment.stop(deployment) end)` belongs beside
every `start!/2`. And nothing decides whether the upgrade worked. That is the
whole point.
