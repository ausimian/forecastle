# Forecastle

Build-time support for hot-code upgrades in Elixir releases. Forecastle is the
build-time half of a pair: [Castle](https://github.com/ausimian/castle) is the
runtime half. Consumers depend on Castle, which pulls Forecastle in as a
build-time dependency — Forecastle is not intended to be taken directly.

## What it does

`Forecastle.steps/1` wraps a Mix release's `:steps` list, injecting a
`pre_assemble` and `post_assemble` hook around `:assemble`:

- **`pre_assemble/1`** — checks and stages any `relup`, and adds a `:preboot`
  boot script that starts `:sasl`, `:compiler`, `:elixir` and `:castle`.
- **`post_assemble/1`** — writes `bin/castle`, appends the Castle hook to the
  generated `env.sh`, and copies the `.rel` file and any staged `relup` into the
  release.

**Nothing here touches configuration, and nothing new may.** Forecastle used to
intercept all of it: `:runtime_config_path` set to `false`, a substitute
`Config.Reader` installed, every provider's init argument rewritten into a
keyword list with an `:env` key added, the providers initialised here and
stashed under the `Forecastle` key in `release.options`, and the `sys.config` Mix
wrote renamed to `build.config` so the standard launcher could not boot from it.
That existed to give the version being upgraded *to* a configuration resolved by
its own providers, which a boot of the version being upgraded *from* cannot
produce. [castle#13](https://github.com/ausimian/castle/issues/13) does that
properly — in a `:peer` booted on the target's own code, running Elixir's own
pipeline — and this half of the change is what made it reachable. It is now the
only path Castle has: 1.0 configures every version that way, and the branch that
read a `build.config` is deleted along with the file, so there is no
discriminator left to preserve. What that leaves as the rule here is simply that
the `sys.config` Mix writes stays where Mix put it — renaming it again would
produce a release whose launcher can find no configuration at all, and no Castle
that reads the other name exists any more. Mix decides which file configures a
release at runtime, initialises the providers a project declared with whatever
term it declared them with, and expands runtime configuration in the booting VM.

The two defects that interception carried —
[#6](https://github.com/ausimian/forecastle/issues/6) — are gone with it rather
than repaired: `:runtime_config_path` was read as a boolean while the substitute
provider was hardcoded to `config/runtime.exs`, and provider arguments were
rewritten even though `Mix.Release` allows any term. Do not reintroduce a
parallel implementation of either.

`create_preboot_scripts/1` outlived the reason it was written. It is what
Castle's peer boots, so it is load-bearing for a different purpose than before.

`bin/<name>` is left exactly as Mix generated it. Everything Forecastle needs
around it composes instead:

- `bin/castle` is a thin wrapper that shells back through
  `bin/<name> rpc "Castle.<command>(...)"`, so it inherits cookie handling,
  distribution and node naming from the standard launcher. Most commands
  `exec` the launcher and are done; `install` and the version-less `commit`
  cannot, because they have something to do afterwards, so they capture the
  output and propagate the status themselves. What `install` does afterwards is
  confirm, through `Castle.running/1`, that the version it installed is the one
  running: `release_handler` replies as soon as it has accepted an upgrade,
  which for a transition that restarts the emulator is before the upgrade has
  run, and the reply may not outlive the reboot it triggers. A lost connection
  is therefore inconclusive rather than fatal — recognised as the launcher's
  whole `--rpc-eval … :noconnection` diagnostic at the start of a line, never as
  the bare word, which is a usable release version and turns up in the messages
  that name a version that failed — which is also why `validate_vsn` refuses
  control characters, since a version carrying a newline could otherwise forge
  that line for itself.

  The install's two streams are captured apart, for different purposes: its
  standard error is what the classifier reads and is passed through to standard
  error, while its standard output is held until the confirmation succeeds. So
  the success stream never carries a claim the confirmation goes on to disprove,
  and a warning the launcher wrote never comes back out on the wrong stream. The
  confirmations are split the same way, and their standard error is passed on
  even when they succeed — a warning is worth no less for arriving as the upgrade
  is being declared good. Do not merge either with `2>&1`; merging cannot be
  undone.

  Everything able to stop the script is settled before the launcher is invoked:
  the timeout, the clock (`date +%s` is not a conversion POSIX requires, so a
  system can have a `date` that will not answer), and a capture directory, which
  `install` claims for itself under `RELEASE_TMP` with `mkdir` under `umask 077`
  — atomic, so it fails rather than following a symlink someone else planted at
  the name, and private, so nothing inside can be swapped between one open and
  the next. Keep that ordering — past the install the system is on another
  release, so stopping from there leaves it unconfirmed with nothing said about
  it. Six separate review findings have been that same shape.

  That rule has a second half, because the first cannot reach everywhere. The
  deadline has to be anchored *after* the install — earlier, and a slow install
  eats the window meant for confirming it — so the clock gets asked again where
  a failure can no longer be moved out of the way, and past the install there is
  always something else: a capture that cannot be read, a stream that cannot be
  written, a sleep cut short, whatever the next change adds. So: **after the
  install has run, no path may exit without reporting the held output.** Not the
  clock, not the scratch file, not anything added later.
  `install_and_confirm` enforces that structurally rather than case by case —
  `install_outcome` is armed the moment the launcher has been asked, every exit
  runs `install_epilogue` through the EXIT and signal traps, and a terminal path
  that has already spoken marks itself `reported`. A bare `|| exit 1` past the
  install is therefore safe *only* because the epilogue is there; do not remove
  it, and do not add a path that reports the outcome without marking it. What
  the operator gets when something breaks late is what the install said, that
  nothing confirmed it, and `bin/castle releases` to go and find out.

  Claiming the name says nothing about who may *rename* it, which belongs to the
  parent, so the parent is checked too: a `RELEASE_TMP` that anyone may write to
  and that is not sticky is refused, since there the directory can be moved
  aside and a symlink left behind it whatever mode it was created with. Refuse
  the parent rather than re-checking the path on the way to each redirection —
  that narrows a race instead of removing it. `test -k` for sticky and
  `find -L … -prune -perm -0002` for the other-write bit, both of which follow a
  `RELEASE_TMP` that is itself a symlink. Nothing ordinary is refused: the
  default lives inside the release, and `/tmp` is sticky.

  `CASTLE_INSTALL_TIMEOUT` bounds the retrying, as a deadline in elapsed time
  rather than a count of attempts, measured against the system clock — so a
  correction to that clock mid-wait moves it, which is a footnote in the release
  notes rather than something to engineer around; POSIX shell has no monotonic
  clock. It does not bound an individual call: `:erpc` waits indefinitely, so a
  hard limit has to come from outside. A wrong cookie or an already-dead node is
  indistinguishable from a reboot and so is asked about until the deadline; that
  is deliberate, and called out in the release notes.

  Do not add signal forwarding or process reaping to make an interrupt stop the
  upgrade: it cannot. `Kernel.CLI` reaches the node through
  `:erpc.call`, which uses `spawn_request` with `{reply, error_only}` and
  `monitor` and **no link** (`erpc.erl:305`), so the remote worker is never
  signalled when the caller goes away — and OTP's own `spawn_request_abandon/1`
  documentation says only the `link` option would send an exit signal to an
  abandoned child. Beneath that, `:release_handler.install_release/1` is a
  `gen_server:call` (`release_handler.erl:1231`), and the upgrade runs inside
  that server's `handle_call`, which completes whether or not the caller is
  still there. Interrupting `bin/castle install` therefore stops the waiting,
  not the upgrade; the release note says so, and points at `bin/castle
  releases` for finding out where the system got to.
- **`releases/RELEASES` is created before the system starts, and nowhere else.**
  The `env.sh` fragment does it, guarded on the file's absence, so it runs on the
  first start of a deployment and on no start after it. That is the only
  placement that works, and the reasoning is worth keeping because a plausible
  wrong answer was tried first. `release_handler` reads the file in its `init`,
  and when it is missing it builds a release record out of the boot script's name
  and version, with no applications in it. The first operation that changes
  anything — `unpack` — then writes the record it is *already holding* straight
  back over the file. So creating the file from `bin/castle` ahead of `unpack` is
  not merely late: it is erased moments later, and a restart afterwards reads the
  erased version. Create, restart, *then* unpack is the only order that helps,
  and doing the create at boot is what takes the restart out of it.

  Failure there is a warning rather than a refusal — a release does not need the
  file in order to run, and a read-only release root is an ordinary way to run
  one. Castle is where the consequence is refused instead, from inside `unpack`
  and `install`; see the next entry.

  The call needs no working directory of its own: `Castle.make_releases/0`
  derives the releases directory from `code:root_dir()`, the root
  `release_handler` resolves *its* relative paths against, so the file lands
  beside the records that will be read from it however the launcher was invoked.
  It used to be resolved against the working directory, which is why the
  fragment wrapped it in a `File.cd!` into `RELEASE_ROOT`.
- **There is no check in front of `unpack` or `install`, and nothing may add
  one.** A system running from the record `release_handler` synthesised for
  itself cannot be upgraded from — the record names no applications, so nothing
  compares as changed and an application whose version moved but whose code the
  relup does not load is left reachable only through the release being replaced.
  Castle refuses both operations for that, from inside the call that acts, and
  raises: the launcher exits non-zero with the reason and its remedy — a restart,
  the only thing that changes the record — on standard error. `bin/castle` decides
  nothing and paraphrases nothing.

  This repo did have a gate, one rpc to `Castle.upgradable/0` in front of each
  operation, and it was wrong. Two rpcs are two moments and possibly two node
  instances: a node can answer on the record it read at boot, restart onto a
  synthesised one, and have the unpack or the install arrive afterwards and act
  on an answer that no longer holds — the very failure the check exists to
  prevent. An answer is only good for the call that acts on it, which is why the
  check is `Castle.Commands.ensure_upgradable/2` and belongs to the operations.
  Do not reintroduce one here, in any shape, and do not add one to make a refusal
  arrive sooner: `Castle.install/1` materialises the target's configuration
  before it refuses, so a refused install starts a peer first. That is harmless —
  the peer writes only into the target's version directory, never to the running
  system or to any release record, and it is idempotent.

  `bin/castle upgradable` asks the question on its own, for an operator who wants
  to know where a system stands without staging anything. It is a plain command
  like `releases`, gates nothing, and says nothing when the answer is yes.
- The `env.sh` fragment expands no configuration and applies none of the
  launcher's defaults; on every start after the first it does nothing at all. It
  is appended, so a project's own `rel/env.sh.eex` survives and runs first, and
  it is where [#10](https://github.com/ausimian/forecastle/issues/10) will
  consume the provisional restart marker.
- Version selection needs no code at all *after commit*: `release_handler` writes
  the committed version to `releases/start_erl.data`, which is where the standard
  launcher already reads `RELEASE_VSN` from. It does not hold for a transition
  that restarts the emulator, which is #10.

## Relup generation and upgrade strategy

`mix forecastle.relup` takes an upgrade strategy — `auto` by default, `--hot`,
or `--restart` — and it is a property of each transition in the relup rather
than of the release, because that is what it is: a relup for release X carries
one entry per from-version, and whether that particular edge can be hot has
nothing to do with the others. `--hot` and `--restart` are `:count` switches so
that a repeat is a count above one rather than a silent overwrite, and so that
`--no-hot` is an unrecognised switch rather than a quiet way of asking for
something else.

**The two emulator-restart instructions are different transitions, not two
spellings of one.** Verified against OTP 28.3, `sasl-4.3`:

| | `restart_emulator` | `restart_new_emulator` |
| --- | --- | --- |
| Position in the script | last | first (hoisted there) |
| Relup evaluated | in full, before the reboot | partly; continues on the way up |
| Hybrid temporary release | no | yes — new ERTS, kernel, stdlib, sasl over the old applications |
| `install_release/1` replies | `{ok, Vsn, Descr}` | `{continue_after_restart, Vsn, Descr}` |

Both replies are sent and *then* `init:reboot()` is called
(`release_handler.erl:1330` and `:1334`). **Both** go through
`prepare_restart_new_emulator/7`, which has two call sites — `:1719` for
`restart_new_emulator` and `:1749` for `restart_emulator` — so both write
`releases/new_start_erl.data`, persist the release as `tmp_current`, and call
`heart:set_cmd/1`. Do not write, in code or in docs, that `restart_emulator`
avoids `heart`: it does not, and that claim was made here once and retracted.
What distinguishes them is the table above, and Castle is built for the
one-stage path.

**`:systools` inserts `restart_new_emulator` by itself.**
`systools_relup:check_for_emulator_restart/5` prepends `[restart_new_emulator]`
to the release-upgrade scripts whenever `erts_vsn` differs between the two
releases, and adds an `erts_vsn_changed` warning;
`systools_rc:sort_emulator_restart/3` then hoists it to the front of the
translated script, "this must be done first for upgrade and last for
downgrade". Changes to `kernel`, `stdlib` or `sasl` bring it in through those
applications' own appups. So a task that simply asked `:systools` for a relup
would ship the two-stage transition whenever ERTS moved, without anybody having
chosen it. That is the gap `auto` exists to close, and it closes it twice:

- **An ERTS change never reaches `:systools`.** `auto` classifies each edge from
  the two `.rel` files first, and an edge whose ERTS version moved becomes a
  hand-written `restart_emulator` transition. It is not refused — the issue's
  settled position is that ERTS, Elixir and dependency changes *are* restarts,
  and refusing would leave no default path for the commonest real upgrade while
  producing the same relup by hand anyway. It is announced instead, naming the
  instruction and the reply, because that reply is what automation reads.
- **Whatever `:systools` does produce is inspected.** An appup may still name
  `restart_new_emulator` itself, and then `auto` refuses the relup rather than
  writing it. Plain `restart_emulator` from an appup is allowed — it is the same
  transition `auto` would have generated — but announced, because a reboot is
  not what a default strategy implies. `--hot` refuses both.

**A restart relup is written directly, never through `:systools`.** That is the
only way to be certain which instruction lands: `make_relup/4`'s own
`restart_emulator` option (`check_for_restart_emulator_opt/3`) merely *appends*
to a script it still built out of appups, and would still have prepended
`restart_new_emulator` for an ERTS change. The term is
`{ToVsn, [{FromVsn, [], [restart_emulator]}], [{FromVsn, [], [restart_emulator]}]}`.
The description is `[]` because that is what `systools_relup`'s
`extract_description/1` yields for a from-release named without one, which is
how every relup this task has ever generated names them.

`release_handler` evaluates such a script without trouble, and the reasoning is
worth keeping because it looks under-specified: `release_handler_1`'s
`split_instructions/1` splits at `point_of_no_return`, and a script without one
falls through to the clause that puts everything in `After` —
`syntax_check_script/1` accepts `restart_emulator` there, `eval/2` throws it,
and `eval_script/5` returns the atom, which is the branch that calls
`prepare_restart_new_emulator/7` and replies `{ok, ...}`.

**`:systools` runs with `noexec`, and the task writes the file.** Two things
need that. A `--hot` run that is refused only after a relup has been generated
must not have replaced the relup that was already in the output directory —
which post-assembly reads, so replacing it with a rejected plan is worse than
leaving it. And an `auto` run that split its edges has to merge hand-written
entries into the same file as the generated ones, which cannot be done once
`:systools` has written it. The format is `systools_relup:write_relup_file/2`'s
own — `"%% coding: utf-8\n"` then `~tp` and a period — and the output has been
checked byte-identical to `:systools`'s for the fixture's relup. `Forecastle`'s
`encode_relup/1` writes the same bytes for the same reason.

**Application classification.** `auto` needs to know which applications the
project owns the appups for: its own `Mix.Project.config()[:app]` plus
`Mix.Project.apps_paths()` for an umbrella. Everything else — dependencies,
Elixir's own applications, OTP's — is not, and a *version change* in one of them
makes the edge a restart. Applications merely added or removed are left to
`:systools`, whose `add_application` and `remove_application` are hot. Only the
ownership test decides anything; `Mix.Project.deps_apps/0` (which is
`Mix.Dep.cached/0`, and loads the whole dependency tree) and `:code.lib_dir/1`
are reached only to *label* something already found, so a project whose deps
have not moved never pays for either. `:code.lib_dir/1` resolves an OTP
application whether or not it is loaded, but it resolves dependencies and
Elixir's applications too, so OTP membership is the path being under
`:code.lib_dir/0` — and Elixir's applications are a hardcoded list, because
theirs sits under Elixir's lib directory and looks like a dependency's.

**This is why the fixture's default transition is now a restart.**
`:sample_dep` is a dependency whose version moves with the sample's, so `auto`
makes `0.1.0 -> 0.1.1` a restart, and `upgrade_test.exs` asks for `--hot`
explicitly — which is the honest thing for a suite whose whole subject is the
hot upgrade. `SAMPLE_DEP_VSN` exists to pin that dependency so that a
project-only transition can be assembled at all; `relup_test.exs` builds a third
release with it to cover the branch of `auto` that does reach `:systools`.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/forecastle.ex` | Release step hooks (the whole of the build-time logic) |
| `lib/mix/tasks/compile/appup.ex` | `:appup` compiler — evaluates the file named by the `:appup` project key and writes `<app>.appup` into `ebin` |
| `lib/mix/tasks/forecastle.relup.ex` | `mix forecastle.relup` — chooses an upgrade strategy per transition, and writes the relup |
| `priv/castle.sh.eex` | EEx template for `bin/castle`, the release management CLI |
| `priv/env.sh.eex` | EEx template for the fragment appended to the release's `env.sh` |
| `test/fixtures/sample` | A real application, assembled by the test suite into a real release |
| `test/fixtures/sample/dep` | An application the relup never mentions, whose version moves with the sample's unless `SAMPLE_DEP_VSN` pins it |
| `test/support` | The workspace the fixture is built in, the case template for tests that build it, and the helpers that drive one once it is built |

## Working on this project

- Run `mix precommit` before committing. It is the single validation gate —
  `compile --warnings-as-errors`, `deps.unlock --unused`, `format`,
  `credo --strict`, `test --include e2e`. Do not run the individual checks
  piecemeal.
- `@version` in `mix.exs` is the single source of truth for the version.
- Add user-visible changes to `RELEASE.md` on the feature branch, using
  [Keep a Changelog](https://keepachangelog.com/) sections. Do not defer release
  notes to release time, and exclude internal CI/lint churn.
- Release with `mix publisho <patch|minor|major>`, which bumps `@version`, folds
  `RELEASE.md` into `CHANGELOG.md` at the `<!-- %% CHANGELOG_ENTRIES %% -->`
  placeholder, commits and tags. Tags are bare semver — no `v` prefix. Pushing
  a tag triggers `.github/workflows/publish.yml`, which publishes to Hex.
- Never commit directly to `main`; work on a feature branch and open a PR.

## Tests

The suite works by building the fixture application in `test/fixtures/sample`
into a real release, in a workspace under `_build/fixtures`. Delete that
directory to start from a clean slate.

| Suite | What it covers |
| --- | --- |
| `test/forecastle_test.exs` | The step functions, against a synthetic `Mix.Release` |
| `test/forecastle/assembly_test.exs` | The assembled tree, including `bin/<name>` being byte-identical to the launcher plain Mix produces |
| `test/forecastle/castle_cli_test.exs` | `bin/castle` as a shell script, against a launcher stub that records its arguments |
| `test/forecastle/configuration_test.exs` | A release that names its own runtime configuration file and declares providers whose init arguments are not keyword lists — assembled, and booted through `bin/<name> eval` |
| `test/forecastle/relup_test.exs` | `mix forecastle.relup` as a command, against three assembled releases: argument handling, exit status, and all three upgrade strategies |
| `test/forecastle/upgrade_test.exs` | Booting a release and hot-upgrading it, including the code path of an application the relup does not load, tagged `:e2e` |

The `:e2e` suite is excluded by default and included by `mix precommit`. Run it
on its own with `mix test --include e2e`. It needs no epmd daemon: the fixture
configures distribution without one.

`configuration_test.exs` is where the two #6 defects are pinned, and it is
deliberately behavioural: there is nothing left in `lib/` to unit-test, so what
it asserts is that the release carries the file the project asked for and that
`init/1` saw the term the project wrote. The fixture's `Sample.EchoProvider`
returns its argument, which is what makes the second observable at all.

## Known limitations

- **Windows is not supported.** The `.bat` launcher boots — Mix writes the
  `sys.config` it reads — but `bin/castle` is a POSIX shell script and is only
  written for a release that asks for unix executables, so nothing on a Windows
  deployment can unpack, install or commit an upgrade. Assembly warns. Real
  support is a feature, not a fix.
- **A system that cannot write `releases/RELEASES` cannot be upgraded, only
  restarted.** The start warns, the system runs, and Castle then refuses `unpack`
  and `install`. There is nothing `bin/castle` could do about it from outside:
  `release_handler` reads that file in its `init` and never again, so creating it
  changes no record the running node holds. What the refusal costs if it is ever
  ignored — through an older launcher, whose `bin/<release>` a hot upgrade does
  not replace — is that `get_new_libs/2` is seeded from the running
  record, so an empty one means nothing compares as changed, and only the
  applications the relup explicitly loads code for get `code:replace_path`. Every
  other application whose version moved stays reachable through the superseded
  release's directory, which the next `remove` deletes.
  `test/forecastle/upgrade_test.exs` covers that shape with `:sample_dep`, whose
  version changes and whose appup asks for nothing.
- **Root scripts do not update through a hot upgrade.** `release_handler`
  extracts with `keep_old_files`, so `bin/<release>` and `bin/castle` are
  whatever the deployment was first built with. New files do appear, so a
  migrating deployment gains `bin/castle`, but keeps its old launcher. Mix's own
  launcher has always behaved this way; do not add a dispatcher to work around
  it without deciding that question for `bin/<release>` too.
- **The emulator-restart transitions are unproven.** A relup that asks for one
  can now be generated — `mix forecastle.relup --restart` — and
  `relup_test.exs` covers it being generated, accepted by `verify_relup!/2` and
  copied into the release. What is still missing is the transition itself: the
  reboot comes back up on whichever version `releases/start_erl.data` names, and
  only `make_permanent` writes that, while `release_handler` leaves the
  installed version in `releases/new_start_erl.data`. `bin/castle install`
  handles the reply and each branch of that handling is tested against a
  launcher stub, but nothing performs the upgrade end to end until
  [castle#14](https://github.com/ausimian/castle/issues/14) and
  [#10](https://github.com/ausimian/forecastle/issues/10). The `:e2e` suite
  covers the hot-upgrade path only, and any test of a restart relup should
  assert on the relup and the assembled tree rather than on a completed upgrade.
- **`restart_new_emulator` is not supported and is refused, not generated.**
  Adding it is its own piece of work: the provisional boot would have to come up
  and *resume* an upgrade through `new_emulator_upgrade/2`, which is strictly
  more than coming up on a provisional version.
- **An unpacked release holds two `.rel` files, and that is normal.**
  `release_handler:do_unpack_release/4` copies `releases/<name>-<vsn>.rel` into
  `releases/<vsn>/` unconditionally, "for backwards compatibility reasons with
  older systools:make_tar" (OTP-9746), while Mix's own copy in that directory is
  called `<name>.rel`. For a tarball `systools` built the two names are the same
  and the copy is a no-op; for a Mix release they differ and both survive.
  `Castle.Peer` used to take the single `*.rel` in the target's version directory
  and refuse when it found more than one, which made every install on the peer
  path fail — the first thing dropping `build.config` made reachable. Fixed in
  Castle. Do not "tidy up" either file: both are wanted, and they are
  byte-identical anyway.

Do not work the configuration question around in this repo: putting Castle's
logic back into shell-embedded Elixir is the coupling `bin/castle` exists to
remove. `require_releases` was a file test for that reason, and the rule said
that the moment it needed to interrogate the node it became a Castle function.
That is what happened, twice over: first as `Castle.upgradable/0` called from
here, and then — because a question asked in one call and acted on in another is
a question about a moment that has passed — as a check the operations make
themselves. The lesson is the stronger form of the same rule: what the node holds
is Castle's to know, and where a decision rests on it, the decision goes with it.
Nothing here is the place for either.

## Compatibility

Forecastle manipulates `Mix.Release` internals and the layout Mix generates, so
it is sensitive to changes in Elixir's release tooling. The CI matrix runs the
whole suite, `:e2e` included, across Elixir 1.18–1.20 and OTP 27–29 to catch
that early.
