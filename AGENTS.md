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
- **`post_assemble/1`** — writes `bin/castle` and `bin/start`, appends the Castle
  hook to the generated `env.sh`, and copies the `.rel` file and any staged
  `relup` into the release.

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
  launcher's defaults. It is appended, so a project's own `rel/env.sh.eex`
  survives and runs first, and everything in it is gated on
  `$RELEASE_COMMAND` naming a command that starts the system — so an `eval`, an
  `rpc` or a `remote` reaches none of it. That gate is not tidiness: `bin/castle`
  drives every command through `rpc`, so a fragment that ran for those would
  consume the provisional marker while an install was still waiting for the
  reboot. Three things are in it: the `RELEASES` bootstrap above, and the two
  [#10](https://github.com/ausimian/forecastle/issues/10) added, below.
- **The provisional version, after a transition that restarted the emulator.**
  `release_handler` writes the installed version to
  `releases/new_start_erl.data` and deliberately leaves
  `releases/start_erl.data` — where the stock launcher reads `RELEASE_VSN` from —
  naming the version that is still permanent. That is the rollback property, and
  only `make_permanent/1` ever writes that file. So version selection needs no
  code at all *after commit*, and needs this before it.

  **Two markers are required, and both are consumed.** OTP's is written *before*
  the reboot and nothing removes it, so on its own it is not evidence that a
  reboot was asked for: a preparation that failed after writing it leaves a file
  naming a version that was never installed. Castle arms
  `releases/castle-restart-pending` with the same version immediately before
  asking for such an install and clears it if the install failed, so the pair is
  what says a reboot happened — and they have to agree on the version. See
  castle#14 for the arming side.

  **Agreeing on a version is not enough, and making the pair an install
  *attempt's* is Castle's end of the protocol rather than this one's.** Castle
  clears any `new_start_erl.data` an earlier attempt left *before* it arms a
  marker, publishes the marker exclusively so that two attempts cannot share it,
  and records the attempt on a second line so that no install removes another's.
  What that buys this fragment is that OTP's file being there means this
  attempt's own preparation wrote it. **Only the first line of the marker is read
  here** — it is the version, and everything after it is Castle's bookkeeping. Do
  not teach this script to parse the rest.

  **What is atomic is the claim, not the pair.** The `mv` is one operation, so
  whichever start wins it is the only one that can act on the pair. OTP's marker
  is then read and removed in separate steps, and no POSIX operation moves two
  files together — so the two are *not* consumed as a unit, and an earlier
  version of this note, Castle's `AGENTS.md` and this release's own notes all
  said they were. What makes it safe
  is the order: the pending marker goes first, so a start killed anywhere after
  the rename leaves no marker behind, and the next start reads `start_erl.data`
  and boots the version that was permanent. The selection is lost, never
  duplicated, and never applied to a version nothing installed — which is the
  direction this whole design fails in. `Forecastle.EnvScriptTest` covers that
  interruption by planting what it leaves behind.

  Both are gone before the launcher is re-exec'd, which is what stops the second
  pass recurring. The claim is named per process — `castle-restart-consumed.$$` —
  so two starts racing for the marker cannot read each other's, and one left by a
  start that died between the rename and the read is replaced rather than
  trusted.

  **It re-execs `$RELEASE_ROOT/bin/<name>` rather than assigning `RELEASE_VSN`.**
  By the time the launcher sources `env.sh` it has already computed
  `REL_VSN_DIR`, and everything after that hangs off it — `RELEASE_VM_ARGS`,
  `RELEASE_REMOTE_VM_ARGS`, `RELEASE_SYS_CONFIG`, the boot script, the `elixir`
  launcher itself. Assigning the version in place boots the old version's
  everything under the new version's name. A sourced file still sees the
  caller's positional parameters, so `exec … "$@"` loses nothing about how the
  launcher was invoked, and the launcher path is interpolated at assembly time
  the way `bin/castle` interpolates it rather than taken from `$0`.

  The version is validated before any of that: non-empty, no path separator, and
  a version directory that has an `env.sh` and a `start.boot` in it — the first
  because the next pass sources it and the second because it is what boots. A
  pair that does not settle warns and boots the permanent version; no pair at all
  says nothing and does nothing.

  `bin/<name> version` still reports the version in `start_erl.data`, so during a
  provisional boot it names the *previous* one while the node runs the installed
  one. That is right rather than a defect: it prints "the version to be booted",
  which for an uncommitted release is the rollback target. Ask the node if you
  want to know what is running.
- **`heart`, run deliberately defanged.** `release_handler` calls
  `heart:set_cmd/1` while preparing *any* transition that restarts the emulator —
  `prepare_restart_new_emulator/7`, which both restart instructions go through —
  and with no `heart` process that raises `badarg`, so the install failed before
  `init:reboot()` on exactly the externally supervised release this library is
  for. Running the real heart satisfies the handshake through documented
  interfaces only. The alternative, a Castle process registered as `heart`
  answering the internal `{Caller, set_cmd, Cmd}` protocol, was refused:
  `heart:wait/0` is a `receive` with no `after`, so a shim that took the message
  and died would wedge `release_handler`'s gen_server for the life of the node.

  heart must then do nothing, because the supervisor is the only thing that
  starts this release and two authorities starting one service is worse than the
  problem being solved. `HEART_COMMAND` is not set. `HEART_NO_KILL=TRUE`.
  `HEART_BEAT_TIMEOUT` is raised to heart's documented maximum, 65535. And
  `$ROOT/bin/start` — the next entry — does nothing.

  **`HEART_NO_KILL` and the inert `bin/start` are a mandatory pair.** Measured on
  OTP 28.3, with the beam `SIGSTOP`ed so heartbeats stop while the process stays
  alive: heart declines to kill it and **runs the command anyway**. So a
  `bin/start` that really started the release would start it beside a live node,
  precisely because heart was told not to kill that node. The documentation says
  as much once read carefully — *"useful if the command executed by heart takes
  care of this"*.

  **`HEART_BEAT_TIMEOUT` is not decoration either, and it is the one place
  castle#14's agreed design was incomplete.** `HEART_NO_KILL` does not make a
  heart-beat time-out harmless. The port program terminates once it has run the command; the Erlang
  `heart` process then exits `{port_terminated, …}`; heart is a *kernel* process,
  linked to `init` by `new_kernelpid/3`; and `init:terminate/3` halts the node
  when a kernel pid dies. Measured, again on OTP 28.3: the node survived while
  suspended and died the moment it resumed, with
  `Kernel pid terminated (heart) ({port_terminated, …})` and a crash dump. So
  `-heart` at the 60s default introduces a way for a stalled node to be killed
  that a deployment without it did not have, and heart is here to satisfy a
  handshake rather than to watch anything. The maximum timeout is what keeps that
  unreachable.

  **All three are assigned, and `HEART_COMMAND` is unset — they used to be
  defaulted, and that was a hole.** `HEART_NO_KILL="${HEART_NO_KILL:-TRUE}"` and
  friends left a deployment that already had these in its environment with
  active watchdog behaviour, while this file, the README and the release notes
  all said it had none: an inherited `HEART_COMMAND` is a second restart
  authority beside the supervisor, `HEART_NO_KILL=FALSE` restores the kill, and a
  shorter `HEART_BEAT_TIMEOUT` restores the death-by-time-out that the paragraph
  above exists to keep unreachable. There is no opting out of this while the hook
  is in use. heart is here to make `heart:set_cmd/1` return `ok` and for nothing
  else.

  **It overrides rather than refuses, and says so.** An operator who set one of
  these has a configuration conflict, not an emergency, and a failed boot is a
  worse answer than the conflict — but a setting that silently stops taking
  effect is worse than either, so each value actually being displaced is named on
  standard error along with what replaced it and why. A deployment that set none
  of them — every ordinary one — says nothing at all, which is why the checks are
  on the *value* rather than on the variable being set: `HEART_NO_KILL=TRUE`
  already agrees, and an empty `HEART_COMMAND` displaces nothing.

  Measured, and worth having written down because it makes the `HEART_COMMAND`
  case sharper than "an unexpected death would start something": heart runs the
  command on an **orderly** halt as well. On OTP 28.4 with `HEART_COMMAND` set,
  a clean `halt()` produced *"Erlang has closed. Executed …  -> 0.
  Terminating."* So an inherited `HEART_COMMAND` turns every `bin/<name> stop`
  into a restart. The same measurement is what makes the e2e assertion possible:
  `heart:get_cmd/0` reports the port program's command, and the port program
  takes its initial value from the environment, so an inherited command comes
  back out of `heart:get_cmd/0` and the existing "has no command of its own" test
  becomes the discriminator once the suite starts with one set.

  `-heart` is appended to `ELIXIR_ERL_OPTIONS` **only if it is not already
  there**. That guard is load bearing, not hygiene: two `-heart` flags make
  `init:get_argument(heart)` answer `{ok, [[], []]}`, which
  `heart:check_start_heart/0` has no clause for, and the boot hangs with nothing
  printed — measured. The fragment is read twice on a provisional start, so
  without the guard the re-exec would hang every such boot.

  **What holds this to the environment rather than to the text of the script is
  `Forecastle.EnvScriptTest`**, which sources the fragment in a release-shaped
  directory and reports what it left behind. It exists because the assembly-level
  test that used to be the whole of the coverage asserted the `${VAR:-default}`
  expressions were *present*, and so passed against exactly the defect above. Any
  future claim about the effective heart configuration belongs there; the
  assembly suite keeps only the claim that the configuration is in the release's
  `env.sh` and that it assigns.

  Incidental, measured: heart prints `heart_beat_kill_pid = <pid>` on every
  start, and `heart_beat_timeout = <n>` when the variable is set. Two lines of
  noise on the release's own output, not a fault.
- **`$ROOT/bin/start`, inert.** `install_start_program/1` writes it, and
  `priv/start.sh.eex` is the whole of it: a comment and `exit 0`. It is at the
  *default* `start_prg` path deliberately — `init/1` yields
  `{no_check, filename:join([Root, "bin", "start"])}` when `{sasl, start_prg}` is
  unset, and `check_start_prg/2` returns that unexamined, so it needs no
  configuration; naming a path of our own means `{do_check, _}` and injecting
  `:sasl` configuration into the release, which is the interception #6 removed.
  Measured, since it was previously only inferred: heart *does* run this command
  on `init:reboot()` with `HEART_COMMAND` unset, receiving the data file as `$1`.
  So it has to exist and exit 0; it is load bearing rather than decorative.

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
  the two `.rel` files first, and an edge whose ERTS version moved is a restart
  edge — decided there, not by asking `:systools` and taking what comes.
- **Whatever `:systools` does produce is inspected.** An appup may still name
  `restart_new_emulator` itself, and then `auto` refuses the relup rather than
  writing it, because the two-stage transition is not supported at all.
  `restart_emulator` from an appup is the same transition `auto` would have
  chosen for itself, so it is settled the same way `auto`'s own choice is — named
  in the one announcement below. `--hot` refuses both.

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
Elixir's own applications, OTP's — is not. Only the ownership test decides
anything; `Mix.Project.deps_apps/0` (which is `Mix.Dep.cached/0`, and loads the
whole dependency tree) and `:code.lib_dir/1` are reached only to *label*
something already found, so a project whose deps have not moved never pays for
either. `:code.lib_dir/1` resolves an OTP application whether or not it is
loaded, but it resolves dependencies and Elixir's applications too, so OTP
membership is the path being under `:code.lib_dir/0` — and Elixir's applications
are a hardcoded list, because theirs sits under Elixir's lib directory and looks
like a dependency's.

A *version change* in one of those applications makes the edge a restart **only
when no appup covers it**. `auto` describing itself as "hot where it can be" is
otherwise false: it would restart edges `:systools` was about to generate
perfectly well from an appup entry that names exactly this from-version.
Applications merely added or removed are left to `:systools`, whose
`add_application` and `remove_application` are hot.

**Matching an appup from-version is `systools_relup`'s job, not a string
compare.** Verified against OTP 28.3, `sasl-4.3`:

- `get_script_from_appup/5` reads `<app_dir>/<app>.appup`, where `app_dir` holds
  the **target** release's copy of the application. The appup that decides an
  edge is the new version's, keyed by the version being upgraded *from* — for
  both directions.
- it takes the `up` list for an upgrade and the `dn` list for a downgrade. The
  two are independent, so `auto` classifies **each direction separately**: a
  from-version present in one need not be present in the other.
- the entry is selected by `appup_search_for_version/2`. A charlist from-version
  matches by term equality; a **binary** one is a regular expression, run with
  `re:run(BaseVsn, Vsn, [unicode, {capture, first, list}])` and accepted only on
  `{match, [BaseVsn]}` — the whole match must be the from-version, so a prefix
  regex does not match a longer version. That function is exported for reuse
  ("Used by `release_handler:find_script/4`. Also used by kernel, stdlib and sasl
  tests"), so **call it**; do not reimplement the matching, and do not compare
  strings, or `auto` and the `:systools` run a moment later will disagree.

**`auto` announces a restart edge; it used to refuse one.** The refusal existed
because Castle could not *complete* such a transition — `heart:set_cmd/1` raised
`badarg` with no `heart` process — and `auto` is the no-switch default, so
emitting a restart edge meant a routine invocation producing a relup that could
not be installed. [castle#14](https://github.com/ausimian/castle/issues/14) and
[#10](https://github.com/ausimian/forecastle/issues/10) closed that, and
`settle_restarts!/2` is now the whole of the verdict: `([], [])` is the all-hot
line and everything else is one `Mix.shell().info/1` naming both kinds.

**A history worth keeping, because it constrains how the announcement is
written.** An earlier revision of this work had a gate —
`restart_transitions_installable?/0`, a private function returning a literal
`false`, consulted from two call sites. Elixir 1.20's type inference proved the
`true` branch of both dead and `mix compile --warnings-as-errors` failed on them,
which took CI red on all six 1.20 cells. That is why the refusal was deleted
rather than made conditional, and why nothing here may grow a predicate the
compiler can fold: reading application env or a switch makes it user-flippable, a
module attribute folds to the same literal, and there is no suppression pragma.
The lesson generalises past this feature — a feature gate whose branches nothing
reaches is a compile error waiting for the next Elixir.

**`appup_restarts!/1`'s refusal of the two-stage `restart_new_emulator` is gated
on nothing and stays that way.** It never was about whether a restart could be
completed. Castle is built for the one-stage instruction, and the two-stage one
reboots into a temporary hybrid release whose version directory has no `env.sh`,
no `elixir` and no `vm.args` — so there is nothing for the launcher to boot and
Castle arms no marker for it.

**One verdict per invocation.** A restart reaches an `auto` run two ways — `auto`
classified the edge as one, or an appup named `restart_emulator` itself — and only
the first is knowable before the relup exists. So nothing is settled until after
generation: the all-hot line and the restart announcement both live in
`settle_restarts!/2`, which runs there. Announcing from classification alone says
every transition is hot and then reports a restart; that shipped once, and now
that such a run *succeeds* it would print both from a successful invocation. Do
not add a second announcement anywhere else. `relup_test.exs` asserts the
all-hot line is absent from every `auto` case that ends in a restart —
`refute_all_hot/1` matters more now, not less.

**Where the earlier plan for this change was wrong, so it is not re-derived.**
This file used to carry a step-by-step account of what castle#14 had to add here,
and one item of it did not survive contact. It said the two mixed-restart tests
both inverted to "zero exit, a relup written, and both causes in the one
announcement". That is true of the first — now *"names both kinds of restart in
one announcement"* — and false of the second: that test deliberately removes
`sample.appup` so the hot half cannot be generated at all, and once the
pre-generation refusal is gone, generation runs first and the `:systools` error
*is* the verdict. It is now *"reports a systools error from the hot half rather
than announcing anything"*, and what it pins is the new ordering rather than the
old one. There is nothing left to announce about a relup that was not produced.

Everything else in that plan held: `refuse_chosen_restarts!/1`,
`refuse_restarts!/2` and `describe_remedies/2` are gone with the refusal;
`describe_causes/3`, `describe_edges/1` and `describe_restarts/1` are what the
announcement reuses; and `plan_transitions!/5` stays `@doc false`-public even
though the task reaches the merge now, because what the merge tests assert is a
term rather than anything the task prints.

The announcement is covered in the three shapes it can take — a restart
classification chose, one an appup asked for by name, and a plan carrying both —
and each of those cases now asserts the *relup* as well as the wording, because
an announcement is a claim about a file and the file is the thing that gets
installed.

The split-and-merge — the path that puts hand-written restart entries and
generated hot ones into one relup — is reachable through the task now, and the
mixed-restart cases in `relup_test.exs` go through it. `plan_transitions!/5`
stays `@doc false`-public anyway, and `relup_test.exs` still drives it in
process, because what those tests assert is the *shape* of the merged plan: which
from-version keeps which script, in which direction. That is a term, and reading
it back off disk through the task would say less. Keep the settling **outside**
that function rather than inside it; that is what keeps the merge callable. What
must stay inside is the unconditional refusal of `restart_new_emulator`
(`appup_restarts!/1`), which is not conditional on anything: it returns the
one-stage restarts and raises on the two-stage ones.

**The merge tests have to pin the direction, not just the shape.** Both sections
of the fixture's mixed relup carry the same from-versions, the same restart
script and the same module, so the only thing that tells an up script from a down
one is the application version in its `load_object_code`: `systools_rc` resolves
the module against the target release's applications for `up` and against the
from-release's for `dn`. Assert that version (`@hot_vsn` up, `@from_vsn` down), or
swapping the two sections at the merge — downgrade code packaged as the
upgrade — passes. There is also one deliberately asymmetric plan, with a restart
edge on the way up and none on the way down, so that a merge which swapped or
reused its up and down *arguments* cannot produce the same set twice and pass.

**The fixture's default transition is hot.** `:sample_dep` is a dependency whose
version moves with the sample's, but its appup covers `0.1.0` in both directions,
so `auto` judges `0.1.0 -> 0.1.1` hot. `upgrade_test.exs` still asks for `--hot`
explicitly, so that the task rather than an assertion is what fails if that ever
stops being true. `SAMPLE_DEP_VSN` pins the dependency so that a project-only
transition can be assembled; `relup_test.exs` builds a third release (`0.1.2`)
with it, which is the hot edge in the merge test and the target of the tests
about appup-supplied instructions. The `auto` cases that need a restart edge are
made by rewriting `sample_dep`'s appup in the assembled target release, not by
changing the fixture.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/forecastle.ex` | Release step hooks (the whole of the build-time logic) |
| `lib/mix/tasks/compile/appup.ex` | `:appup` compiler — evaluates the file named by the `:appup` project key and writes `<app>.appup` into `ebin` |
| `lib/mix/tasks/forecastle.relup.ex` | `mix forecastle.relup` — chooses an upgrade strategy per transition, and writes the relup |
| `priv/castle.sh.eex` | EEx template for `bin/castle`, the release management CLI |
| `priv/env.sh.eex` | EEx template for the fragment appended to the release's `env.sh` |
| `priv/start.sh.eex` | EEx template for `bin/start`, the inert program heart is handed |
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
| `test/forecastle/env_script_test.exs` | The `env.sh` fragment as a shell script, sourced in a release-shaped directory with a launcher stub: the heart environment it leaves behind, and which provisional version each state of the two markers selects |
| `test/forecastle/configuration_test.exs` | A release that names its own runtime configuration file and declares providers whose init arguments are not keyword lists — assembled, and booted through `bin/<name> eval` |
| `test/forecastle/relup_test.exs` | `mix forecastle.relup` as a command, against three assembled releases: argument handling, exit status, and all three upgrade strategies |
| `test/forecastle/upgrade_test.exs` | Booting a release and hot-upgrading it, including the code path of an application the relup does not load, tagged `:e2e` |
| `test/forecastle/restart_upgrade_test.exs` | The same shape through an emulator restart: the OS pid changes, an uncommitted release rolls back when killed, and a commit makes it what an ordinary start boots. Tagged `:e2e` |

The `:e2e` suite is excluded by default and included by `mix precommit`. Run it
on its own with `mix test --include e2e`. It needs no epmd daemon: the fixture
configures distribution without one.

`restart_upgrade_test.exs` is the hot suite's opposite where it counts —
`refute provisional.os_pid == booted.os_pid` against the hot suite's
`assert installed.os_pid == booted.os_pid` — and it has one thing no other suite
does: **it is the supervisor.** Nothing in the release restarts it after
`init:reboot()`, deliberately, so `Forecastle.Deployment.install_supervised!/3`
runs `bin/castle install` in a task, waits for the old *operating system process*
to go, and starts the release again. Waiting on the process rather than on the
node matters: a node that has stopped answering rpc is not necessarily one that
has exited, and starting the replacement while the old beam still holds the
distribution port is a name clash rather than a boot.

**It also runs the whole transition on a hostile environment**, and that is not
incidental colour: `HEART_COMMAND`, `HEART_NO_KILL=FALSE` and an 11-second
`HEART_BEAT_TIMEOUT` are in the deployment's environment for the first start, so
a fragment that only *defaulted* them would have this suite exercising a release
with a live watchdog beside its supervisor. What is asserted is what the node
says it was started with — `{nil, "TRUE", "65535"}` — plus the warning naming
each displaced value, and, on the one start with a clean environment, silence.

`env_script_test.exs` is the other half of that, and the division between the two
is worth keeping: this suite proves the effective configuration survives a real
boot and a real reboot, and that one proves each individual override and each
marker state, cheaply and without a `mix release`. Neither replaces the other,
and **no claim about the effective heart configuration belongs in
`assembly_test.exs`** — asserting the text of the fragment is what let the
defaulted version pass.

Three of its assertions are load bearing in ways the obvious ones are not.
`RELEASE_VM_ARGS`, which `runtime.exs` reads with `fetch_env!`, is derived by the
launcher from `REL_VSN_DIR` *after* `env.sh` is sourced — so the provisional
node reporting the *new* version's `vm.args` is what says the fragment re-execs
rather than assigning `RELEASE_VSN` in place. `SAMPLE_GREETING` changes between
the first boot and the provisional one, so the provisional node answering the
second value is what says the version's own config providers ran again over the
`sys.config` Castle materialised — which is also the only coverage of that
interaction anywhere. And the rollback half comes *before* the commit half,
because the only way to see a provisional release roll back is to kill one; the
second install then goes through the same transition again from the release that
came back.

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
  extracts with `keep_old_files`, so `bin/<release>`, `bin/castle` and
  `bin/start` are whatever the deployment was first built with. New files do
  appear, so a migrating deployment gains `bin/castle` and `bin/start`, but keeps
  its old launcher. Mix's own launcher has always behaved this way; do not add a
  dispatcher to work around it without deciding that question for
  `bin/<release>` too.

  What this costs the restart path is worth stating: the heart configuration and
  the provisional-version selection are in `releases/<vsn>/env.sh`, which a hot
  upgrade *does* replace, so a deployment can take one hot upgrade to this
  release and a restart transition after it. It cannot take a restart transition
  as the *first* upgrade from an older deployment — the running node came up on
  the old version's `env.sh`, so there is no `heart` process, and the install
  fails in `heart:set_cmd/1` before anything reboots.
- **An emulator restart needs something outside the release to start it again.**
  That is the design rather than a gap: `bin/start` is inert, `HEART_COMMAND` is
  unset, and the supervisor is the only restart authority. A deployment run by
  hand from a shell therefore stays down after such an upgrade until somebody
  starts it — and comes back on the installed version when they do, because the
  markers are still waiting. Only systemd has been exercised in anger; Docker
  restart policies and runit are the same shape but unmeasured, and `:e2e` stands
  in for a supervisor by starting the release itself.
- **`restart_new_emulator` is not supported and is refused, not generated.**
  Adding it is its own piece of work, and for two reasons rather than one. The
  provisional boot would have to come up and *resume* an upgrade through
  `new_emulator_upgrade/2`, which is strictly more than coming up on a provisional
  version — and the version `release_handler` writes into `new_start_erl.data` for
  it is the temporary hybrid release, `__new_emulator__<current>`, whose version
  directory `new_emulator_make_hybrid_boot/6` gives a `start.boot` and a
  `sys.config` and none of the launcher's own files. There is no `env.sh` to
  source, no `elixir` to run and no `vm.args` to read, so the fragment could not
  select it even if it wanted to; Castle arms no marker for that transition.
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
