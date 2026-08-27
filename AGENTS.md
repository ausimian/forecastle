# Forecastle

Build-time support for hot-code upgrades in Elixir releases. Forecastle is the
build-time half of a pair: [Castle](https://github.com/ausimian/castle) is the
runtime half. Consumers depend on Castle, which pulls Forecastle in as a
build-time dependency — Forecastle is not intended to be taken directly.

## What it does

`Forecastle.steps/1` wraps a Mix release's `:steps` list, injecting four hooks
around `:assemble`:

- **`pre_assemble/1`** — checks and stages any `relup`, refuses a project-root
  `relup` and an `upgrade_from:` option together, reads and checks the appup
  sources in `rel/appups`, and adds a `:preboot` boot script that starts
  `:sasl`, `:compiler`, `:elixir` and `:castle`.
- **`post_assemble/1`** — writes `bin/castle` and `bin/start`, appends the Castle
  hook to the generated `env.sh`, copies the `.rel` file and any staged `relup`
  into the release, and places the staged `rel/appups` sources at
  `lib/<app>-<vsn>/ebin/<app>.appup`.
- **`generate_relup/1`** — generates this release's relup from its
  `upgrade_from:` option and writes it into the version path. Immediately before
  `:tar`, *after* any function step the project put between `:assemble` and
  `:tar`; see *The relup generated during assembly*.
- **`refuse_late_upgrade_from/1`** — refuses a build whose `upgrade_from:` is not
  the one `pre_assemble/1` resolved. Appended after every other step, and called
  from `generate_relup/1` as well; see *A late `upgrade_from:` is refused*.

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
  whole `--rpc-eval … :noconnection` diagnostic on one complete line, never as
  the bare word, which is a usable release version and turns up in the messages
  that name a version that failed — which is also why `validate_vsn` refuses
  control characters, since a version carrying a newline could otherwise forge
  that line for itself. Classification and filtering live behind two shell
  helpers; operator-facing copy does not share their pattern.
  `Forecastle.AssemblyTest` asks the real generated Mix launcher to call an
  unreachable local node and compares its stderr line to this contract across
  the supported Elixir matrix; do not replace that measurement with another
  restatement of the literal.

  Managed versions are valid UTF-8 with no C0, DEL or C1 controls. The validator
  distinguishes unsafe input from an unavailable `od` or `awk`; both refuse the
  command, but unavailable validation is reported as such instead of blaming the
  value.

  **Nothing in either script may express that contract as `[[:cntrl:]]`, and the
  reason is measured rather than theoretical.** A character class is resolved by
  the shell against the locale the release inherited, so it describes the host
  and not the contract. Across the shells a release can be started by: dash, and
  bash under `LC_ALL=C`, match C0 and DEL; bash in a UTF-8 locale also matches
  the C1 block, and glibc's tables put U+2028 and U+2029 in the class besides.
  Both directions of error follow — the class refuses codepoints the contract
  permits on some hosts, and accepts C1 on others — so the accepted set became a
  property of the locale. `castle_controls`, a literal set of the C0 bytes and
  DEL built with `printf`, is what both scripts use instead; it is identical
  under every shell and locale measured. NUL never reaches it, since no shell
  variable can hold one.

  In `bin/castle` that set is only a shortcut in front of the decoder, which
  stays authoritative for invalid UTF-8 and C1 — and the shortcut is now
  restricted to bytes the decoder also forbids, so it can never refuse a value
  the decoder would accept. **The `env.sh` fragment has no decoder and is not to
  be given one**: selection after the claim must not depend on `od` or `awk`
  being present, or a missing tool turns a prepared reboot into a refused one.
  So the fragment refuses C0 and DEL byte-exactly and says nothing about C1.
  That is a real limit and not a hole — a POSIX shell has no portable way to
  match the C1 block, whose UTF-8 encoding is two bytes that bash in a UTF-8
  locale sees as one character and dash sees as two, so a bracket of the
  composed characters would refuse every ordinary version carrying U+00A0 to
  U+00BF under dash. What closes it is that no release is selected on that check
  alone: the two markers still have to name one version, and the version
  directory still has to hold an `env.sh` and a `start.boot`. Castle validates
  through the decoder before it ever writes a marker. Its displayed value is independently encoded and falls back to
  `<unprintable>` if the display tools are unavailable too.

  The version-less `commit` has a separate protocol of its own. The remote
  expression appends one of two exact record lines, for no provisional release
  or a successful commit. Each record carries the wrapper invocation's tag,
  built from `$$` to separate concurrent invocations and reused ordinary output.
  It is an identifier, not an unpredictable secret, and does not defend against
  stdout deliberately forged with the current tag. The done record follows an
  explicit `:ok = Castle.commit(...)`, so a changed Castle return contract cannot
  accidentally report success.
  The launcher may write after the expression returns, so the wrapper takes the
  last exact matching record and strips only that line. Earlier token-like output
  and output after the record remain operator output, and the local human
  diagnostic can change without changing control flow. The record remains
  authoritative if the launcher exits non-zero after emitting it. If the parser
  itself is unavailable, captured output is withheld because it may contain the
  record. A status-zero reply
  without a recognised record is a protocol failure: its captured output is
  reported, the commit is described as possibly permanent, and the operator is
  directed to `bin/castle releases`. Once a record is recognised, filtering
  ordinary output cannot change its outcome: a filtering failure reports that
  the output was unavailable without replaying the machine record.

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
  arrive sooner. There is nothing left for it to buy: `Castle.install/1` used to
  materialise the target's configuration ahead of the operation, so a refused
  install started a peer first, and that composition has since been folded into
  `Castle.Commands.install/5` — behind the record check and behind the
  pending-marker refusal — precisely because materialising ends in a rename onto
  the target's `sys.config` and so is not the harmless idempotent work it was
  described as here. A refused install now configures nothing.

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

  OTP constructs its marker as `EVsn ++ " " ++ Vsn`. The fragment splits at the
  first literal space and preserves the remainder as the release version; this
  matters because Mix permits spaces in versions and Castle manages them. POSIX
  shell parameter expansion makes that split and its structural validation
  explicit without forking a parser after Castle's marker has been claimed.
  Selection must remain fork-free: failure of a display utility cannot reject
  valid reboot evidence, quarantine it, or stop the boot. A malformed line is
  renamed to the inert `new_start_erl.data.rejected.<pid>`, warns, and falls back
  to the permanent version. Its diagnostic uses a fixed malformed-line label
  rather than echoing the untrusted contents, which may contain terminal control
  bytes.

  **A fixed label is for a line that could not be parsed, never for a version
  that merely looks unusual — and a space is the case that proves it.** This
  fragment reached the encoder by way of two display guards that matched
  `[[:space:]]` beside `[[:cntrl:]]`, which reported any version carrying the
  space the paragraph above says is *preserved* as
  `<non-empty line containing whitespace or control bytes>`. That is the case
  where naming the release matters most: the pair can fail to settle for a
  reason having nothing to do with the version — mismatched markers, a version
  directory with no `env.sh` — and the label was then the only thing telling the
  operator which releases to inspect. The encoder answers it structurally, since
  `0x20` is inside the printable ASCII range it passes through untouched, so
  there is no guard left to get wrong. What must not come back is a *class* of
  value being withheld for looking odd: everything unsafe is already
  percent-encoded byte by byte, and `<unprintable>` is reserved for a
  representation that could not be produced at all.

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

  **This block comes first in the fragment, ahead of everything else it does, and
  that ordering is load bearing. Do not move it.** The re-exec means the fragment
  is read twice, so anything decided before the selection is decided about the
  version being *replaced* — and exported to the pass that boots. It shipped the
  other way round, with `heart` ahead of the selection, and that is exactly what
  went wrong: pass 1 probed the permanent version's `vm.args`, found no `-heart`
  and exported `ELIXIR_ERL_OPTIONS=-heart`; pass 2 probed the target's, measured
  the inherited flag beside the target's own, and so declined to append a third —
  but nothing removes what pass 1 exported, so a target carrying its own `-heart`
  booted with two and hung. Measuring on both passes and appending on neither is
  not a fix for that; there being only one pass that decides anything is.
  The same ordering is what makes the probe's emulator unambiguous, since the
  release whose `elixir` names it is then the selected one.

  A consequence worth stating: a target release whose `env.sh` is not Forecastle's
  gets no `heart` configuration at all, because the pass that would have set it
  execs away first. That is right — such a release has no Castle upgrade path into
  it in the first place — but it is a behaviour change from the order this had, and
  it is the reason not to "helpfully" export anything else across the re-exec.

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
  effect is worse than either, so each setting actually being displaced is named
  on standard error along with what replaced it and why. Values use a reversible
  ASCII representation: visible ASCII is preserved, `%` and every other byte are
  percent-encoded. Unicode paths stay identifiable and C0, DEL, C1 and invalid
  UTF-8 cannot forge log lines or control a terminal. A deployment that set none
  of them — every ordinary one — says nothing at all, which is why the checks are
  on the *value* rather than on the variable being set:
  `HEART_NO_KILL=TRUE` already agrees, and an empty `HEART_COMMAND` displaces
  nothing.

  Formatting fails closed: a diagnostic whose representation cannot be produced
  uses the fixed `<unprintable>` label. Every formatter substitution supplies that
  fallback explicitly because this fragment is sourced under `set -e` and a
  diagnostic must never stop the boot. Marker selection itself does not depend on
  `od`, `awk` or any other display tool, and successful selection does not invoke
  the formatter at all; marker values are formatted only when a warning needs
  them.

  **A variable set to nothing is a value, and `${VAR:-default}` cannot see
  that.** It treats set-and-empty as absent, which is what these were written
  with, so `HEART_NO_KILL=` and `HEART_BEAT_TIMEOUT=` were displaced in silence —
  neither is the value that gets assigned, so both were being overridden while
  the promise above is to name every value that stops taking effect. The two
  assigned ones therefore use `${VAR-default}`, without the colon: unset takes
  the default and says nothing, set-and-empty compares unequal and is reported as
  `[]`. An empty `HEART_COMMAND` stays silent, and that is a *different* rule
  rather than the same one — unsetting a variable that was already empty changes
  nothing heart can read, so there is nothing to tell an operator. Do not
  "consistently" collapse the two back together.

  Note for whoever writes the next test here: an empty value in `System.cmd/3`'s
  `:env` **removes** the variable, the same as `nil` does, so the case that named
  this state could not be arranged that way and the test that claimed to was
  really testing the unset one. `Forecastle.EnvScriptTest` prefixes shell
  assignments to the command for the empty ones instead.

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

  `-heart` is appended to `ELIXIR_ERL_OPTIONS` **only if the emulator is not going
  to be given one anyway**. That guard is load bearing, not hygiene: two `-heart`
  flags make `init:get_argument(heart)` answer `{ok, [[], []]}`, which
  `heart:check_start_heart/0` has no clause for — a `case_clause` at
  `heart.erl:348` — and the boot hangs with nothing printed; measured. What the
  guard is for is a deployment supplying its own flag — in its `vm.args` or in one
  of the variables `erlexec` reads. It used to have to cover the fragment's own
  flag as well, because this block ran ahead of the provisional selection and so on
  both passes of a re-exec, and it could not: see that block for what that cost.
  This block now runs once per boot, on the pass that boots.

  **The guard asks `erlexec` what the argument vector came out as. It does not
  read the environment and decide, and three versions of it that did were each
  refuted by a narrower counterexample than the last.** Write the series down,
  because the lesson is the series rather than any one entry in it:

  1. `case " $ELIXIR_ERL_OPTIONS " in *" -heart "*` — a match bounded by literal
     spaces. Mix's generated `elixir` expands that variable **unquoted** (`set --
     … $ELIXIR_ERL_OPTIONS $ERL "$@"`), so what reaches the emulator is its fields
     under `$IFS`: space, tab and newline. `-heart<TAB>-noshell` carries a live
     flag this could not see.
  2. Two loops splitting the fields of `ELIXIR_ERL_OPTIONS`, `ERL_AFLAGS`,
     `ERL_FLAGS` and `ERL_ZFLAGS`. `erlexec` prepends the second and appends the
     third and fourth to the command line it builds, so all four reach
     `init:get_argument(heart)` — but it also applies **shell-style quoting and
     backslash escaping** to the three it reads itself, so `ERL_AFLAGS="'-heart'"`,
     `ERL_FLAGS='"-heart"'` and `ERL_ZFLAGS='-he\art'` all arrive as `-heart`
     while carrying no `-heart` substring at all. Measured.
  3. The same, plus a literal scan of `vm.args` — the launcher passes it as
     `-args_file`, so a project's own `rel/vm.args.eex` is a fifth source. Wrong in
     three further ways at once: the escapes above apply to the file too,
     `erlexec` treats `#` as a comment there *except inside a quoted value*, and it
     follows a nested `-args_file` that no shell can see through.

  **Every one of those shipped with a unit test that agreed with it**, because the
  test mirrored the same model — see `Forecastle.EnvScriptTest`'s note on its own
  counter. There was no reason to think the series had ended, so it was not
  continued.

  `erl -emu_args_exit` prints the argument vector `erlexec` assembled, one
  argument per line, and **exits without starting a VM**. So the fragment runs
  that with the start's own environment, its own unquoted `$ELIXIR_ERL_OPTIONS` and
  its own `-args_file`, in the order Mix's `elixir` would put them, and looks for a
  line that is exactly `-heart`. That is not an approximation of the union of the
  sources — it *is* the union, including `ERL_OTP<major>_FLAGS`, which the fragment
  can neither name nor needs to.

  Six properties of that, each load bearing:

  - **The emulator asked is the one the launcher will run, and the fragment is told
    which that is by the file that decides it.** The launcher execs
    `$REL_VSN_DIR/elixir`, and the only thing in that script choosing an emulator
    is its `ERTS_BIN`: `mix release` rewrites Mix's own `ERTS_BIN="$ERTS_BIN"` into
    `ERTS_BIN="$SCRIPT_PATH"/../../erts-<vsn>/bin/` when the release brought an
    ERTS, and leaves it alone when it did not — in which case `ERTS_BIN` is empty
    and `erl` comes off `PATH`. That script's `SCRIPT_PATH` is the directory it is
    in, which is `REL_VSN_DIR`, so the fragment reads the assignment out of the
    same file the exec will read it out of and resolves it against `REL_VSN_DIR`.
    Anything that does not come out executable falls back to `erl`, which is what
    an un-rewritten assignment means anyway. **This is the resolution, not a model
    of it, and that is the point** — the same rule as asking `erlexec` rather than
    parsing the environment.

    It used to expand a glob over the release root's `erts-*` directories and keep
    the last executable it found. That is wrong the moment the root holds more than
    one of them, which is what unpacking an ERTS-changing release leaves behind,
    and the last one a glob yields is the *lexicographically* last — not even the
    newest, since `erts-9.9` sorts after `erts-16.2`. `ERL_OTP<major>_FLAGS` is
    named for the OTP version of whichever binary answers, and an args file may be
    written for one emulator and not another, so asking the wrong one is a question
    about a different deployment rather than a near miss. `Forecastle.AssemblyTest`
    refutes the glob in the shipped file, and the fragment's own prose deliberately
    does not repeat its spelling so that the refutation is about the code.

  - **It cannot hang, so it needs no timeout.** A deployment already carrying two
    `-heart` flags — the boot this guard exists to prevent — makes it print two
    lines and exit 0.
  - **`-emu_args_exit` is undocumented** — present in the `erlexec` binary in OTP
    27, 28 and 29, absent from the usage string and the documentation. Relying on
    it is acceptable *because it fails safe*, and the fragment makes that true
    rather than assuming it: the probe carries `-boot /nonexistent/…`, so an
    `erlexec` that passed the flag through would fail on a boot file that cannot
    exist instead of starting a node, and the output is believed only if it
    contains a `-root` line, which every vector `erlexec` builds has. Both
    failures land in the same branch as an unreadable `-args_file`: add nothing,
    and say so on standard error.
  - **The probe always runs on a start, and there is deliberately no gate in front
    of it.** There was one: a `case` over the four flag variables and a `read` loop
    over the args file, looking for `heart`, `args_file`, a quote, a backslash or a
    glob character, so that an ordinary deployment forked nothing. **It was removed
    on purpose and it must not come back.** It was the last thing in the fragment
    reasoning about the *text* of those values rather than measuring them, and its
    soundness rested on a claim about `build_args_from_string()` in `erlexec.c`
    removing nothing but quotes and backslashes — a claim about a C state machine,
    of exactly the kind that was wrong three times above. And it left a hole it
    could not close, which is the next point.

    What every start now pays is **one `fork`+`exec` of a C program that exits
    without booting an emulator** — about 11ms, measured — and it is paid once per
    node start, because the whole fragment is gated on `$RELEASE_COMMAND` naming
    `start`, `start_iex`, `daemon` or `daemon_iex`. An `eval` or an `rpc` reaches
    none of it, which is what keeps the fork off `bin/castle`'s path.
  - **All six sources are covered, `ERL_OTP<major>_FLAGS` included.** That is the
    hole the gate could not close: POSIX sh cannot enumerate environment variable
    *names*, and `env` and `export -p` both need a fork of their own to look for a
    variable whose name carries the emulator's OTP major — one that `erlexec`'s own
    source calls "intentionally undocumented and intended for OTP internal use
    only". So a deployment setting only that variable never tripped the gate,
    received a second `-heart`, and hung the boot having printed nothing. The probe
    sees it because `erlexec` reads it, and `Forecastle.EnvScriptTest` pins that
    with a case deriving the variable's name from the running OTP major.
  - **The one condition left is a fact about the filesystem, not a judgement about
    contents.** `-args_file` is passed only when the path exists, because `erlexec`
    refuses an args file it cannot open and exits non-zero — which would make every
    start with no readable args file report the measurement as impossible and
    decline to add the flag. **It is defensive rather than load-bearing**, and an
    earlier note here overstated it as covering "a release with no `vm.args`, a
    supported shape". A stock build does not produce that: `mix release` always
    renders `rel/vm.args.eex` into `releases/<vsn>/vm.args`, so the launcher's own
    `${RELEASE_VM_ARGS:-…}` default always resolves to a file that exists. What is
    reachable is a deployment exporting `RELEASE_VM_ARGS` to a missing path, or a
    hand-deleted `vm.args` — both starts the launcher fails on moments later
    anyway. So it costs nothing and spares a doomed start a confusing warning,
    rather than holding up the common case.
    Every variable `erlexec` reads still reaches the probe, `ERL_OTP<major>_FLAGS`
    among them, so nothing goes unmeasured; only a file that is not there goes
    unmentioned. A path that exists and cannot be read is still handed over and
    still reported, because that one is worth knowing about.

  The coverage follows the same rule: **do not validate any of this with a shell
  counter**, whatever shape it takes, because what such a counter measures is
  somebody's model of `erlexec`. `Forecastle.EnvScriptTest` counts by asking a real
  `erlexec` with `-emu_args_exit`, over a matrix of quoted, double-quoted,
  backslash-escaped and whitespace-separated values in each variable and in
  `vm.args`, plus `ERL_OTP<major>_FLAGS` under its real name, a nested args file, a
  commented flag, and an emulator that does not know the flag. It also records
  every invocation of the release's own `erl`, which is the only way to see whether
  the fragment probed and what it probed with — so an ordinary start asserts one
  invocation rather than none, and a missing `vm.args` asserts one carrying no
  `-args_file`. Cases asserting *no* invocation of it mean one of three things,
  and the distinction matters: a `$RELEASE_COMMAND` that does not start the
  system probed nothing at all, while the `include_erts: false` shape and a
  version directory with no `elixir` probed `PATH`'s emulator instead — which is
  what the launcher would run. A second emulator installed under another `erts-*`
  writes to its own log, which is the only way to see *which* one answered; that
  is what pins the resolution against the glob it replaced, and it is also how a
  provisional start is held to asking the target's.

  `Forecastle.RestartUpgradeTest` is the real boot, and the fixture's own
  `rel/vm.args.eex` carries the flag spelled **`-he\art`**. That is the point of
  it: `erlexec` unescapes it and the booted node answers
  `init:get_argument(heart) == {ok, [[]]}`, so the only way for the fragment to see
  it is to ask. `ERL_AFLAGS` carries `-env CASTLE_TAB_PROBE tabbed` behind tabs —
  `erlexec` splits that variable on tabs as readily as on spaces, measured — so the
  node answering with the value says the tabs really were separators, and the value
  carrying no `heart` of its own says that asking about an unremarkable flag
  variable does not manufacture a second flag. The suite additionally asserts
  `ELIXIR_ERL_OPTIONS` is **unset** in the running node, which is what says the
  fragment added nothing beside a flag no reading of that file could have found.

  `Forecastle.Fixture` scrubs all four variables, `ERL_OTP<major>_FLAGS`, and both
  `RELEASE_*VM_ARGS`. The three `ERL_*FLAGS` matter more than `ELIXIR_ERL_OPTIONS`
  does — they are read by `erlexec` rather than by anything Mix generates — and
  `ERL_OTP<major>_FLAGS` is a fifth of that kind, appended at run time because its
  name carries the emulator's OTP major and cannot be written into a module
  attribute. The `RELEASE_*VM_ARGS` pair matters differently again: those do not
  add a flag, they point the launcher at another project's args file entirely.

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

`mix castle.relup` takes an upgrade strategy — `auto` by default, `--hot`,
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
`restart_verdict/2` is now the whole of the verdict: `([], [])` is the all-hot
line and everything else is one message naming both kinds.

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

**One verdict per invocation, and it is printed after the relup exists.** A
restart reaches an `auto` run two ways — `auto` classified the edge as one, or an
appup named `restart_emulator` itself — and only the first is knowable before the
relup exists. So nothing is settled until after generation: the all-hot line and
the restart announcement both come out of `restart_verdict/2`. Announcing from
classification alone says every transition is hot and then reports a restart;
that shipped once, and now that such a run *succeeds* it would print both from a
successful invocation. Do not add a second announcement anywhere else.
`relup_test.exs` asserts the all-hot line is absent from every `auto` case that
ends in a restart — `refute_all_hot/1` matters more now, not less.

**And "after generation" was not far enough, which review round 4 found.** The
verdict is *returned* by `plan!/5` and printed by `generate!/7` only once
`publish_relup!/3` has come back. An announcement is a claim about a file, and
encoding, opening, writing, closing and renaming can each fail — every one of
them leaving either no relup or, by the publication contract, the older one that
was already there. Printed before publication, a run could report that every
transition was a hot upgrade and then produce no relup at all, or leave one
describing something else. `relup_test.exs` pins it by standing a *directory*
where the relup goes, which fails the rename and nothing before it, and asserting
the all-hot line is absent. Do not move the printing back into the planning
clauses.

**`--dry-run` is that same ordering, stopped one step short**
([forecastle#31](https://github.com/ausimian/forecastle/issues/31)). It is nearly
free precisely *because* the verdict already waits for the generated plan:
whatever the invocation would have done it still does, and the plan is then
encoded and dropped instead of published. Nothing about the classification is
re-derived for it, and nothing may be: a second opinion about what the relup
would have said is one that can drift from what it says.

**Say what a dry run does *per strategy*, and do not flatten it.** Review round 2
was right that "the baselines are resolved, each edge is classified and
`:systools` is asked for the hot half" describes `auto` and reads as though it
described the mode. Only baseline resolution happens under all three: `--restart`
reaches `plan_transitions/6`'s first clause, which builds the entries by hand and
neither reads an appup nor calls `:systools`. So `--restart --dry-run` validates
the two `.rel` files and nothing else, and an operator told otherwise would take
it for appup validation it never performed. A dry run is worth exactly what the
run it stands in for is worth, and saying so is the whole of the correction.

**The notice says what the run did, never what the file holds.** It read
"<path> is whatever it was before this run" until review round 3, and that is a
claim about a moment that has already passed: nothing locks or snapshots the
destination, so an ordinary run sharing the output directory — two CI jobs, a
`mix release` alongside — can publish over it while the dry run is still
generating, and the sentence would have been false as it was printed. "This run
did not write `<path>`" has nothing for a concurrent writer to falsify, because
a run that did not write is a fact about the run. The same rule the rest of this
tree already follows: a question asked in one call and answered in another is a
question about a moment that has passed.

**A successful `--hot --dry-run` is not a one-line run.** `--hot` announces
nothing of its own on success, which is why the notice has to stand on its own —
but `silent` hands `:systools`' diagnostics back to `report/1` to forward, and
those go to **standard error** through `Mix.shell().error/1` while the verdict
and the notice go to standard output through `info/1`. A `bad_vsn` from a drifted
appup tag reaches a dry run exactly as it reaches an ordinary one, which
`relup_test.exs` now pins. Do not write that the notice is the only output, and
do not invite a pipeline to parse the lines: the exit status is the machine
answer.

**Encoding is inside the dry run and publication is outside it, and that line is
the point.** `encode!/1` is the last thing that can fail about the relup
*itself*; opening, writing, closing and renaming are facts about a file, which a
mode whose whole promise is that it writes nothing cannot go and find out. So the
exit status is about **generation** — zero when the relup could have been
generated, non-zero when generation would have failed — and the notice it prints
claims only that. This is also why `--outdir` is still required to name a
directory that exists: an ordinary run would have refused it, so a dry run that
accepted it would answer a different question. The notice comes *after* the
verdict, and it has to stand on its own, because `--hot` says nothing on success
and `--hot --dry-run` is otherwise a silent exit 0.

**Do not write that the exit status is the one the ordinary run would have had.**
It was written that way once and review round 1 was right to call it: the gap is
real and one-sided. Everything that refuses before the write refuses in a dry run
too, so it never passes a plan an ordinary run would have refused — but a failure
to *publish* is invisible to it, and a directory standing where the relup goes,
an unwritable destination or a full disk each exit 0 under `--dry-run` and
non-zero without it. `relup_test.exs` pins that deliberately, with the ordinary
run of the same command as the control, so the divergence is a named boundary
rather than something found later. Do not close it by checking the destination
either: a `File.stat/1` is not a write and answers about a moment that has
passed, so it would disguise the gap rather than remove it, and writing is the
one thing this mode may not do.

**"Writes nothing" is a promise about the relup and the directory it would have
gone in, not about the run.** A dry run still resolves its baselines, and two of
the three sources write while doing it: `tar:` unpacks the artefact into
`_build/castle/baselines` and `ref:` builds the commit into the same place. Only
`rel:` costs nothing, because it names a release already on disk. That is not a
loophole to close: a baseline that cannot be resolved is a generation that would
have failed, and the only way to say so is to resolve it. State the promise in
those terms rather than as "a dry run writes nothing", which is false the moment
anybody points one at a `tar:` spec.

What *is* pinned is the output directory — `relup_test.exs` lists it rather than
merely reading the relup, because publication renames a staging file over the
destination and a run that got as far as staging would leave a `.tmp` behind even
where the relup survived. Measured by hand as well, once, and recorded here
rather than turned into a suite: a manifest of the whole fixture workspace —
path, size and mtime to the nanosecond — is identical before and after a `rel:`
dry run, and moves for the same command without the switch. The suite pins the
output directory, which is the part a regression would break; the manifest is
what says nothing *else* moved either.

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

## The relup generated during assembly

`Forecastle.generate_relup/1` generates this release's relup from its
`upgrade_from:` option and writes it into the version path.
[forecastle#28](https://github.com/ausimian/forecastle/issues/28), and
`design/upgrade-tooling.md` §1.2 and §D5 in ausimian/castle, are where the
reasoning started.

**What it removes is a double build that was mandatory and undocumented.**
Generating a relup needs the target's `<name>.rel` and its `lib/<app>-<vsn>/ebin`
directories, for the appup lookups — and those exist only *after* `:assemble`,
while `stage_relup/1` reads the project-root `relup` *before* it. So a relup
destined for a release meant `mix release`, then `mix castle.relup`, then
`mix release --overwrite`, with a mutable file in the project root as the hand-off
between two builds. Most of what defends that seam — `verify_relup!/2`'s version
refusal, the staging-and-rename in `publish_relup!/3`, the `on_exit` cleanup in
`Forecastle.ReleaseCase` — is correct and is paying for something that did not
need to exist.

**Between `post_assemble` and `:tar`, and that is the only interval that works.**
Earlier and there is no `.rel` and no populated `lib/`; later and `:tar` has
already packed the version directory without it. `:tar` packs `releases/<vsn>`
wholesale (`Mix.Tasks.Release.make_tar/1`), so a relup written into the version
path during the same run is in the artefact with no copying afterwards — which is
the whole difference between this and the staged project-root one.

**Within that interval it goes last, immediately before `:tar`, and the
difference from "immediately after `post_assemble`" is not cosmetic.** It shipped
the other way round for one round of review, and two independent adversarial
passes found the same thing: `mix release` documents a function step between
`:assemble` and `:tar` as *the* way to customise an assembled release, so such a
step can change exactly what a relup would be generated from — an appup
rewritten, a module replaced, something copied into `lib/`. Generating before it
describes the tree as it was while `:tar` packages the tree as it became, which
is an upgrade plan for contents that never shipped: §1.1's failure again, arrived
at from a third direction. `before_tar/2` is the splice, and it is written by
hand rather than through `Enum`/`List` so that an improper tail survives for
`Mix.Release`'s own refusal to name.

Mix's `validate_steps!/1` is what makes "before `:tar`" unambiguous — at most one
`:tar`, and it must come after `:assemble`. With no `:tar` at all there is no
packaging step to precede and generation is appended; a project that packs its
own archive in a function step, which `Castle.customize/1` warns about rather
than refuses, has to place the step itself, because nothing here can tell which
of its steps does the packing.

**A caller-placed `&Forecastle.generate_relup/1` is honoured rather than
duplicated, and that is [#38](https://github.com/ausimian/forecastle/issues/38).**
The splice used to append unconditionally, so the *one* arrangement the paragraph
above prescribes — pack your own archive, place generation in front of it — was
the arrangement that got two. Not merely the summary printed twice: the spliced
one ran after the packing step, so the archive held the relup from the first run
and the version path the one from the second, and a packing step that touched the
tree on its way past made them different plans in silence — §1.1's failure again,
from a fourth direction. `place_generation/1` is the guard, and `generates_relup?/1`
is hand-written for `before_tar/2`'s reason: it walks the same possibly-improper
list, and `Enum` there would raise out of Forecastle instead of letting
`Mix.Release` refuse the list by name.

**Only a step after `:assemble` counts**, which `Mix.Release.validate_steps!/1`
does not settle — it constrains `:tar` and says nothing about function steps. The
deciding reason is that a `generate_relup/1` before `:assemble` cannot generate
anything: it reads `<name>.rel` out of `version_path`, which Mix has not written
yet, so `read_rel!/1` refuses that file by name. Counting it would skip the splice
on the strength of a step that generates nothing, trading a build that fails
loudly for one that assembles a release with no relup and says nothing. It is
also the segment `before_tar/2` already searches, and it keeps `Enum` away from
the improper tail.

**A placement after `:tar` is guarded, and it is the only placement `steps/1` has
anything to say about.** `validate_steps!/1` allows function steps on either side
of `:tar`, so `[:assemble, :tar, &Forecastle.generate_relup/1]` is a list Mix
assembles happily — and honouring it means `:tar` packing the version directory
before anything has written a relup into it, then generation writing one into the
assembled release, announcing it, and the build exiting 0 having shipped an
archive with no upgrade plan. §1.1's failure wearing a success. The first round of
adversarial review on #38 caught exactly this: the change had honoured it, and the
unit test had codified it. Splicing a *second* step before `:tar` instead is no
better — one plan in the archive, another in the version path, nothing saying
which — so it is named rather than resolved, the same call the module makes about
a hand-written `relup` beside `upgrade_from:`.

**It is named by a step rather than from `steps/1`, and the second review round is
why.** `steps/1` is handed a list; whether the placement costs anything is a fact
about the *release*. Without `upgrade_from:` generation does nothing at all —
documented, and asserted — so refusing in `steps/1` failed builds whose output had
nothing wrong with it, including one packaging a hand-written `relup`.
`Forecastle.refuse_unpackaged_relup/1` is spliced in instead and asks the release.

**It is spliced twice, and the third review round is why.** A `Mix.Release` is
the caller's to rewrite, so a single check up front passes for a release that
names nothing *yet*, and a step adding the option afterwards reaches `:tar`
with the placement never re-examined: archive packed, relup generated into the
release behind it, plan announced, exit 0. Such a build is refused twice over
now — `refuse_late_upgrade_from/1` sees the option change — but this guard is
deliberately still the first to fire, because it names the *placement*, which is
what the project can move. So one guard before `:assemble`, where
a refusal costs no build and no resolved baseline, and one immediately before
`:tar`, which is the packaging boundary and the only position sure of the options
as they finally are. Same doctrine as `refuse_hand_written_relup!/0` being called
from both `stage_baselines/1` and `generate_relup/1`: early because failing is
free there, late so the step is right on its own. The early one is *not* ahead of
every step — the caller's own pre-`:assemble` steps come first, because `steps/1`
has never inserted anything in front of those, and one of them adding the option
is exactly what the second guard covers.

Early because resolving a baseline can mean unpacking an artefact or building a
git ref, and before `:assemble` for the reason `stage_relup/1` and
`stage_baselines/1` both give: Mix does not tidy up after a step of its own that
raised, so a refusal afterwards leaves a version directory that a retry declines
to overwrite before exiting 0. The late guard pays that price deliberately — an
assembled release needing `--overwrite` is the lesser of the two, the greater
being a shipped archive announced as carrying a plan it does not carry.

**What the guards deliberately do not close is
[#40](https://github.com/ausimian/forecastle/issues/40).** A step *after* `:tar`
that sets `upgrade_from:` is past both of them and past the packing, and the
fourth review round on #38 named it. It is not about a caller-placed generation
step at all: with generation in its ordinary position and the mutating step after
`:tar`, the same build exits 0 with **no relup anywhere and nothing printed** —
the worse half, and identical on `feature/upgrade-tooling` before #38, which was
checked by running one fixture against both revisions. Closing it from `steps/1`
would mean refusing every steps list with a function step after `:tar`, which
refuses builds that have nothing to do with relups. It is closed from the other
end instead — by what `upgrade_from:` is allowed to mean once the pipeline has
started, which was a decision rather than a patch. See *A late `upgrade_from:` is
refused*.

A step *before* `:assemble` is deliberately not guarded at all: `read_rel!/1`
already refuses it by name, before `:assemble` has created anything, and a second
check would be the same decision made in two places. An after-`:tar` step has
nothing downstream that could notice it, which is why it needs something here.

`forecastle_test.exs` asserts the *ordered* steps list rather than the presence
of the step, including a case with a caller function between `:assemble` and
`:tar` and one with no `:tar`. `assembly_relup_test.exs` pins the consequence on
a real release: the fixture's `SAMPLE_STEPS=custom` mode puts
`Sample.MixProject.remove_dep_appup/1` in that position, deleting the
dependency's appup — the file `auto` consults to decide whether that
application's version change can be hot — so generation before it writes a hot
script and generation after it writes `restart_emulator`. The placement is
therefore visible *in the packaged relup*, not only in the steps list. All three
tests were checked to fail against the old splice.

The duplicate has the same shape of coverage. `forecastle_test.exs` asserts the
ordered list for a caller-placed step with and without a `:tar`, before
`:assemble`, and against an improper tail, plus the guard for a step after
`:tar` — and that a caller step after `:tar` which is *not* generation is left
alone, since this is about one capture in one position rather than about steps
after `:tar`. `refuse_unpackaged_relup/1` has its own describe block: the no-op
without `upgrade_from:`, the named refusal with it, and a malformed option
refused for what is wrong with the option rather than for where the step sits.
`assembly_relup_test.exs`
pins it on a real build through the fixture's `SAMPLE_STEPS=packing` mode, which
is the documented arrangement itself — no `:tar`, generation placed by hand, and
`Sample.MixProject.pack/1` packing the archive. **That step slims the tree before
packing it**, dropping the dependency's appup for the same reason
`remove_dep_appup/1` does, so the two generations would disagree rather than
merely repeat: the archived and on-disk relups are asserted *identical*, and
against the old splice they were a hot script and a `restart_emulator` one. The
verdict count is asserted alongside, so two generations that happened to agree
would still fail. Checked to fail against the old splice. A third mode,
`SAMPLE_STEPS=after-tar`, is the guard on a real build, and it is assembled
*twice*: once naming a baseline, where the run fails in the first step with no
release directory and — the assertion that matters — no archive for a pipeline to
pick up and ship; and once naming none, where the same steps list assembles
cleanly and the tarball is asserted to hold no relup. The pair is what says the
guard asks the release rather than the list. A fourth mode,
`SAMPLE_STEPS=after-tar-late`, is the second guard: `Sample.MixProject.add_upgrade_from/1`
gives the release a baseline *after* the early guard has passed it, and the
assertion is that the build fails with no tarball — the release directory does
exist there, because that refusal necessarily lands after `:assemble`.

Those four modes are the only places the fixture calls `Forecastle.steps/1` rather
than spelling the list out, because there the splice is the thing under test. It
is why the fixture's release definition is a `fn -> … end` thunk: Mix loads
`mix.exs` before the path dependency on Forecastle is compiled, so capturing
`&Forecastle.pre_assemble/1` is fine but *calling* `Forecastle.steps/1` raises
`UndefinedFunctionError`. The thunk is what Castle's own documentation
prescribes, for this exact reason.

**Both callers go through `Forecastle.Relup`, and that is what the module is
for.** The task and the step ask the same question about the same two releases,
and a step that judged an edge hot while `mix castle.relup` restarted it — or
the reverse — would be worse than having only one of them. What differs is where
the target comes from, which baselines it is against and where the file goes,
which is exactly what `generate!/5` takes; everything else is there once. Same
doctrine as `Forecastle.Appup` and the same reason.

**The strategy is `auto` and there is no option for the others.** `--hot` and
`--restart` are refusals and insistences a *pipeline* makes, and a pipeline that
wants one is running a command; the release option is what a project writes once
in `mix.exs`. A second way to spell the strategy in the release definition would
have to mean the same thing as the switches, which is a vocabulary to keep in
step for no new capability.

**A baseline at the target's own version is refused, in `read_from!/2` beside
the release-name check.** `:systools` accepts such a pair and generates an entry
from the version to itself, whose script carries nothing but
`point_of_no_return`; `release_handler` selects an entry by the version it is
upgrading *from* and will not unpack a version a deployment already has, so the
entry could never be used and the build packaged it as the release's upgrade
plan without a word. The way to reach it without meaning to is a release
assembled twice into one path with `upgrade_from:` naming that path: `:assemble`
replaces the directory, so baseline and target become the same release. Refused
in the shared module rather than in the step, because the same spec typed at
`mix castle.relup` is the same mistake. Review round 4.

**Every baseline gets both directions.** `upgrade_from:` names releases this one
can be upgraded *from*, and each is passed as both the up and the down list —
`--fromto`, not `--upfrom`. A relup that cannot be rolled back is not much of an
upgrade plan, and the option gives a project no way to say "no downgrade" because
nothing has asked for one. `resolve_baselines!/1` resolves each distinct spec
once, so passing the list twice costs nothing.

### Absent, empty, and resolving to nothing

**These are three different answers, and collapsing any two of them is how this
would come to report success having done nothing.** That failure has happened in
this tree three times — an `Application.spec` list a project can override, a
regex blind to `defmodule(...)`, and a `rel:` baseline resolving to `/lib`, which
exists on Linux, so every application read as removed and the run announced full
coverage having compared nothing. So:

- **No `upgrade_from:` at all is a documented no-op.** `upgrade_from!/1` answers
  `:none` and the step returns the release untouched. A release that says nothing
  about upgrading has to assemble exactly as it did before this existed, and
  `assembly_relup_test.exs` asserts that on the baseline release it has to build
  anyway — the *absence of a file*, not the return value.
- **`upgrade_from: []` is a refusal.** It is a build asking for an upgrade plan
  and naming nothing to generate one against: a list read out of the environment,
  or filtered down to nothing by a `mix.exs` that computes it. Answering `[]` for
  this and for the absent option alike would assemble a release with no relup in
  it and say nothing, which is precisely the shape above. `upgrade_from!/1`
  returns `:none | {:baselines, [binary(), ...]}` and **has no third answer** —
  the distinction is in the return type rather than in whoever remembers to
  check.
- **Baseline resolution happens in `pre_assemble/1`, and the result is carried
  forward.** It is the largest thing this feature can fail at — a `tar:` that is
  not there, a `ref:` that does not exist or does not build — and `pre_assemble`
  is the last moment at which failing is free. `stage_baselines/1` resolves and
  stashes the spec-to-path map under `:forecastle_baselines`, dropped
  unconditionally first for the reason `stage_relup/1` drops its own key;
  `generate!/7` takes that map, or `nil` to resolve for itself, which is what
  `mix castle.relup` passes because its target is a path somebody typed and can
  be wrong. Raised in review, and the reasoning is in the next section.
- **A spec that is not a spec is refused before `:assemble`, not after it.**
  `baselines!/1` runs `Forecastle.Baseline.parse!/1` over every element, which is
  the grammar and touches no filesystem — so `""`, `"tar:"` and a prefix naming
  no source are all settled in `pre_assemble/1`. Being a non-empty list of
  binaries was not enough: left to `resolve!/2`, each of those failed *after*
  `:assemble` had created the version directory, and Mix does not tidy up after a
  step of its own that raised, so the corrected retry finds it, declines to
  overwrite it, and exits 0 having assembled nothing. Resolution deliberately
  stays where it is — that half unpacks tarballs and builds commits, and belongs
  beside the generation that needs the target.
- **A second `upgrade_from:` is a refusal, not the first one winning.**
  `Mix.Release` keeps options it does not recognise in the keyword list it was
  given, and `Keyword.merge/2` preserves duplicate keys *within* the list merged
  in — so a release definition built by joining lists, which is how this option is
  most naturally added beside others, really can carry two. `Keyword.fetch/2`
  would take the first and discard the rest silently, which is a build generating
  against baselines the project did not settle on. `mix castle.relup` refuses a
  repeated `--target` or `--outdir` for the same reason and this is the same rule.
- **A baseline that resolves to nothing fails the build, by name.** `rel:`
  touches no filesystem deliberately (see *Baselines*), so a spec pointing
  nowhere reaches `read_rel!/1`, which names the `.rel` it could not read. One
  level further in, a baseline whose library directory exists and holds no
  applications is refused by `:systools` itself: it searches, finds only the
  *target's* copy of each application and refuses on the version —
  `sample: No valid version ("0.1.0") of .app file found`. `assembly_relup_test.exs`
  asserts that exact refusal for **every** application the baseline names, not
  merely a non-zero exit, because a test content with non-zero would go on
  passing if this became some other failure or if the refusal ever reported one
  application and skipped the rest.
- **An option a step changed after `pre_assemble/1` resolved it is a refusal.**
  It is a fourth answer to "what does this release name", arrived at after the
  question was settled, and it is refused at generation and again after every
  step has run. See *A late `upgrade_from:` is refused*.
- **The target is not checked, and that is a boundary rather than a gap.** At
  this point in the steps list the target is Mix's own output, so there is
  nothing to check that `:assemble` has not already guaranteed. A hand-written
  steps list that put the step elsewhere meets `read_rel!/1` naming the file it
  could not read; `forecastle_test.exs` pins that, and pins that it happens
  *before* any baseline is resolved, since resolving one can mean unpacking a
  tarball or building a git ref.

**Both refusals are read twice, deliberately.** `pre_assemble/1` reads the option
and refuses a malformed one *before* `:assemble` has created anything, for the
reason `stage_relup/1` gives about the project-root relup: Mix does not tidy up
after a step of its own that raised, so a corrected retry without `--overwrite`
finds the version directory, declines to overwrite it, and exits 0 having
assembled nothing. `generate_relup/1` reads it again so that the step is right on
its own rather than on the assumption that its neighbour ran. One function, two
call sites — not two implementations.

### What a late failure costs, and where the line is

**Everything this feature can decide early now happens before `:assemble`**: the
option shape, the spec grammar, a repeated option, the two-plans conflict, and —
since review round 2 — baseline resolution, which is the expensive half and the
one most likely to fail. What is left in the late half is reading the target's
`.rel` and asking `:systools` for a script, and both of those *need* the
assembled release. There is no earlier point for them.

So a late failure is possible and its cost is stated rather than engineered
away: the assembled release stays on disk without a relup, and the build must be
retried with `--overwrite`. `assembly_relup_test.exs` pins that whole sequence —
a hollow baseline fails after assembly, the version directory is still there, no
relup is in it, and the same path retried with `--overwrite` and a resolvable
baseline produces both the relup and a tarball containing it.

**Two remedies were considered and refused.** Making a plain retry re-assemble is
not Forecastle's to do: `Mix.Tasks.Release` decides whether to run the steps at
all *before* any step is reached, so no step can influence it. And cleaning the
release output on a late failure would mean deleting a directory tree at a path
the user chose with `--path` and which Forecastle did not create — the same
destructive-action objection that keeps `git worktree prune` out of the baseline
resolver, for a failure mode Mix owns.

One consequence worth knowing rather than fixing, and it predates this feature: a
`mix release --overwrite` into a directory that already holds a release does not
clear it, so a relup left by an *earlier* build survives into a build that
generates none. `copy_relup/1` has always behaved that way when nothing was
staged. Removing it would mean deleting a `relup` that a caller's own step may
have written, which is the same objection again.

**A caller step that rewrites `upgrade_from:` is refused, and that reverses what
this document said before #40.** It used to read: a step that adds a baseline
leaves the staged map not answering for it, `staged_baselines/2` re-resolves
where the map does not cover every spec, and *"that is the correct branch and not
merely the safe one, because what the option says now is what the relup should be
generated from"*. That sentence was true about the branch and wrong about the
option, and #40 is where it was settled the other way. Rejecting the mutation had
been considered and refused there as protecting an optimisation at the cost of a
customisation Mix supports; what that reading missed is that the mutation does
not survive the pipeline in either shape — see *A late `upgrade_from:` is
refused*.

`staged_baselines/2` keeps its coverage check, as a guard rather than as support
for the mutation: a steps list reaching generation without `pre_assemble/1` has
no stash to index into, and Mix's carrying of unrecognised options means a
caller's step can leave something there that is not a map at all. Indexing into a
stale map instead raised a `KeyError` naming a map, which is what review round 3
found, and that is still the failure the check exists to avoid.

**This is the third appearance of one class — work that can only happen after
`:assemble` — and the answer is deliberately structural rather than another
special case: everything nameable before `:assemble` is settled there, the
irreducible remainder is listed above, and its cost is documented and tested
rather than engineered around. Do not reopen it with a fourth narrower case.**

**A project-root `relup` beside `upgrade_from:` is a refusal, not a precedence
rule.** They are two upgrade plans for one release and only one file can be in
the version path, so picking one silently discards the other and which one was
discarded is invisible in the assembled release. `refuse_hand_written_relup!/0`
names both, from `stage_baselines/1` and again from `generate_relup/1`. Note the ordering that makes this reachable: the step runs *after*
`copy_relup/1`, so if a precedence rule were ever wanted the generated one would
win by construction — which is exactly why there is a refusal instead.

**The recursion guard belongs to Castle, and this half deliberately does not read
it.** Building a `ref:` baseline runs that commit's own `mix.exs`, which sets
this option again and would ask for a baseline of a baseline;
`Forecastle.Baseline`'s `refuse_recursion!/1` refuses that on `CASTLE_BASELINE`,
and its message says `Castle.customize/1` is where the variable is read. That is
the right side for it — the recursion arrives through Castle's entry point — and
a second check here would be the same decision made in two places. A project that
sets the option directly and names a `ref:` baseline meets the resolver's own
refusal, which is loud.

### A late `upgrade_from:` is refused

**A build whose `upgrade_from:` is not the one `pre_assemble/1` resolved is
refused**, and that is [#40](https://github.com/ausimian/forecastle/issues/40).
The option is *read* at generation and the archive is packed at `:tar`, so a step
that sets it after either asks for an upgrade plan too late for one to be made,
or too late for one to be packed. Both shapes exited 0:

- generation where `steps/1` puts it and the mutating step after `:tar` — no
  relup anywhere, neither in the archive nor in the version path, and nothing
  printed; and
- generation placed after `:tar` by the project with the mutating step between
  the two — a relup on disk, `auto`'s verdict announced, and an archive carrying
  none of it. `:erl_tar.table/2` on the produced tarball listed no
  `releases/<vsn>/relup`.

**Not every refused change is one of those, and the message must not say it is.**
A caller step between `:assemble` and `:tar` runs *before* generation, so that
one used to work: `staged_baselines/2` found the stash did not cover the new spec,
re-resolved, and the archive got a relup for the baseline the step named. It is
refused too, so that `upgrade_from:` means one thing at one moment rather than
two — but the refusal cannot tell which of the three it is looking at, so it
states the invariant and stops. Adversarial review round 4 found the diagnostic
claiming a shipped archive with no plan in it for all of them; `mid-option` is
the fixture mode that pins this one, refused at generation with no tarball
written at all.

**Refuse rather than freeze or merely report, and three things decided it.**
Refusing now and supporting it later is additive while the reverse is breaking,
and `upgrade_from:` is unreleased, so nobody can be relying on rewriting it
mid-build — true now and not true again. Nothing real is lost: a step placed
before `:assemble` runs ahead of `pre_assemble/1`, since `steps/1` has never
inserted anything in front of the caller's own pre-`:assemble` steps, so a
project computing baselines from git tags or an artefact store puts the work
there and has them resolved and honoured normally. And it closes both shapes,
which neither alternative does — a rule comparing only at generation cannot see
the first, and freezing the option changes nothing there either, since generation
has already produced nothing by the time the step runs.

**Two positions, and the second is not optional.** `refuse_late_upgrade_from/1`
is called from `generate_relup/1`, where refusing is cheap and where the option
is about to be read, and spliced by `steps/1` after every other step, which is
the only point from which the first shape is visible at all. Under a rule that
refuses every difference the two are the same comparison, which is what makes
this smaller than the alternatives it replaced. It is appended to *every* list
`steps/1` splices rather than only to those where a step could still change
something: which steps run after generation is a fact about where `steps/1` puts
generation, and a rule resting on that would quietly stop being true the next
time that placement moves.

**A missing record is not innocent, and reading it as "pre-assembly never ran"
was a hole.** Adversarial review found it and a build reproduced it: a caller step
writes the option either by rewriting the keyword list it was handed, which keeps
Forecastle's keys, or by putting a fresh list in their stead —
`%Mix.Release{release | options: [upgrade_from: specs]}` — which drops them. The
second spelling names a baseline and deletes the record in one move, and a check
lenient about the absence passed such a build straight through to exit 0 with no
relup in the archive.

**But the absence is answered by asking the release, not by refusing on the
bookkeeping**, which is `refuse_unpackaged_relup/1`'s rule and it holds here for
its reason. Refusing every absence failed builds that name no baselines at all
and produce nothing wrong — a step can rebuild the options for reasons of its
own, and a release with no `upgrade_from:` has to assemble exactly as it did
before this feature existed, which is not a promise worth a private key. So a
release naming baselines with no record behind them is refused at the final step,
and one naming none is left alone. The fixture's `replaced-options` mode is that
second build, and `SAMPLE_LATE_UPGRADE_FROM_STYLE` writes the option both ways,
so the difference between the spellings is exercised rather than assumed.

**The message for that refusal describes missing evidence, and does not claim
the baselines were never resolved.** A step can replace the options carrying the
*same* specs, dropping only the record, and `pre_assemble/1` did resolve those —
so "never resolved" would be false in exactly the case the refusal is most
conservative about. Adversarial review round 5 found it saying so. The refusal
stands, because nothing at that position can tell the two apart; what changed is
that it says as much.

**One shape stays open, and it is stated rather than engineered away.** A step
that replaces the options *before* generation, dropping an `upgrade_from:` the
build had along with the record, takes the request and the evidence of it in one
move, and both checks then see a release asking for nothing.

**There is a mechanism that would close it, and it is named here rather than left
to be rediscovered.** `pre_assemble/1` could append a *closure* to
`release.steps` capturing what it resolved, which an options replacement cannot
reach: `Mix.Tasks.Release.run_steps/1` hands each function step the remaining
list and then runs whatever the returned release carries, so appending works and
the captured value is out of the caller's way. Adversarial review round 3 raised
it, and the claim it replaced — that `Mix.Release` offers no such place — was
simply wrong. It is not taken, for two reasons. `release.steps` is the caller's
to rewrite exactly as `options` is, and by the same mechanism: a step returning
`%{release | steps: release.steps ++ [mutate]}` runs `mutate` after any terminal
guard, closure or not, so the surface moves rather than closing. And a guard
existing only at runtime is invisible to `steps/1`, whose ordered output is what
`forecastle_test.exs` and Castle's `customize_test.exs` assert on precisely so a
splice cannot go wrong quietly — and `Mix.Release.validate_steps!/1` has already
run by then, so a step appended afterwards is never validated by name either.

**So the boundary is this, and it is a boundary rather than a gap.** These checks
catch a step that gets `upgrade_from:` wrong. They do not defend against a step
that dismantles the pipeline it is running in: one replacing the release options
wholesale drops Mix's own along with Forecastle's — the staged relup, the staged
appups, `:overlays`, `:quiet` — and one rewriting `release.steps` can run
anything after anything. The spelling a step is actually written with,
`Keyword.put/3` on the list it was handed, is refused properly in both
directions. **Do not reopen this with a narrower case**: three review rounds
produced three of them, each defeated by a step erasing whatever the last one
relied on, which is what says the class has no terminus inside a `Mix.Release`.

`generate_relup/1` cannot be strict about a missing record at all and goes
through `compare_upgrade_from/1` instead: it is reachable without
`pre_assemble/1` — a caller who placed it before `:assemble` — and `read_rel!/1`
already answers that by naming the file, which this module declines to decide
twice. So the two positions differ in what a missing record means and share the
comparison itself.

**`stage_baselines/1` records what it read as well as what it resolved to**,
under `:forecastle_upgrade_from`, on both branches and `:none` included. The two
answers the comparison has to tell apart are "this release named nothing and a
later step named something" and "`pre_assemble/1` never ran, so there is nothing
to compare", which a key appearing only when the option did could not
distinguish. The resolved map cannot stand in for it either: it is keyed by spec,
so it answers for a set rather than for the list the project wrote. Both keys are
dropped unconditionally first, for the reason `stage_relup/1` drops its own.

**What the second position costs is stated rather than engineered away.** A
change made after `:tar` can only be refused after `:tar`, so the archive is
already on disk when the build fails, and so is the assembled release, which a
retry has to `--overwrite`. The non-zero exit is what stops a pipeline shipping
it; deleting an artefact at a path the user chose and Forecastle did not create
is the destructive-action objection made about cleaning up after a late failure
and about `git worktree prune`. What the archive is *not* is a release announced
as carrying an upgrade plan it does not carry.

**Deferred, not rejected.** Supporting a genuinely late baseline would mean
moving generation to the last moment before packing in a way that survives caller
steps, or an explicit opt-in saying "re-read the option, I know where my packing
step is". Neither is needed for 1.0 and neither is foreclosed. **If this refusal
is later read as a considered permanent rule, that is a misreading — it is a
narrowing taken while narrowing was still free**, and the comment beside
`refuse_late_upgrade_from/1` says so as well.

`forecastle_test.exs` covers the comparison directly: an option matching the
record is a pass, and a baseline added, rewritten or taken away is a refusal —
plus a malformed one refused for what is wrong with the option rather than for
having changed, which is the call `refuse_unpackaged_relup/1` makes too. It pins
both answers to a *missing* record as well: refused at the final step when the
release names baselines, passed when it names none, and passed inside
`generate_relup/1` either way, where what is asserted is that the failure names
the target it could not read rather than the record. And it pins the ordering
inside `generate_relup/1`, since the comparison has to come before the target's
`.rel` is read and before any baseline is resolved.

`assembly_relup_test.exs` pins both shapes on real builds, through the fixture's
`SAMPLE_STEPS=late-option` and `late-option-after-tar` modes, each of them a
second time with `SAMPLE_LATE_UPGRADE_FROM_STYLE=replace` for the
options-replacing spelling, and the third shape with `mid-option` — the change
made before generation, refused with no tarball written at all, which is what
says the two after-`:tar` shapes leaving an archive behind is a property of
*where* they are refused rather than of the refusal. It pins the capability the
refusal protects with
`early-option` — the same step one position earlier, asserted on the relup *in
the archive* rather than on the exit status — and the line the strictness must
not cross with `replaced-options`, a build that rebuilds the options and asks for
no relup, which has to succeed.

One thing those assemblies establish in passing, and it is worth knowing: Mix
carries `release.options` through `:tar` and through its own steps untouched, so
the record survives to the last position. Every default-mode assembly in the
suite now ends on a step that would refuse if it did not.

**What none of it covers is a hand-written steps list that leaves the final step
out**, which keeps the exposure this closes. That is the same class as a list
that leaves `post_assemble/1` out and ships without `bin/castle`: Forecastle does
not police hand-written lists, and cannot start here. The check would have to be
unconditional to catch the first shape — the release names nothing at
`pre_assemble/1` time, which is the whole of the issue — so it would refuse every
list that predates this, including releases that never mention `upgrade_from:`.
That is the objection that made `refuse_unpackaged_relup/1` a step rather than a
refusal in `steps/1`. `Castle.customize/1`, which is how a consumer reaches any
of this, always goes through `steps/1`.

**The fixture sets the option directly and names the step functions by hand.**
`test/fixtures/sample/mix.exs` does not go through `Castle.customize/1`, so this
half is testable without Castle's API — castle#34 is a separate issue and lands
after this. It is also why the fixture's `steps/0` writes the list out rather
than calling `Forecastle.steps/1`: a splice bug would otherwise produce both
sides of the comparison. The `custom`, `packing`, `after-tar`, `after-tar-late`,
`late-option`, `late-option-after-tar`, `mid-option`, `early-option` and
`replaced-options`
modes are the
deliberate exceptions — there the splice *is* what is under test.

## Baselines

A relup needs a previous release to compare against, and `Forecastle.Baseline`
is the one place that turns the name of one into something on disk.
[forecastle#26](https://github.com/ausimian/forecastle/issues/26), and
`design/upgrade-tooling.md` §D4 in ausimian/castle, are where the reasoning
started.

**One grammar, three sources, no sniffing.** `rel:` is an assembled release,
`tar:` a shipped artefact, `ref:` a git ref. A value with no prefix is a `rel:`
path, which is the whole of the backwards compatibility story: `--fromto` and its
two siblings took a path long before they took a spec, and everything written
then still means what it meant. Direction stays on the switch name and source
stays in the value — crossing them into separate switches is a switch per
combination, and there are twelve.

**A prefix-shaped value that names no source is a mistyped spec, not a path.**
`re:v1.0.0` read as a filename fails looking for a release called `re:v1.0.0`,
which mentions neither the typo nor the fact that there is a grammar. The
pattern needs two characters before the colon, which is what keeps a Windows
drive letter out of it — Windows is unsupported here, but being unable to name
`c:/...` at all would be a poor way to say so, and `rel:` in front of anything is
the way through. `spec?/1` is the same test exposed, and is how `--target` — which
takes a path and never a spec — answers rather than resolving the typo.

**`tar:` is the recommended source and the reason is correctness.**
`release_handler` selects a relup entry by from-version *string* and never
verifies that the running code is what the relup assumed. Rebuild an old tag
today and you get today's Elixir and OTP patch releases, today's hex tarballs for
anything not fully pinned, today's compiler output; if the module set differs at
all from what is deployed, the instructions miss modules. That is §1.1's failure
arrived at from the other direction, and it is why `ref:` says on **every**
resolution — cache hit included — that what it produced was rebuilt. The claim is
about the baseline, not about the work done to get it.

**`rel:` deliberately touches no filesystem.** It hands back the path it was
given. `mix castle.relup` reads the `.rel` a moment later and says exactly what
it could not read and why, so a check in the resolver would either duplicate that
message or stand in front of it with less to say. `relup_test.exs` pins the
ordering with a run where the target *and* the baseline are both wrong: which
failure comes out is the assertion, because resolving can mean unpacking an
artefact or building a commit and neither message would otherwise show it.

**Two different baselines for one release version are refused, not chosen
between.** A relup carries one entry per from-version and `release_handler`
selects by version, so only one of a pair sharing a version could ever be used —
and which one would be whichever `:systools` happened to emit first, which is to
say whichever order the switches were written in. The specs make that easy to
reach without meaning to: one release can be named three ways, and
`tar:my_app-1.0.0.tar.gz` beside `ref:v1.0.0` is a natural thing to write while
checking that the two agree. They may not.

Identical `.rel` terms would not settle it either, so do not "improve" this into
a deduplication. A `.rel` names applications and their versions and nothing about
the code inside them, so two releases can agree on every line of it and share not
one module — which is the entire reason `tar:` is recommended over `ref:`.

What *is* collapsed first is one release reached two ways. `rel:` hands back the
path it was given, deliberately, so a release arrives under as many names as
there are ways to write it — `./rel/…` and its absolute form, and a symlinked
spelling of the same tree. `baseline_identity/1` settles that with device and
inode, which is the same file by the only definition that does not depend on how
it was reached, falling back to `Path.expand/1` where the file cannot be stat'd
(and `read_rel!/1` a moment later says why). A textual comparison was not
enough: it saw a symlinked spelling as a second baseline and refused a command
that named one release twice and meant it.

**The identity is the `.rel` file *and* the library directory, and the pair is
the point.** Keyed on the `.rel` alone, what it left was a false *dedup* rather
than a false ambiguity, and that is the worse direction: `lib_dir/1` derives the
code tree from the spelling of whichever path survived, so two release roots
sharing one `.rel` — a symlink or a hard link to the same file — while holding
different `lib/` trees collapsed into a single baseline, and *which* code tree
the relup was generated against then came down to the order the switches were
written in. That is the failure `refuse_ambiguous!/3` exists to prevent,
arriving underneath it. Raised in review and fixed; `relup_test.exs` pins it with
two roots sharing a symlinked `.rel` and holding different `lib/` trees, and the
case was checked to pass — silently generating against one of them — against the
`.rel`-only key.

The library directory is compared by inode rather than by `Path.expand/1` for
the same reason the `.rel` is: a symlinked spelling of one tree expands to two
different strings, so a textual comparison there would refuse the
one-release-reached-two-ways case that dedup exists for.

**Every cache entry is immutable, and its existence is the whole of the
question.** Nothing is built or unpacked in place: the work happens in a staging
directory and the finished thing is *renamed* into position, so an entry appears
only once it is whole. That is what makes "the directory is there" a safe answer
to "is this usable?", and what makes an interrupted run leave nothing a later run
would mistake for a hit — the same promise, and the same mechanism, as
`publish_relup!/3`.

It is also what makes concurrency a non-question. Two runs resolving the same
baseline each build their own and the first to finish wins; the loser's rename
fails with `EEXIST` and it throws its copy away, because the key names everything
that decides the contents and the two are therefore the same thing.

**The staging directory is *claimed*, not chosen.** `File.mkdir/1` is `mkdir(2)`,
which either creates the directory or reports that somebody else holds it, and
that atomicity is the mechanism: a name this run believes is unique is not
something it may act on destructively. It once cleared its candidate with
`File.rm_rf!/1` first, on the reasoning that a name carrying the OS pid and a
per-run counter could not already be taken — but two BEAMs in separate PID
namespaces (two containers over one bind-mounted `_build`) can hold the same pid,
and `System.unique_integer/1` is unique *within* a BEAM rather than between them.
The two runs then agree on a name and the second deletes the first's live
workspace. The name now carries random bytes, which makes the collision
vanishingly unlikely, and `mkdir` makes it harmless when it happens anyway.

A staging directory is removed on every path out, success or failure, so one left
behind means a run was killed outright. Clearing those in passing would be the
worktree-prune mistake again — nothing here can tell a dead workspace from a live
one — so they wait for the cache-clearing task the design defers.

An earlier revision built in place under `.compiled` / `.released` stamp files,
and it had two ways to hand back a half-built baseline: one run could clear
`rel/` while another was assembling into it, and one could write the stamp while
another was still writing artefacts beside it. Do not reintroduce a stamp — a directory that
is still being written to cannot also be the signal that it is finished.

**A cache key has to name everything that could make the contents different.**
`tar:` is keyed on a digest of the artefact's *bytes* — not its path, because a
pipeline that writes `my_app-1.0.0.tar.gz` afresh every build would otherwise be
served the first build's release for ever. `ref:` is keyed on the resolved sha
(via `^{commit}`, so an annotated tag keys on the commit rather than the tag
object) **and on the build context**: level, `MIX_ENV`, `MIX_TARGET`, the Elixir
version and the ERTS version. Each entry carries a `context.txt` recording it, so
what is in the cache can be read rather than inferred from a digest.

The environment is in the key because the child is built with the caller's
`MIX_ENV` while the cache sits beside the environments rather than inside one, so
without it a `prod` build answers a `dev` caller with a `lib` directory nothing
ever produced. The *project* is in it because an umbrella's children share one
`_build`, and therefore one baseline cache: without it `apps/a` and `apps/b`
resolving the same ref land on one entry and whichever built first answers for
both. The toolchain versions are in it for a reason specific to what a baseline
is *for*: an ordinary build cache can leave them out because Mix notices a
version change and recompiles, but nothing recompiles a hit here — the point is
to skip the build — so an Elixir upgrade would otherwise leave every cached
baseline compiled by the old one, and the relup would then be generated between
module sets from two different compilers. That is the drift `tar:` exists to
avoid, arriving through the door `ref:` came in by. `os` is the same argument for
a `_build` shared across a container boundary, which a bind mount does every day.

**Where the key stops, and why it is a boundary rather than a gap.** Three
successive review rounds found something missing from this key, and each was a
real omission — but the sequence is the point, not the individual fixes. A
`mix.exs` is arbitrary code and may read anything at all to decide what it
builds: an environment variable, a file, the clock. No key computable from here
can name that, and Mix's own build directory does not try. So the contract is
stated rather than approximated: **the key covers what Forecastle chooses
(`level`, `project`, `MIX_ENV`, `MIX_TARGET`) and what the toolchain is (Elixir,
ERTS, OS).** A project whose build depends on something outside that has two
honest options, and both beat a key that grew until it looked complete — name the
artefact with `tar:`, which is the recommended source anyway, or clear
`_build/castle/baselines`. Do not extend the key to chase the next example
without deciding that boundary has moved.

**A `tar:` artefact is copied into staging before it is unpacked**, and the
digest that keys the entry is taken of the copy. Hashing the path and then
unpacking the path is two reads of something that can change in between — and
rewriting `my_app-1.0.0.tar.gz` is exactly what a pipeline does — so artefact A
could be hashed while artefact B was unpacked and published under A's digest,
after which every request for A silently gets B. The digest of the *live* file is
still taken first, but only to answer "is this already unpacked?", where a hit is
by construction an entry unpacked from bytes with that digest; the copy is on the
miss path, which is the only path that publishes anything.

**Everything the build writes goes outside the worktree**, which is what makes
"remove the worktree, keep the artefacts" true rather than aspirational.
`MIX_BUILD_ROOT`, `MIX_DEPS_PATH` and the release's `--path` all point into the
cache directory; `MIX_BUILD_PATH` is *unset* for the child, because it names one
build directory outright and takes precedence over `MIX_BUILD_ROOT`, so one
inherited from the calling build would put the baseline's artefacts where the
caller's already are. `Forecastle.Fixture` scrubs the same variable for the same
reason. `MIX_ENV` is the calling build's rather than a hardcoded `prod`:
comparing a `prod` release against a `dev` baseline reports differences that are
the environment rather than the change.

**`MIX_TARGET` is passed, and `MIX_EXS` is cleared.** Neither is optional.
`Mix.target/0` is *process state* in the calling build — it can come from `def
cli`'s `preferred_targets` or from `Mix.target/1`, not only from the environment
— and `System.cmd/3` carries none of that across, so without passing it the child
could build for `:host` under an entry whose key claims otherwise. `MIX_EXS`
names the full path of the project file, so an absolute one inherited from the
caller would have the child load *today's* `mix.exs` while standing in a worktree
of an old commit, and publish that under the old commit's key: the baseline would
be configured by current code and nothing would say so. Those two, plus the build
paths above, are the whole set of Mix variables that change *which* project is
built or *where* its output goes; everything else describes how a build runs in
the user's environment and applies to caller and baseline alike.

**The compiled `lib` directory is found, not reconstructed.** Mix builds into
`<root>/<target_><env>`, except that `build_per_environment: false` replaces the
environment with `shared` and `:host` contributes no prefix at all — and the
first of those is the *baseline project's* configuration, which the calling
project cannot know. Since `MIX_BUILD_ROOT` belongs to one entry alone, whatever
single directory is under it is the one the build wrote. An earlier revision
joined `<env>` on by hand and returned a path that did not exist for any
non-host target.

**A separate deps path is not a tidiness measure.** Sharing the caller's `deps/`
would have `mix deps.get` in the baseline rewrite it to the *old* commit's
versions, which corrupts the caller's build. The cost is a fetch per baseline and
it is not avoidable.

**`git worktree prune` is not used, and that is deliberate.** A registration
whose directory has gone — a killed run, a deleted `_build` — does need clearing,
and `git worktree remove` cannot do it, because it validates the directory before
it will touch the record and so refuses exactly the case that needs clearing. But
prune operates on *every* worktree in the repository, and a checkout of
somebody's on a disk that is not mounted today is indistinguishable from a dead
one. A relup task has no business deregistering it. So the registrations are
walked directly — they are directories under `<git common dir>/worktrees` holding
a `gitdir` file naming the checkout — and one is removed only when its recorded
path is inside this cache **and** it is not locked. `git worktree lock` is how
somebody says "the directory is missing on purpose", which is precisely the case
a blanket prune gets wrong. `baseline_test.exs` registers an unrelated worktree,
deletes its directory, resolves a baseline, and asserts the registration survived.

The worktree itself lives inside the staging directory, so it is unique per run
by construction and two runs resolving the same ref cannot collide on it.

**Removing the worktree needs `--force` and must not raise.** `mix deps.get`
rewrites `mix.lock` wherever the old lock cannot be satisfied as written, and an
unforced remove refuses a worktree with modified tracked files. And by the time
it runs the baseline is built and usable, so a directory that will not come away
is reported and cleared rather than thrown away with the build.

**The recursion guard is a refusal, not a depth limit.** `CASTLE_BASELINE` holds
the sha being built. Building an old commit runs *its* `mix.exs`, which in a
project using Castle calls `Castle.customize/1` and may want a relup — and so a
baseline, and so another commit. There is no build in which a baseline of a
baseline is the right thing, so a run that asks for one is misconfigured. The
variable is named for Castle rather than for Forecastle because the recursion
arrives through Castle's entry point, which is where the other half will read it.

**Shallow clones are named because CI makes them constantly.** Left alone, a tag
outside the clone's slice surfaces as `git worktree add` failing on an unknown
revision, which says nothing about why. `--is-shallow-repository` decides which
of the two messages to give, and only the shallow one mentions `--unshallow`.

**Where a git command's output is a *value*, the two streams stay apart.** Git
writes advice and warnings to standard error and still exits zero — dubious
repository ownership, a deprecated configuration key, a hint about something
unrelated — so a `rev-parse` read through `stderr_to_stdout: true` hands back
those lines with the object id on the end. One did, and the warning text went on
to become part of a directory name and part of a revision to check out. `out/3`
is for a command whose output is read back; `cmd/4`, which merges, is for one
whose output is only ever quoted in a diagnostic. What comes back from
`rev-parse` is then checked against a 40- or 64-character hex pattern rather than
trusted. `baseline_test.exs` puts a `git` on `PATH` that writes a warning and
delegates, so the merge cannot come back unnoticed.

**The build runs where the project is, not where the repository starts.** `git
worktree add` checks out the whole repository, so a project in a subdirectory —
a monorepo, an umbrella one level down — has to be built at that same relative
position inside the worktree, or the child finds no `mix.exs` or builds the wrong
one. `git rev-parse --show-prefix` is git's own answer to "where am I relative to
the top level"; subtracting the top level from the working directory instead gets
it wrong wherever a symlink stands between the two, which on macOS is `/tmp`
every time. A commit where nothing is at that prefix is refused by name rather
than left to fail as a Mix error in a directory the caller never named.

**Two levels, because a coverage check needs `mix compile` and a relup needs
`mix release`,** and on a real project that is a large difference. The level
changes nothing for `rel:` and `tar:`, which name something already built. At
`:compile` a `ref:` baseline has no `.rel` and its `lib_dir` is a Mix build's —
`<app>/ebin`, with no version in the directory name — rather than a release's
`<app>-<vsn>/ebin`. `<lib_dir>/*/ebin` matches both, and that is the only thing
the struct promises about the layout.

The level is *in the key*, so the two do not share an entry and a project wanting
both pays for both. The earlier design shared one and let a release satisfy a
later compile — true of the artefacts, false of the guarantee, because the shared
entry had to be mutated in place to grow from one level to the other.

**An unpacked release's two `.rel` files are one release.** The version directory
of a release unpacked by `release_handler` holds both `<name>.rel` and
`<name>-<vsn>.rel` (see the known limitation below), so a tarball made from a
deployment rather than from a build matches the glob twice. They are
byte-identical, so duplicates that consult to the same term collapse; only a
tarball holding genuinely different releases is refused.

**`:erl_tar` mishandles members two different ways and returns `:ok` for both.**
Verified in OTP 28.3, `stdlib-7.2`. `write_extracted_element/3` sends anything it
has no clause for — a **hard link** included — to a final clause that logs
"unsupported type" and returns `not_written`; and its clauses for `char`, `block`
and `fifo` create **empty regular files**. So the list of types that survive a
round trip is shorter than the list it tolerates, and it is exactly
`regular | directory | symlink`.

The hard link is the one that turns up in practice, and a release tree is full of
identical files for `tar` to store as one. `:erl_tar.create/3` does not write
them, so an artefact Mix packaged has none; but `tar:` is meant to be the
artefact that *shipped*, which may have been rolled by GNU tar somewhere in a
pipeline, and GNU tar does. Silently that costs a `.beam` out of
`lib/<app>-<vsn>/ebin`, and a relup generated against a release missing modules is
the very failure this resolver exists to prevent, arriving through the one source
that was supposed to be beyond doubt — and a FIFO at a payload path is the same
failure with an empty file in place of the modules. So the archive's table is
read before it is unpacked and anything that would not come back as itself is
named. Refusing a device node in a release tarball costs nothing real: no release
wants one, and `rel:` names an already-unpacked tree for anyone who disagrees.

Do not widen that list back to what `:erl_tar` *accepts*. It was `regular |
directory | symlink | char | block | fifo` for one revision, on the reasoning
that the device types are "written" — they are, as empty files, which is the
whole problem.

**Which builder each test archive uses is load-bearing, and the two go opposite
ways.** The hard-link and FIFO artefacts are built by the **system `tar`**,
because `:erl_tar` cannot write those member types at all and an archive it built
would assert nothing. The colliding-members artefact is built by **`:erl_tar`**,
because `tar` given one file twice notices the repeated inode and writes the
second as a *hard link* — so the type check refuses it before the collision check
is reached. That passed on macOS and failed on Linux, which is bsdtar and GNU tar
disagreeing about when to hard-link, and it is why that archive is now assembled
from two genuinely different files named onto one destination. Every one of these
tests asserts its member really is in the archive before using it, so a builder
that quietly stops producing it fails loudly rather than passing vacuously.

**Two members landing on one path are refused too**, which is the same failure
by a different route: extraction is sequential, so which of them survives is a
property of the order rather than of the archive, and a symlink over an existing
file is refused by the filesystem outright. Names are compared after the two
transformations `:erl_tar` itself applies — a leading `/` dropped, `./` segments
collapsed — and after nothing else. Predicting its destination in general would
mean a second implementation of `make_safe_path/2` to keep in step with OTP,
which is the same reasoning that keeps the traversal check out of here entirely
(`:erl_tar` refuses `..` and absolute paths itself, with `unsafe_path` and
`unsafe_symlink`). What this does instead is refuse an archive that names one
thing twice, which no release tarball does.

**A `ref:` worktree is a sibling of the artefacts, not a parent of them.**
Staging holds `src/` and `out/`, and only `out/` is published. That is structural
rather than careful: the worktree is not *removed from* the thing that gets
renamed into the cache, it was never inside it. An earlier revision built into
staging directly and removed the worktree before publishing, which was correct
only while the removal worked — a `git worktree remove` failure fell back to an
**unchecked** `File.rm_rf/1`, so a checkout that would not delete was published
into an entry that is supposed to be immutable and finished, carrying a `src/`
and a dangling worktree pointer. The fallback now reports what actually happened
rather than what it attempted.

**`baseline_test.exs` drives `ref:` through `mix run` in a repository of its
own, and that is not incidental.** The resolver takes its repository from the
working directory and its cache from `Mix.Project`, so calling it in process
resolves against *Forecastle's own checkout* — it would add git worktrees to the
repository the suite is running in. `File.cd/1` is not an answer either: it moves
the whole OS process, and `forecastle_test.exs` and `env_script_test.exs` are
`async: true`. Do not "simplify" that suite by calling the resolver directly.

## Appup coverage

`mix castle.appup` diffs two builds of an application and reports how the
committed appup covers the modules that moved.
[forecastle#27](https://github.com/ausimian/forecastle/issues/27), and
`design/upgrade-tooling.md` §D3 and §3 in ausimian/castle, are where the
reasoning started.

**It is the primary artefact of the whole upgrade-tooling design, not a
convenience.** The `:appup` compiler never sees a second version of the
application, so it cannot tell whether the instructions it compiles are right,
and nothing downstream closes that gap: `:systools.make_relup/4` fails when an
appup has no *entry* for the from-version, and does not and cannot notice that
an entry is *incomplete*. Two modules changed, the appup mentions one, the relup
generates, the install succeeds, and the unmentioned one goes on serving calls
from the code that was loaded before. That failure is invisible to the compiler,
to `:systools`, to `--hot` and at install time, and it becomes visible on the
next restart — when the code changes underneath a system nobody was upgrading.

**The check and `auto` read appups through one module, and that is the point of
`Forecastle.Appup` existing.** `mix castle.relup`'s `auto` asks whether an appup
covers a transition at all; the check asks what the entry it finds actually does.
Both are questions about one file keyed by one from-version, and a check that
pronounced an appup adequate while `auto` restarted the same edge — or the
reverse — would be worse than no check. So the reading, the
`appup_search_for_version/2` matching and the "what does this instruction cover"
rule all live there, once, and `project_apps/0` with them, since the check
defaults to the same set of applications `auto` treats as the project's own.

**Coverage is asked per *effect*, not per mention, and getting that wrong is how
the check came to pass the worst appup it can be given.** `systools_rc` does not
treat the four module instructions alike:
`translate_dep_to_low/3` turns `update` and `load_module` into a `{load, …}`
with a `load_object_code` behind it, `translate_add_module_instrs/2` rewrites
`add_module` into a `load_module` first — and `delete_module` becomes
`{remove, …}` plus `{purge, …}` and **loads nothing**. So a changed module named
only by a `delete_module` was reported as covered, and what the upgrade would
actually do is delete working code out of a release that still has it. The
whole-application instructions split the same way in
`translate_application_instrs/3`: `add_application` adds every new module,
`remove_application` removes every old one, `restart_application` does both.

`Forecastle.Appup.effects/4` therefore answers in `:load` or `:removal`. A
changed or added module needs `:load`; a removed one needs `:removal`. Do not
collapse them back into a single "mentioned" set.

**The order instructions run in is deliberately NOT modelled, and that is the
answer to five review rounds of getting it wrong rather than a gap in the
sixth.** The class kept coming back because the model was a reimplementation of
`systools_rc`, and each round found another respect in which the two differed:

1. two sets, one loaded and one removed — could not see a load undone by a
   removal at all, because the module was in both and the subtraction cancelled
   it. `release_handler_1` implements `remove` with `code:purge/1` and
   `code:delete/1`, so the module really is gone.
2. a sequence in *source* order — wrong too. Measured on OTP 28.3:
   `[{update, dict, …, [lists]}, {remove, {lists, …}}, {update, lists, …}]` is
   accepted and translated to `[{load, lists}, {load, dict}, {remove, lists}]`.
   The dependency-connected updates are hoisted *past* the independent low-level
   `remove`, in both directions, so `lists` ends up removed where source order
   says loaded.

Modelling (2) faithfully means building `translate_dependent_instrs/4`'s digraph
— reimplementing the thing `Forecastle.Appup` exists to avoid reimplementing. So
the question is asked only where order cannot change the answer: a module with
exactly one effect has it; a module whose effects agree has it; a module whose
effects **disagree** is a `{:conflict, instructions}` that the task reports
instead of resolving. An ordinary appup names each module once, so the common case
is exact and the reported case is one an author needs to see anyway.

**Do not "improve" this by reintroducing an order.** Both directions of guessing
have now been measured wrong, and the conservative report is the whole point. The
one exception is measured, not assumed: a `restart_application` is *itself* a
removal of every old module and a load of every new one, and
`translate_application_instrs/3` emits them in that order within the single
instruction — verified to come out `remove, remove, purge, load, load` in both
directions — so where a module's only effects come from one `restart_application`
the answer is `:load`. That also retires the old rule where
`deleted_but_present/2` was asked of the removals *minus* the loads, which was a
heuristic that happened to be right for `restart_application` and blind to
everything else.

**A module defined by more than one dependency-ordered instruction is refused by
`:systools` outright, and gets its own finding.** `systools_rc` builds a digraph
of the instructions carrying `DepMods` and throws `{muldef_module, Mod}` for a
module with more than one vertex, before producing anything. Measured: an
application-level instruction counts, through its expansion to an `add_module`
per module the `.app` names — so `{restart_application, App}` beside an explicit
`{update, M, …}` for one of `App`'s own modules is refused. That is a
reasonable-looking thing to write, and asking only about coverage called every
module of it covered and exited zero. `remove_application`'s half contributes no
vertex (it expands to the low-level `remove` and `purge`), and neither does a
hand-written `load` or `remove` — which is exactly why `[{update, M, …},
{remove, {M, …}}]` is *accepted* and has to be reported as a conflict rather than
as a muldef.

**The low-level `load` and `remove` count too, and leaving them out was wrong in
both directions.** `check_op/1` accepts them in an appup — they are what the
high-level instructions translate *into* — so a `remove` undoing a covered load
was a false pass, and a removal written as one rather than as a `delete_module`
was a false gap. They are the one pair carrying their module *inside* a tuple
instead of at the second element, which is why `subject/1` exists: it also keeps
`{purge, Mods}`, `{apply, {M, F, A}}` and `{load_object_code, {Lib, Vsn, Mods}}`
out by the general rule that a second element which is not an atom names no
single module, rather than by listing them.

**"Every module of the application" is the `.app` resource's `modules` list, not
the beams in `ebin`, and it took a second review round to get that right.**
`translate_application_instrs/3` expands over `#application.modules`, which comes
from the `.app` — so `effects/4` takes the inventories as *parameters* rather than
returning an `:all` sentinel, and it takes the right one per effect and
direction: the new side's for `:load`, the old side's for `:removal`. Returning
`:all` meant a changed beam the `.app` did not name was reported as covered by a
`restart_application`, while a successful upgrade left its old copy loaded — this
task producing the exact failure it exists to catch.

`Mix.Tasks.Compile.App` fills `:modules` in with `Keyword.put_new_lazy/3`, so a
project supplying its own list in `application/0` keeps it, which is how an
ordinary build reaches the mismatch. The fixture's own `.app` is consistent,
which is precisely why the covered case could not expose it — two tests now
rewrite the inventory directly, one per effect, and both were checked to fail
against the old behaviour.

A beam the `.app` does not name is reported for *that* rather than for the appup,
because `get_lib/2` resolves object code through the same list and throws when
nothing in the release has the module — so no instruction could carry it whatever
the appup said, and the appup is not where the problem is.

One consequence of the split that is easy to get wrong, and was:

- the *notes* use `Appup.named/2`, which deliberately does **not** expand an
  application-level instruction. "You named a module that did not change" is a
  remark about what somebody wrote, and an `add_application` names no module at
  all — expanding it turned every unchanged module into a remark about a leftover
  nobody left.

The mirror finding is a gap too, and asymmetrically so: a `delete_module` naming
a module the *target* build still has is a defect, because module names are
global and it can only be this application's. A *load* naming a module this
application does not have is only a note, because `systools_rc:get_lib/2`
resolves a module against every application in the release — it may be somebody
else's, and if it is nobody's, `:systools` refuses the relup itself.

**What is a gap, and what is only reported.** Non-zero on gaps and nothing else:

- a module that changed or was added and that no instruction *loads*, or was
  removed and that no instruction *deletes*
- a module a `delete_module` names that is still in the target build
- no entry at all for the from-version — the coarse version of the same failure,
  reported here because every module that moved is then mentioned nowhere. It is
  what `:systools.make_relup/4` refuses outright, so an appup deliberately
  offering no downgrade path is reported: the same answer, arriving earlier
- an application whose modules moved while its version did not. `release_handler`
  compares versions and `:systools` consults no appup for one that did not
  change, so no instruction anywhere could carry that code, and the remedy is
  the version rather than an instruction — which is why that finding names the
  version rather than listing the modules

A module an instruction mentions that *did not* change is reported and is **not**
a gap, and that is a decision rather than an omission. It is usually a leftover
naming the wrong module — and where it is, the module that really did change is
mentioned nowhere and fails on its own account, so refusing the build twice buys
nothing. An instruction loading a module whose code is identical is inert, so
failing a pipeline for one would refuse a build for something that cannot go
wrong. A mention of a module in neither build is the same kind of note: it may
belong to another application, since `systools_rc` resolves modules against the
whole release rather than against one appup's owner.

**Which module an instruction names is exact, and `DepMods` is deliberately not
it.** Four instructions name one module — `update`, `load_module`, `add_module`,
`delete_module` — and in every arity `appup(4)` allows the module is the second
element; `systools_rc:expand_script/1` and `normalize_instrs/1` expand every
short form and leave it there. `DepMods` is the *last* element of most of those
and names modules the instruction's own module depends on, used only for
ordering: a module appearing only in somebody else's `DepMods` is never loaded,
and counting it would turn an exact question into a substring search. Same for
`{apply, {M, F, A}}`.

### Decided: coverage is the question, script validity is not

**This check answers "does the appup name everything that moved". It does not
answer "is the resulting script one `systools_rc` will accept", and that is a
boundary rather than a gap in it.**

The distinction is `design/upgrade-tooling.md` §1.1's, and the whole reason this
task exists. `:systools.make_relup/4` *does* fail on a malformed script — that
is not the failure anybody needed help with. What it cannot see, structurally, is
an **incomplete** entry: one that names some of the modules that changed and not
the rest. The relup generates, the install succeeds, and the unmentioned module
goes on serving calls from the code that was loaded before. Incompleteness is the
question here; shape validity is `:systools`' own, and it is enforced the moment a
relup is generated, which `mix castle.relup` does anyway.

**So a script `systools_rc` would refuse is out of scope, and a future finding of
that class is not a defect in this check.** Six of them were raised in review on
this branch — `bad_instruction` for a bad shape and for a nested list left after
one splice, `muldef_module`, `removed_application_present`,
`bad_op_before_point_of_no_return`, and a `modules` value that is not a list of
atoms. Each is now caught, each is measured against OTP 28.3, and they are worth
keeping: they are cheap, they are tested, and they turn a confusing failure later
into a clear one now. But they are **cases this happens to catch, not a modelled
contract**, and nothing here should be written as though the set were complete.
Do not reopen this to close "the remaining ones".

**Why not close the class by asking `systools_rc` directly.** The obvious
structural fix — call `systools_rc:translate_scripts/4` and report any
`{error, systools_rc, Reason}` — is exact by construction and cannot drift, and it
is the doctrine this module follows elsewhere for `appup_search_for_version/2`.
It was **considered and rejected.** `translate_scripts/4` needs `#application`
records, and `systools.hrl` is internal: not under `include/`, not reachable from
Elixir, so the record has to be built positionally against a 16-field layout. That
couples the gate to an OTP implementation detail and breaks it for whoever
upgrades OTP first — bought against holes that `make_relup` closes downstream
anyway, in a task that is explicitly *not* a substitute for it.

That the unmodelled cases have no natural end — `sync_nodes` shapes,
`mnesia_backup`, purge validation on the low-level forms — is the evidence that
enumeration was the wrong shape for the problem, not a list of work outstanding.
Scoping closes the class by construction, which enumerating it never could.

**An instruction is credited only once its whole shape is one `:systools`
accepts.** That is a *coverage* rule before it is a validity one, which is why it
survives the scoping above: an instruction `:systools` will not accept covers
nothing, so crediting it overstated coverage. Reading an instruction by its head
and the position of its module was wrong in two independent ways — it missed a
legal shape (the nested fragment below) and it credited an illegal one. The
second is the worse of the two:
`{restart_application, App, Anything}` is refused by
`systools_rc:check_syntax/1` as a `bad_instruction`, so the edge produces no
relup at all, yet by leading elements alone it looked like a whole-application
instruction and covered the entire inventory. The check announced that every
module that moved was covered, of an appup that cannot be used — a false *pass*.

So recognition is now positive rather than positional. `Forecastle.Appup`'s
`legal?/1` writes out every shape `expand_script/1` and `check_op/1` between them
accept, `effects/4` and `named/2` credit nothing else, and `refused/1` hands the
rest back so the task can report it — because a module reported as uncovered when
an instruction names it is confusing unless the instruction is named too.

`legal?/1` is `check_op/1` and nothing more, and that exactness is bought by
`script/2` producing the very script `check_syntax/1` would see — see the
fragment section below, which is what lets one vocabulary serve both a top-level
instruction and a fragment member with neither carrying a note about where it
came from. It is deliberately allowed to be **narrower** than `:systools`, and
the asymmetry is the whole design: too narrow costs a false gap with the
instruction printed beside it, too wide costs a false pass. Only this module's
own vocabulary is judged: `{apply, …}`, `point_of_no_return` and the rest name no
module here whatever their shape, were never credited with anything, and
`:systools` checks them anyway.

**A script element may itself be a list, `appup(4)` does not say so, and
`Forecastle.Appup.script/2` is `expand_script/1` — both of its effects, in its
order.** That function runs each element through a `case` that rewrites the short
forms into long ones and then, *if the result is a list*, appends it into the
script instead of consing it on. No clause of that `case` matches a list or
returns one, so the two branches never meet: **a list element is spliced verbatim
and everything else is expanded, and a fragment's members are never passed back
through the expansion.**

Reading only the top level of the list was mostly *noisy* — gaps reported on an
edge `:systools` would have restarted, or on a module a nested instruction loads
— but a nested `{delete_module, Mod, []}` translates to the `remove` and `purge`
pair, and missing that failed **silently**, since nothing then said the upgrade
deletes code the target still has.

**Splicing first and expanding afterwards is a different function, and the
difference is a false pass.** That was the first attempt at this and it was
wrong: a nested short form got the expansion `:systools` would not give it, so
`{load_module, Mod}` inside a fragment was credited with coverage — and a nested
`{add_application, App}` with the entire inventory — for an appup no relup can
be produced from at all. Measured against OTP 28.3 through
`translate_scripts/4`:

| script | answer |
| --- | --- |
| `[{load_module, m}]` | syntax OK (`no_such_module` later) |
| `[[{load_module, m}]]` | `{bad_instruction, {load_module, m}}` |
| `[[{update, m}]]` | `{bad_instruction, {update, m}}` |
| `[[{add_application, a}]]` | `{bad_instruction, {add_application, a}}` |
| `[[{add_application, a, permanent}]]` | syntax OK |
| `[[{add_module, m}]]`, `[[{delete_module, m}]]` | syntax OK |
| `[[[restart_emulator]]]` | `{ok, [point_of_no_return, restart_emulator]}` |
| `[[[[restart_emulator]]]]` | `{bad_instruction, [restart_emulator]}` |

The three heads refused nested are exactly the three whose short forms exist only
because the expansion rewrites them; the ones accepted are the arities
`check_op/1` has itself. So the fix is not an origin flag threaded through the
script — it is doing the two effects in the right order and letting `legal?/1` be
`check_op/1`, which every instruction in an expanded script is held to whichever
branch produced it. `effects/4`, `named/2` and `restarts_emulator?/2` do no
expanding of their own and must be given a script `script/2` handed back.

**An edge that ends by restarting the emulator is passed over in silence, and
which edges those are is `systools_rc`'s answer rather than the appup's
ordering.** Measured against OTP 28.3, `sasl-4.3`, in
`sort_emulator_restart/3`: a `restart_emulator` is filtered out wherever the
appup wrote it and appended to the end, so **its position does not matter** and a
check reading the last instruction would be wrong; a `restart_new_emulator` in a
*downgrade* script is replaced by a trailing `restart_emulator`, so that is a
one-stage restart too; and one in an *upgrade* script is hoisted before the point
of no return, with the rest of the relup running after the reboot — so coverage
still matters there, and the check says so rather than leaving the reader to meet
`mix castle.relup`'s refusal of that transition later.

**That exemption is sound but deliberately incomplete, and the distinction is
worth keeping because a review will raise it again.** `:systools` merges every
application's script for one relup edge before `sort_emulator_restart/3` runs, so
a restart in *any* application's appup restarts the whole edge. A restart named
in *this* application's own entry therefore really does restart the edge that
entry belongs to — the exemption never lets a dangerous appup through. What it
cannot see is a restart supplied by an application `--app` did not name, or one
`:systools` inserts for an ERTS change.

That was raised as a finding and **declined**, with the reasoning: there is no
release here to read a restart out of. At `:compile` level there is no `.rel` at
all, applications named in one invocation need not be in one release, and each is
checked against *its own* from-version rather than a release version — so "the
edge" is not a thing this task can know. Suppressing one application's gaps
because another's appup restarts would be a claim about a relup it never sees.
The residual error is that gaps get reported on an edge that would have
restarted, which is the conservative direction, and `mix castle.relup` is what
decides restarts properly, having both `.rel` files to do it with.

**The other form of the same boundary was raised in a later round and declined
for the same reason: an instruction is credited only to the application whose
appup it is in.** `:systools` merges every application's script before
translating it and `get_lib/2` resolves each module through the whole
application list, so an instruction in *A*'s appup naming a module of *B* really
does load it — and this reports that module as a gap under *B*, saying under *A*
only that it is in neither build of *A* and may belong to another application.

Crediting it would need what the task has not got, and in two ways rather than
one. Whether `:systools` consults *A*'s appup for this edge at all depends on
whether *A*'s own version moved, and which applications share an edge is a fact
about a release — `--app` may name two applications that are in no release
together, each is checked against its own from-version, and at `:compile` level
there is no `.rel`. Aggregating named effects across whatever `--app` happened to
list would credit an appup `:systools` may never read, which is a false pass in
place of a false gap. The reported direction is the conservative one, and the
note under *A* is what points a reader at it.

**Change detection is `:beam_lib.md5/1` *and* the persisted attributes, and a
digest of the file bytes would be useless.** `Mix.Release.strip_beam/2` rebuilds
each beam from `@additional_chunks ++ :beam_lib.significant_chunks()`, so a
release's copy of a module is different bytes from the `_build` copy of identical
code — measured on Elixir 1.19.5 / OTP 28, `AtU8 Code StrT ImpT ExpT FunT LitT
LocT Attr CInf Dbgi Docs ExCk Line Type` before and `Attr Line Type AtU8 Code
StrT ImpT ExpT FunT LitT` after. The md5 is stable across that, which is the
whole reason `--from` can name a stripped release while `--to` is an unstripped
build.

The md5 alone was not enough, and `:beam_lib`'s own documentation says why — it
covers the code, and "compilation date and other attributes are not included".
Measured: two modules differing only in an explicit `@vsn`, or in an attribute
registered with `persist: true`, have the same md5. Those attributes are loaded
with the module and readable through `module_info/1`, and an explicit `@vsn` is
exactly what hot-upgrade code carries, so reporting such a module as unchanged
was a false pass. Pairing them costs nothing: `Attr` is one of the chunks
stripping keeps, and the *decoded* attribute list is identical either side of it
while the bytes are not — asserted by the suite rather than assumed. Docs are not
in `Attr`, so a `@doc` change still moves nothing, and a module with no explicit
`@vsn` is given its own md5 as one, so for ordinary code the pair moves exactly
when the code does.

The fixture for that is a beam whose `Attr` chunk is rebuilt in place with
`:beam_lib.all_chunks/1` and `build_module/1`, and it asserts that the md5 did
*not* move — otherwise the case would pass against a check comparing md5 alone
and be asserting nothing.

A beam with **no** `Attr` chunk is read with `allow_missing_chunks` and
fingerprinted with `[]`, not refused. Measured on OTP 28.3: such a module loads,
answers calls, and reports `[]` from `module_info(attributes)`, so `[]` is what
it really has and the md5 alone is the right comparison for it. And
`:beam_lib.strip/1` — already named as a trap because it drops `Attr` — is how
one turns up in somebody's dependency, so insisting on the chunk made this a gate
that could not *answer* rather than one that said no.

**Absence is a meaningful answer here, which makes a spurious absence the worst
bug this task can have — and it had it.** An application in one build and not the
other is a *note*, since `:systools` covers that with `add_application` /
`remove_application` and neither needs an appup. So anything that makes an
application merely *look* absent exits **zero**. A mistyped `--from` did exactly
that: the library directory was not there, every application looked added, and
the run reported success having compared nothing. Nothing else was going to catch
it either — `Forecastle.Baseline` resolves a `rel:` spec without touching the
filesystem, deliberately, because the caller is what reads the release and can
say what it could not read, and this task reads no `.rel` at all.

**Being readable is not the same as being a library directory, and that
distinction cost a silent pass that only appeared on Linux.**
`Forecastle.Baseline` derives a `rel:` spec's library directory by climbing three
levels from the `.rel` path, so a nonsense spec still lands somewhere real:
`rel:/nope/x` resolves to `/lib`. On macOS that does not exist, the listing
failed, and the refusal fired. On Linux `/lib` *is* a directory — the system one
— so the listing succeeded, held none of the applications being checked, and
every one of them read as **removed** between the two builds. A removal is a
legitimate hot transition needing no appup, so the run announced that every
module that moved was covered and exited **zero** having compared nothing.

So `build/2` decides it structurally rather than by whether the path resolves: at
least one entry that is an application directory with an `ebin` in it. A build's
library directory always has one, an empty one is not a build, and a directory
that merely happens to sit at the resolved path does not. Both symptoms share one
message, because which of them a machine shows is an accident of its filesystem —
and the suite pins the readable-but-empty case with a directory it builds itself,
rather than relying on `/lib` existing, so it fails on either platform.

So the library directory is *listed* once per build and a failure to read it is a
refusal, and an application directory with no `ebin` in it is a refusal too
rather than an absence. Listing also closes a narrower form of the same bug: a
`{app,app-*}/ebin` glob is a pattern built out of a path, and
`:filelib.wildcard/1` cannot quote the part that is a path — a project under a
directory named `a{b}` matched nothing and every application looked absent again.
Do not put a glob back in either place, or in the `*.beam` listing beside them.

The third form of it is one level further in still, and it is why `app_dirs/2`
returns two lists rather than one filtered list. *Whether anything matched the
name at all* and *whether what matched is usable* are different questions, and
filtering non-directories out answered the second as though it were the first: a
regular file, or a symlink with nothing at the end of it, named for the
application left it looking absent and exited zero. An application whose matches
are **all** non-directories is now a refusal. One beside a real directory is
still passed over rather than refused — a legacy `sample-<vsn>.ez` archive
matches the prefix and is not what an upgrade would read, and refusing there
would break a layout that works.

**`--to` defaults to the current build, and that is why the task compiles — in
`current_build/0`, not in `@requirements`.** The everyday question is *what has
changed since 1.0.0, and does my appup cover it?*, which should cost a
`mix compile` and nothing more, and a check run against beams that do not
reflect the source is a wrong answer rather than a stale one. But
`@requirements` runs before `run/1` and so before anything has looked at the
arguments, which made `--from tar:a --to tar:b` — two artefacts, neither of them
this checkout — wait for a compile of a working tree it was not going to read,
and fail outright if that tree does not compile. A read-only comparison of two
things that already exist must not need the working tree to be in a fit state.
Do not put the requirement back.

**Reading a build is not synchronised against something rebuilding it, and that
was raised and declined.** The `.app` is consulted, then `ebin` is listed, then
each beam is read, then the appup: a `mix release --overwrite` into the same tree
during that window can be observed half-done, and a beam replaced at the right
moment could compare unchanged. There is nothing to fix it with. There is no lock
protocol on a `_build` tree or on a release directory to acquire, and no snapshot
to read; checking digests before and after would double the reading to narrow a
window rather than close it, and would still be a time-of-check-to-time-of-use
gap. The invariant relied on is the one every build tool relies on — nobody
rebuilds the tree you are reading while you read it — and two `mix release`
runs into one directory are already undefined without this task in the picture.

**A malformed `.app` is read leniently and deliberately, and that is not a gap
in the validation.** A missing or malformed `modules` list is read as an empty
one, where `systools_make:check_item/2` would `throw({missing_param, Item})` or
`{bad_param, Item}`, and a `vsn` spelled as a binary is accepted where
`string_p/1` would refuse it. Validating a `.app` is that function's job and it
does it when a release or relup is built; a second, weaker copy here could only
disagree with the first. What makes leaving it there safe is the direction: an
empty inventory resolves nothing, so every module that moved is reported by
`unresolvable/2` and an application-level instruction covers only what it names
by hand — strictly more findings and a non-zero exit. A malformed resource
cannot buy a clean bill of health, which is the only outcome that would matter.

**The fixture is the failure.** `Sample.Counter` and `Sample.Unmentioned` are the
same module twice — both supervised GenServers, both carrying a compile-time
`@vsn_tag`, both exporting a `code_change/3` that would set the new tag — and
`appup.exs` names only the first. Do not complete that appup. Two suites rest on
it: `appup_check_test.exs` asserts the check reports the gap, and
`upgrade_test.exs` asserts what happens when nothing does, which is
[#25](https://github.com/ausimian/forecastle/issues/25) and the pinning §3.5
asks for. Both children have to be *supervised* for the comparison to mean
anything, because `update` only reaches processes found through the supervision
tree.

**Reading the two builds lives in `Forecastle.Build`, not in the task, and every
paragraph above about absence applies there.** `mix castle.appup.gen` diffs the
same two builds and must not be able to disagree with the check about which
modules moved — a generator drafting from one diff while the gate ran on another
would produce output the gate rejects, or worse, output that passes a check
computed differently from the upgrade. So the library-directory refusals, the
`ebin` discovery, the `.app` resource reading and the fingerprint pair are one
module with two callers. The behaviours `mix castle.appup.gen` classifies on come
out of the *same* read: the attribute half of the fingerprint is already the
decoded attribute list, so `behaviours/2` is a lookup rather than a second file
read.

## Drafting an appup

`mix castle.appup.gen` takes the same arguments and the same diff and writes the
instructions for it. [forecastle#29](https://github.com/ausimian/forecastle/issues/29),
and `design/upgrade-tooling.md` §D2, §3.2, §3.3 and §3.4 in ausimian/castle, are
where the reasoning started. §D3 is the framing: the coverage check is the
primary artefact and the generator falls out of it.

**The signal is the behaviour in the beam's `Attr` chunk, and `code_change/3`
being exported is not a signal.** Elixir 1.19.5's `gen_server.ex:953` injects an
overridable `@doc false def code_change(_old, state, _extra), do: {:ok, state}`,
so **every** `use GenServer` module exports it — and the injected one cannot be
told from a hand-written one at a release's beams, since that would need the
`Docs` chunk or the abstract code and `Mix.Release.strip_beam/2` removes both.
`appup_draft_test.exs` pins this by compiling a `use GenServer` module beside a
module that hand-writes `code_change/3` and asserting the second is a
`load_module`, which is a discriminator rather than a restatement.

`{:update, M}` (soft) is the unsafe alternative, since it does not call
`code_change/3` at all and so leaves a state that did need migrating alone,
silently — and nothing here emits it.

**§3.3's "`{:advanced, []}` is safe whether or not a `code_change/3` was
written" is Elixir-specific, and that was found in review on this branch.** It
holds for `use GenServer`, whose injected identity runs. It holds for nothing
else: `code_change/3` is in `gen_server`'s and `gen_event`'s
`-optional_callbacks` and `code_change/4` in `gen_statem`'s and `gen_fsm`'s, so
`@behaviour GenServer` without `use`, and every Erlang callback module, can
declare the behaviour and export neither. Measured on OTP 28, against a
`@behaviour GenServer` module with no `code_change/3`: `sys:change_code/4`
answers `{error, {'EXIT', {undef, [{Mod, code_change, …}, …]}}}`, and
`release_handler_1:change_code/5` matches `ok = sys:change_code(…)` — so the
install fails and rolls back.

**The instruction is not changed for it, and the export is not a classification
signal.** §3.2 forbids reading `code_change/3`'s *presence*, because Elixir's
injected one makes it meaningless. *Absence* is a different fact and is
decidable, and what the alternatives would cost is what settles it: a
`load_module` swaps the code under a live process with no suspend at all, and a
soft update suspends and migrates nothing. So the draft keeps the instruction the
behaviour implies and says the module needs a `code_change` written. Do not turn
`Forecastle.Build.exports?/4` into a classifier.

**Every matched behaviour is asked for its arity, not just the one that decided
the instruction**, and that was a second review round's finding. `gen_server` and
`gen_event` call `code_change/3`; `gen_statem` and `gen_fsm` call
`code_change/4`. A module declaring two of them needs both, because which one the
running process asks for is decided at run time by that process's behaviour
module and is not visible in a beam — so a module declaring `:gen_statem` and
`GenServer` and exporting only `code_change/4` passed silently while a
`gen_server` process using it would fail. The ambiguity itself is now said too.

### One rule, because three rounds asked it the wrong way round

**Three review findings were the same mistake wearing different clothes:
reading the *destination* for a question the *running* side answers.** They were
patched one at a time until the rule was stated, and the rule is what stops a
fourth:

> The callback called on this edge is the one the **old** side's behaviour calls,
> on the **new** side's module.

`sys:change_code` is a system message handled by the behaviour the process was
*started* under, and a hot upgrade does not restart the process — so the old
code decides whether `code_change/3` or `code_change/4` is sent, and the module
just loaded is what it is invoked on. The three findings:

- classifying on the destination alone, so a behaviour-role change said nothing;
- asking the destination's arity, so `GenServer` → `:gen_statem` exporting only
  `code_change/4` passed while a still-running `gen_server` would ask for `/3`;
- asking it only in the advanced branch, so `GenServer` → `Supervisor` passed —
  `expand_script/1` turns `{update, M, supervisor}` into an advanced change too,
  so `change_code` reaches a `use Supervisor` module that exports no
  `code_change/3` at all.

**The rule covers all three and makes the silent cases decidable rather than
lucky.** An old side with no advanced behaviour requires nothing, because no
process is running that module under one — which is why plain → `GenServer` and
`Supervisor` → `GenServer` say nothing, and are right to. A `load_module` is
never asked, since it suspends nothing and calls nothing. Do not reintroduce a
union of both sides' arities: it warns falsely on exactly those two.

The role comparison is the same rule from the other end: within the advanced row,
roles compare by which arity the behaviour calls, so `GenServer` for
`:gen_server` is one role spelled two ways and says nothing, while `GenServer`
for `:gen_statem` is a different callback contract and does.

**The `Attr`-to-`Draft` boundary is pinned against real beams**, in
`appup_draft_test.exs`'s "against real beams read through Forecastle.Build". Every
other case in that suite hands `Draft` a side built by hand, so none of them
exercises the read that produces one — a regression where `Forecastle.Build`
misread `ExpT`, or associated one module's exports with another's, would pass all
of them. That case compiles two modules differing only in whether `use GenServer`
injected the callback, writes them to a real `ebin` with a real `.app`, and reads
both sides through `Build.side!/2`.

**A module whose behaviour *role* differs between the two builds is drafted for
what it becomes, and the change is said.** The classification is the destination
side, because that is the code that will be running — but the process running now
was started by the old code, and an instruction only swaps code under it. A
`GenServer` that becomes a plain module is a `load_module` under a live
`gen_server`; the reverse is an advanced update whose `code_change` runs against a
process that was never one. Neither is mechanically decidable, so both are
reported and neither is refused: refusing an entry over one module would take the
other twenty with it.

Both attribute *keys* are read, and that is measured rather than defensive: the
Erlang compiler keeps the spelling the source used, so `-behavior(gen_server).`
is stored under `behavior` and `-behaviour(...)` under `behaviour`. Elixir's
`@behaviour` always produces the British one, so the American key turns up only
in Erlang sources — which is exactly where a `gen_server` is likely to live.

A module carrying more than one behaviour is classified by the first row of the
table that matches, and **supervisor wins**. That is reachable in ordinary code —
`use GenServer` beside `@behaviour Supervisor` compiles to
`behaviour: [GenServer, Supervisor]` — and it is the conservative direction,
since a supervisor upgraded as a plain gen_server has its child specs left alone
silently. The comment beside the instruction names every behaviour found and
which one decided it, so the choice is visible rather than implied.

### The three writing cases, and why the refusal is the load-bearing one

An appup source is **arbitrary Elixir evaluated for its value** — the fixture's
own is a `case` on `SAMPLE_VSN` — so flattening one into a static term would
silently discard the logic that decides what it produces. Hence: no appup yet →
write; a pure literal → merge and print the diff; anything that computes →
**refuse to write** and print the entry to merge by hand.

`Forecastle.Appup.Source` decides that on the parsed AST, and **the predicate and
the reader are one function**. `to_term/1` either produces the term the AST
denotes or answers `:error`, and "is this a pure literal?" is exactly "did
`to_term/1` answer" — so there is no second predicate that could be wider than
the reader, which is the shape a heuristic takes. Every accepted shape is written
out and the default is `:error`, the same asymmetry `Forecastle.Appup.legal?/1`
is built on.

Two shapes are accepted that `Macro.quoted_literal?/1` refuses, and the first is
not optional: `~c"0.1.0"` parses to a `sigil_c` call, which that function answers
`false` for, so a purity test built on it alone would refuse every appup written
the way Elixir has spelled a charlist since 1.15 — including every file this task
writes, which would make the merge case work only on files nobody writes any
more. `appup_source_test.exs` pins the measurement rather than the claim. The
second is the `{:__block__, meta, [literal]}` wrapper the `:literal_encoder`
parse option produces, which is asked for because it is the only way to get the
position of a `[` out of the parser.

**`~c` and `~C` are two clauses, not one, and the difference is measured.** A
sigil's contents reach the AST *raw* — they are handed to the sigil function
unprocessed and it is the function that decides — so `~c"a\n"` and `~C"a\n"` both
arrive as the same four characters while evaluating to different charlists.
`Kernel.sigil_c/2` unescapes and `Kernel.sigil_C/2` does not, which is why the
first goes through `Macro.unescape_string/1` and the second does not. Reading
both the same way made every `~c` carrying an escape disagree with
`Code.eval_file/1` — `confirm/4` caught it, so the file was *refused* rather than
merged wrongly, which is the cross-check earning its keep rather than an argument
for not having found it.

### Where the accepted set stops, and why that is now a rule rather than a list

**Successive review rounds each found one more shape that is a literal and was
refused — a `<<…>>` bitstring, then a cons cell — and a list that grows one round
at a time is a list nobody can tell is finished.** That is the recurring class,
and it is closed by stating the rule instead of extending the list:

> **A shape is accepted when the term it denotes is determined by the AST alone.**

That admits an alias (`Module.concat/1` of its segments), the two charlist sigils
(their text, under the escape rule above), and a cons cell — `[1 | 2]` parses to a
one-element list holding a `{:|, …}`, which `Macro.quoted_literal?/1` does not
walk. It excludes two things that look like literals and are not determined by the
AST: a **struct**, whose term needs the module's compile-time defaults rather than
anything in the syntax tree, and a bitstring segment Elixir would **truncate**
(`<<256>>` denotes `<<0>>` by a rule of the language). A `::` segment is excluded
too, which is what keeps an *interpolated string* refused — that parses to a
`<<>>` as well.

**The boundary is pinned rather than described.** `appup_source_test.exs` runs a
corpus of shapes through `to_term/1` and `Macro.quoted_literal?/1` and asserts
they agree everywhere except at two named sets, each with its reason. A new
shape — or a future Elixir widening its own predicate — fails that test instead of
arriving as a review finding. It earned its keep immediately: adding the cons
clause moved cons cells from "both refuse" to "ours only", and the test said so
before the commit.

**The bytes evaluated are the bytes that were checked**, which a later round
found: `Code.eval_file/1` opens the path a second time, so a source replaced in
between would have the literal check applied to the old bytes and arbitrary code
run from the new ones — and the term comparison would refuse only *after* those
side effects, which is not the promise this module makes. That function is
defined as `eval_string(File.read!(file), [], file: file, line: 1)`, so passing
the captured source with the path as metadata is the same evaluation with the
second read taken out. Measured, including the file and line a raise reports.

The term that is merged into is therefore the evaluated term — what the `:appup`
compiler will produce from the same bytes — and it is
compared against what `to_term/1` read. A disagreement is a refusal rather than a
rewrite. The evaluation happens only after the AST has read as a literal, so
nothing arbitrary is ever run.

### A merge is a text splice, and it has to prove it landed

Re-rendering the term would take the file's comments with it, **including the
ones a previous run wrote to say what it could not decide** — which is the point
of the draft, so losing them on the next run would take the honesty out of the
tool one generation at a time. So the entry is inserted as text and nothing else
in the file is touched.

**It goes in at the front of the list, immediately after the `[`, and that is a
fact about Elixir's grammar rather than a preference.** Appending means writing
the separator on a line of its own, and a newline ends the expression before it:
a `,` opening a line after a complete element is a syntax error where a `,`
closing the previous line is not. Position cannot shadow anything, and that is
exact rather than likely — `appup_search_for_version/2` takes the first entry
that matches, a charlist from-version matches by term equality, and an entry is
only ever added to a direction where that same function found none.

The splice is then verified: the result is parsed again, read as a literal again,
and refused unless the term it denotes is exactly the merged term intended. So a
rendering bug, a splice in the wrong place, or an instruction that does not
survive `inspect/2` is a refusal with nothing written rather than an appup
claiming coverage it has not got. The same check runs on a freshly rendered file,
which is also what says the output is mergeable next time.

**Verifying the text says nothing about the file, so publishing is separate and
has two rules.** Raised in review. A first appup is created with `:exclusive`, so
a file that appeared between being read as absent and being written refuses in
the same operation that would have created it — everything drafted was drafted on
its absence. **Exclusivity is not atomicity**, which a second round found: the
open creates the inode, and a failure in the write or the close after it leaves a
partial `.exs` that the next `mix compile` cannot evaluate. So the open is done
directly rather than through `File.write/3` — only the caller of `:file.open/2`
knows it created the file and may remove it again — and where the removal fails
too, the refusal says the path may hold partial output instead of saying nothing
was written. A merge goes to a staging file *in the same directory* and is
renamed on, which is the mechanism `Forecastle.Baseline` publishes a cache entry
with and `Forecastle.Relup` a relup: `File.write/2` truncates before it writes, so
a failure part way through would leave the source neither what it was nor what it
was going to be. The mode is carried across, because the rename replaces the
inode. Before the rename the bytes are compared against what was read, which
turns "an edit between planning and writing was discarded" into a refusal — that
**narrows the window rather than closing it**, and there is no closing it, but
unlike the read-a-build-while-it-rebuilds case this module declines, this one
*writes*, and the check costs one read of a file whose expected contents it
already holds.

### Nothing ends without saying so

Every way a run can end without writing an instruction is either a refusal or a
named no-op, and the exit status is derived from that. **Refused and non-zero:**
an application in one build and not the other (`:systools` covers that with
`add_application` / `remove_application`, which no appup entry describes); one
whose version did not move; a build of the application with no beams in it, where
every module of the other side would read as added or removed and the entry
drafted from it would load or delete the whole application; an appup that
computes; one that is not an appup; and one whose merged form does not read back.
**Named and zero:** nothing moved while the version did, which writes an entry
with an empty script and a comment saying an empty script is the instruction that
nothing has to be loaded rather than an omission; and an appup that already has
an entry for this from-version in both directions, which is never rewritten.

The absent-application case is the one place this deliberately **diverges** from
`mix castle.appup`, which reports the same state as a note and exits zero. A
check has an answer for it and a generator that was asked to write something has
not.

### Boundaries

- **A drafted `update`, `load_module` or `add_module` naming a module the new
  side's `.app` does not list is still drafted, and carries the reason it cannot
  work.** `systools_rc:get_lib/2` resolves object code through
  `#application.modules`, so such an instruction is a `{no_such_module, Mod}` and
  the whole relup fails. Leaving it out instead would produce an appup that
  *builds* a relup and leaves the module running its old code — the §1.1 failure
  this tooling exists to catch — so the loud direction is the right one, and the
  comment says the fix is the `modules` list rather than the instruction. A
  `delete_module` gets no such note: it translates to a `remove` and a `purge`
  and resolves nothing.
- **The version tag of a file this writes is a literal**, so it names the version
  it was generated for and does not follow the application's. The generated
  header says so. A merge leaves an existing tag alone: updating it is a third
  kind of edit on a file the task was asked to add one entry to, and
  `mix castle.appup` already reports a `bad_vsn` mismatch as the note
  `:systools` makes of it.
- **A `:appup` key naming a file that does not exist is a compilation error, and
  it is in the way of the default `--to`.** `Mix.Tasks.Compile.Appup` refuses a
  configured-but-missing source deliberately and the default `--to` compiles, so
  the first appup for a project that has already set the key needs an explicit
  `--to`. Leaving the key unset until there is a file to name is the other way
  round it, and is what the report tells a project with no key to do afterwards.
- **An application that is neither this project nor an umbrella child is written
  to `rel/appups/<app>-<from>-<to>.exs`**, which `Forecastle.Appup.Dep` owns; see
  *Appups for applications this project does not own*. Umbrella children are
  reached through `Mix.Project.in_project/3`, because the `:appup` key is in the
  child's own `mix.exs` and there is no other way to ask; there is no umbrella
  fixture here, so that path is exercised by no test.

## Appups for applications this project does not own

`rel/appups/<app>-<from>-<to>.exs` is where a project puts an appup for a
dependency, and `Forecastle.Appup.Dep` is what reads it in `pre_assemble/1` and
places it at `lib/<app>-<vsn>/ebin/<app>.appup` in `post_assemble/1`.
[forecastle#30](https://github.com/ausimian/forecastle/issues/30), and
`design/upgrade-tooling.md` §5.5 in ausimian/castle, are where the reasoning
started.

**The consuming half already existed, which is the whole reason this is small.**
`Forecastle.Relup`'s `appup_gap/4` reads the *target release's* copy of a
dependency's appup and honours an entry matching this from-version whoever wrote
it, precisely because such an entry *is* an instruction for this transition. What
was missing was a project-owned place to put one.

**Decided: `mix castle.appup.gen --app <dep>` writes there rather than printing,
and the argument is in what the refusal it replaced actually said.** That refusal
was "a dependency has no source here to write" — an observation about a missing
destination, not a policy about dependencies. `rel/appups` is that destination,
so the premise is gone. Consistency then argues the same way round: for an owned
application the task writes, and printing for a dependency would leave the merge
case dead and a copy-this-out-of-your-terminal workflow beside the good one. D2
is satisfied identically — the output is source a person reviews and commits,
nothing generates an appup during assembly, and assembly places a file somebody
wrote. Do not turn it back into a print.

**The filename is read against the release rather than parsed, and that is a rule
rather than a convenience.** A version may contain a `-` (`1.7.0-rc.2`), so
splitting `<app>-<from>-<to>` on dashes is a guess. Both ends are already known:
for every application `A` the release carries at version `V`, the name is matched
by anchoring `"A-"` at the front and `"-V"` at the back, and what is left is the
from-version. Exact whatever either version contains. A name matching no
application at that application's version is the **stale** case and is refused —
that is the acceptance criterion, and the message names the version the release
actually carries.

**Never into `deps/`.** `deps/` and `_build`'s copy of a dependency are shared by
every release built from the tree, and by other projects where the build cache is
shared. Nothing here writes outside `Mix.Release.path`.

**Every refusal that *can* be made before `:assemble` is**, for the reason
`stage_relup/1` gives at length: a raise afterwards leaves the version directory
behind, and the corrected retry then declines to overwrite it and exits 0 having
assembled nothing. `stage_dep_appups/1` reads and checks; `place_dep_appups/1`
only writes bytes that were already checked, which is also why the bytes are
produced early — these files are arbitrary Elixir evaluated for their value, so a
second read is not necessarily a second read of what was checked.

**Two refusals cannot be, and saying otherwise was a review finding rather than
a rounding error.** Both are in `write!/2`, both cost a build, and both need
`mix release --overwrite` on the retry:

- an application named by a source that has no `lib/<app>-<vsn>/ebin` in the
  assembled release. Reachable rather than theoretical: `Mix.Release.copy_app/2`
  copies nothing for an OTP application when the release brings no ERTS of its
  own, since the deployment then takes those from the host.
- anything at the destination that is not the copy Mix made of the build's own
  appup — see the interposed-appup paragraph below.

`README.md` and `RELEASE.md` name both, and must go on naming both: a refusal
whose cost is a rebuild is worth documenting as one.

**Two files for one application are merged, in the order the names sort**, since
a release upgradeable from more than one baseline needs an entry per baseline and
a release has one appup per application to hold them. That order is stated rather
than incidental, because `appup_search_for_version/2` takes the *first* entry
that matches.

**Two entries that can both be *selected* for one version are refused, and
asking that as "two equal keys" was a false pass found in review.** A binary key
is a **regular expression** to `appup_search_for_version/2`, so a broad regex in
an earlier-sorting source and a literal in a later one both answer for the same
version without being equal terms — and the filename sort would have decided
which instructions ran. So the question is asked with the function that selects,
one entry at a time, at the versions the sources themselves name: the
from-version in each file name, and every entry key that is a concrete version.
That is decidable. Two regexes overlapping *only* at a version no source names is
what is left, and it stays stated rather than modelled — "can these two regexes
match one string" is not decidable here, and a guess is worse than a named edge.

**An appup the application ships for itself is merged into, not written over,
and that too was a review finding.** A dependency carrying an appup for its own
1.9 → 2.0 lost it the moment a project supplied one for 1.0 → 2.0, because the
file was written whole — so a transition the dependency *did* support silently
became a restart, which is this tree's own failure mode arriving through the
feature built to remove it. It is read from the build directory Mix copies the
application's `ebin` from, so an unreadable one is still refused before
`:assemble`. The project's entries go first and are therefore the ones selected;
every shipped entry that shadows is *named* rather than dropped, because
supplying an appup for a transition a dependency already covers is how a project
corrects one that is wrong — the only remedy short of forking it — and the whole
requirement is that it not be silent. Everything the dependency shipped is still
in the placed file, behind the project's entries: one rule, with no second rule
about which shipped entries survive.

**Which shipped entries are shadowed is asked at the probes, not of the shipped
keys, and asking it the other way round was a hole a later round found.**
Iterating the shipped entries and keeping only the ones whose key is a concrete
version skipped a shipped *regular expression* — so a project source named for
0.1.0 placed in front of a shipped `0\.1\..*` overrode it in silence. That is a
concrete collision at a version a source names, not the undecidable case.

**Two entries *within* the shipped appup that can both be selected for one
version are deliberately not refused.** The collision refusal is about the order
the *project's* sources are concatenated in — decided by a filename sort, which is
this module's doing rather than something an author wrote — so it refuses rather
than choose. Inside one file the order is that file's author's,
`appup_search_for_version/2` resolves it by first match, and that is what every
release carrying that dependency already does; the project's entries going first
cannot change how the rest of the list resolves. Refusing would fail a build over
a file the project does not own, which built yesterday, because the project
supplied an appup for some other transition.

**The probe set for those notes includes the shipped appup's own concrete
versions, and a round after that found why.** The project's probes are the
from-versions its file names claim plus its own concrete keys — so a project
entry keyed on a broad regular expression (a source may hold entries beyond the
version its name claims) shadowed a shipped literal for some *other* version,
which never became a probe. Both halves are covered now, whichever side is the
pattern. Those versions are deliberately **not** added to what
`refuse_collision!/5` is asked with: that refusal is about two project entries
competing, and a project entry winning over a shipped one is allowed — announced,
which is what these probes are for.

**What is at the destination has to be the copy Mix made of what was merged, and
anything else is a refusal.** `:assemble` copies the applications and *then*
copies the release's overlays over them, so a
`rel/overlays/lib/<app>-<vsn>/ebin/<app>.appup`, or any step Mix runs in between,
installs upgrade instructions after everything here was read. Reconciling them
instead would mean doing the collision refusals after `:assemble` and modelling
where an overlay came from; refusing says what happened and leaves the choice to
the author. The bytes read in `pre_assemble/1` are carried through and compared,
which also closes the two-reads window in `shipped!/2`: a file that changed
between its read and its consult cannot match at the destination either.
`Forecastle.ReleaseCase` clears `rel/overlays` for the same reason it clears
`rel/appups`.

**It is asked of the link rather than of what the link points at, and a later
round found that too.** `File.cp_r!/2` copies a symlink *as a symlink* and
`copy_overlays/1` calls it that way, so an overlay can leave one at the
destination — and reading through it answered about something else entirely. A
dangling one read as `:enoent` and passed for "no appup here"; one pointing at
the dependency's *build* appup read back exactly the staged bytes and passed for
"Mix copied it", after which the write would have followed it and put this
project's instructions into the shared build. `File.lstat/1` decides, and
anything that is not a regular file is refused. The write then goes to a staging
name in the same directory, created exclusively, and is renamed on — `rename/2`
replaces the *link* rather than following it, so the check and the write answer
about the same name, and a truncating write cannot leave a partial appup in a
release.

**`:enoent` from `File.ls/1` on `rel/appups` is two states, and reading it as one
was the same mistake one directory out.** That call follows a directory symlink,
so `rel/appups -> ../shared/appups` with the target missing answers exactly as an
absent directory does — and a project that *has* appups would have assembled a
release with none of them and nothing said. `File.lstat/1` tells the two apart.

**Coverage is a question about the *set* of sources, not about the one file the
generator would write, and asking it of the file alone was a later finding.** A
dependency's appups are one file per transition and the release merges every file
naming the application into one appup, so a sibling keyed on a regular expression
can already select this from-version — and a second entry for it is one
`Forecastle.Appup.Dep` refuses from the next build onwards. `mix castle.appup.gen`
would have reported success and left a tree that no longer assembles, which is
the disagreement between what writes an appup and what reads it that this pair of
tasks exists not to have. It asks with `appup_search_for_version/2` over each
sibling's own term, which is what the assembly step asks with. Both directions
covered is a named no-op; one direction is a **refusal**, because a file that is
not there is written in both directions or not at all. A sibling that *computes*
is a refusal too: this task does not evaluate a source it has not read as a
literal, so what that file covers is not knowable from here, and assembly — which
does evaluate it — is where the collision would land.

**The set includes the destination, for coverage *and* for multiplicity, and
three rounds on the PR found three ways of asking that missed one.** Asking only
the siblings refused a case where the file being written covers one direction and
a sibling covers the other — a release that assembles perfectly well. Reducing the
covered directions to a *set* before counting them turned two siblings competing
for one direction into a reported no-op. And leaving the destination's own entries
out of the count did the same for a destination competing with a sibling. Both of
the latter are trees `Forecastle.Appup.Dep` already refuses, reported here as
success and, worse, written into.

So `selecting/3` yields one pair **per entry** rather than one per direction that
has any, `refuse_collision!/2` is asked of every entry in the set — this file
included, which also catches one file holding two — and only then is coverage
reduced to `mine ++ theirs` per direction. A merge into an existing literal needs
no refusal of its own after that: it adds exactly the directions nothing answers
for.

**A source in the set has to be tagged with the version the transition goes to,
and reading its entries without asking was the fifth round of the same
disagreement.** `Forecastle.Appup.Dep` refuses a tag that is not the version the
release carries, so a `dep-1.0.0-2.0.0.exs` tagged 1.9.0 makes every build fail —
while the generator read its entries, called the transition covered and exited
zero. It is refused for a sibling as much as for the destination, and *ignoring*
a mistagged sibling would be worse than either: the run would draft an entry
beside it, and fixing the tag afterwards would produce exactly the collision the
set-wide rule exists to refuse. A file misnamed altogether is a different case
and is left to the build — it names no transition, so it is not in this
application's set at all.

**Which names belong to the set is asked of `Forecastle.Appup.Dep.from_version/3`
rather than re-derived, and re-deriving it was the fourth round of the same
disagreement.** A copy that only checked the two ends took `<app>--<vsn>.exs` for
a source — the release refuses that name, because the rule requires a from-version
*between* the ends — so the generator counted as coverage a file the next build
rejects. That is why `from_version/3` is exported at all: one reading of these
names, in the module that owns the directory.

**The generator's file name is built out of two version strings, so it is checked
to be a name.** `Forecastle.Build` refuses a version that is not valid UTF-8 or
that carries control characters — those reach a report and a terminal — and says
nothing about path separators, which reach nothing anywhere else and reach the
filesystem here: a `.app` naming its version `2.0/x/../../../../config/runtime`
made `mix castle.appup.gen` create and write `config/runtime.exs`. Checked on the
parent **as written**, not on the parent it expands to — a version carrying
`x/../1.0` normalises back to a path directly under the directory and passed the
expanded check, while getting there created the intermediate directory inside it
and left the file under a basename naming no application. The parent as written
is the directory exactly when the name carries no separator, which is the whole
of what a file name in a directory means. `bin/castle` refuses a path separator
in a version one layer out, for the same reason.

**Not checked: whether the generated name is ambiguous in the target release.**
`<app>-<from>-<to>.exs` can read as two applications only where one application's
name ends in `-` plus something that is the other's version — `foo-bar` at 2.0
beside `foo` at 2.0 — and `Dep.named!/2` refuses that by name, showing both
readings. Asking it here would mean an inventory of every application in the
`--to` build and its version, machinery nothing else needs, to move a loud and
exact build failure slightly earlier. That is the line for this whole class: a
disagreement that ends in *silence* or in a file written to the wrong place is
this task's to prevent; one that ends in the build naming the file and both
readings is the build's to report.

**A file covering only one direction is deliberately not refused.** An appup with
an upgrade entry and no downgrade is a legitimate thing to write, `auto`
classifies each direction on its own, and the restart it makes of the other is
announced there.

**Dotfiles are ignored and everything else must be a `.exs` file.** A misspelled
extension is the case worth refusing — passing it over quietly leaves somebody
with an appup they wrote, a build that succeeded and a restart nobody can account
for — while `.DS_Store` and `.gitkeep` belong to the filesystem and the editor.

**The directory is a fixed path rather than `:rel_templates_path`.** That option
belongs to one release, and `mix castle.appup.gen` has no release to read it
from. Two answers to "where do the dependency appups live" that could disagree is
one more than a writer and a reader of the same directory can have, and the half
that disagreed would write a file no build ever reads.

**One boundary that is stated rather than closed:** `mix castle.appup --app <dep>`
reads the appup out of the build `--to` names, and a project-supplied one is only
ever in an assembled release — so checking one means pointing `--to` at a `rel:`
or `tar:` baseline. The generated file's own header says so.

## The upgrade harness

`Forecastle.Deployment` and `Forecastle.UpgradeCase` are what a downstream
project points at its own release. They started as `test/support/deployment.ex`
and the private setup of the two e2e suites; they are in `lib` now, which is the
whole of the change — `package/0` ships `lib`, Castle takes Forecastle as
`runtime: false`, and a build-time dependency is compiled and on the code path
wherever the consuming project's own tests run. Nothing enters a release.

**It is a case template rather than a `mix castle.upgrade.test`, and that is
settled** — `design/upgrade-tooling.md` D6 in ausimian/castle. A task would have
to hardcode what "the upgrade worked" means, and only the project knows: a
counter for one, an open socket or an in-flight job for another. Nothing in
either module asserts that anything worked, and nothing new may.

Three decisions in it are worth not relitigating:

- **A deployment is a copy, never the resolved baseline.** `tar:` and `ref:`
  resolve into `_build/castle/baselines`, whose entries are immutable and read by
  every later resolution of the same spec. Starting a release writes
  `releases/RELEASES` into the tree, unpacking one puts another release beside it
  and installing rewrites `start_erl.data` — so a deployment run in place would
  leave the cache holding a booted, half-upgraded release with nothing to say so.
  `deploy!/3` refuses a destination that overlaps the release for the same
  reason it copies: it empties the destination first, and an overlapping one is
  `File.rm_rf!/1` on what is about to be copied.
- **The preflight is about the shape of the spec, and it is not decoration.**
  The release root is three directories above the `.rel`, `Forecastle.Baseline`
  deliberately reads no filesystem for a `rel:` spec, and `Path.expand/2`
  climbing past the top of an absolute path stops at `/` rather than failing —
  so `rel:/tmp/missing` resolved to a root of `/`, and the next two lines were
  `File.rm_rf!/1` on the destination and a recursive copy of the whole
  filesystem into it. So the `.rel` has to be a file and it has to sit under
  `releases/<vsn>/`, both asked before anything is deleted. For the same reason
  containment is compared on path *segments*: a textual prefix test reads
  `<root>-next` as being inside `<root>`, and misses a root of `/` entirely,
  since `/` with a separator appended is `//`.
- **There is no one call that installs both kinds of transition.** A hot upgrade
  never leaves its operating system process, so `install_supervised/3` would
  wait for an exit that is not coming; a restart transition reboots and nothing
  in the release starts it again, so `castle!/3` alone would hang. Which one a
  transition is comes from the relup, and the caller knows because the caller
  asked for it. `install_supervised/3` watches the install task *while* it
  waits for the process, because `bin/castle install` cannot be answered until
  the release has been started again — which is that function's own next line —
  so an install that has already exited has exited about a failure and is
  holding the only account of it. Waiting on the process alone spent the whole
  timeout and then reported that a process was still running.
- **Relup generation is not part of the harness.** `mix castle.relup` and
  `upgrade_from:` are already public, so a project has both without this, and
  `test/support` keeps `make_relup!/3` because what it wraps is the *fixture* —
  `SAMPLE_VSN`, a build root per version, the workspace the relup is left in.

The environment scrub has one home now, `Forecastle.Deployment.scrubbed_env/1`,
and `Forecastle.Fixture` reads it from there. Two copies of that list is how the
two drift, and what drifting costs is a `-heart` reaching a release the fragment
then adds another to — a hang, printing nothing.

**`MIX_ENV` is in that list, and its being there is a deliberate change from
what these suites used to do.** `Forecastle.Fixture` set `MIX_ENV=prod` on every
command, launcher invocations included, because one function served both the
builds and the runs; a deployment taking the variable from the caller instead
inherited `test`, measured on the generated launcher. Neither is what a deployed
release sees, which is nothing at all — there is no Mix. Nothing Mix or
Forecastle writes reads the variable, so what it changes is whatever the
*project's* `config/runtime.exs` makes of it, and that file is the one place a
project routinely shares between a Mix run and a release. So it is unset rather
than restored to `prod`, and the e2e suites run without it.

`Forecastle.DownstreamUpgradeTest` is the check on the acceptance criterion
rather than a restatement of it: everything it does below the build is shipped
API, and one of its cases asserts that both modules really are compiled into the
fixture's dependency build, which is a genuine consumer's. The hot and restart
suites are the other half — they were rewritten onto the harness rather than left
duplicating it, and the diff of their test bodies is nine lines, every one of
them `deploy` becoming `deploy.root`.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/forecastle.ex` | Release step hooks (the whole of the build-time logic) |
| `lib/forecastle/baseline.ex` | The baseline resolver — `rel:`, `tar:` and `ref:` specs, and the cache under `_build/castle/baselines` |
| `lib/forecastle/appup.ex` | Reading appups and asking them what `systools` asks: the from-version matching, what an instruction covers, and which applications the project owns the appups for |
| `lib/forecastle/appup/draft.ex` | The decision table — behaviours out of the beam's `Attr` chunk — and the comments that go beside each drafted instruction |
| `lib/forecastle/appup/source.ex` | Reading and rewriting an appup *source* file: whether its AST is a pure literal, and splicing a from-version entry into one that is |
| `lib/forecastle/appup/dep.ex` | The appups a project supplies for applications it does not own: the `rel/appups` directory, reading a name against the versions the release carries, and placing the result into the assembled release |
| `lib/forecastle/build.ex` | Reading one build of an application and diffing two of them: the library-directory refusals, the `ebin` discovery, the `.app` resource, and the module fingerprints. Shared by the check and the generator |
| `lib/forecastle/relup.ex` | Generating a relup: resolving baselines, classifying each transition, the three strategies, the announcement and the atomic publication. Shared by the task and the assembly step |
| `lib/forecastle/deployment.ex` | A release tree on disk, and everything an upgrade test does to one: laying a baseline spec out, starting it, `bin/castle`, `rpc`, the environment scrub, and standing in for the supervisor a restart transition needs |
| `lib/forecastle/upgrade_case.ex` | `Forecastle.UpgradeCase` — the case template a project uses, the scratch directory it deploys into, and where the whole recipe is written down |
| `lib/mix/tasks/compile/appup.ex` | `:appup` compiler — evaluates the file named by the `:appup` project key and writes `<app>.appup` into `ebin` |
| `lib/mix/tasks/castle.appup.ex` | `mix castle.appup` — the read-only coverage check. Non-zero when a module that moved is mentioned nowhere |
| `lib/mix/tasks/castle.appup.gen.ex` | `mix castle.appup.gen` — drafts the entry for a transition and writes or merges it into the appup source |
| `lib/mix/tasks/castle.relup.ex` | `mix castle.relup` — the command line over `Forecastle.Relup`: argument handling, `--target`, `--outdir`, `--dry-run` and the strategy switches |
| `priv/castle.sh.eex` | EEx template for `bin/castle`, the release management CLI |
| `priv/env.sh.eex` | EEx template for the fragment appended to the release's `env.sh` |
| `priv/start.sh.eex` | EEx template for `bin/start`, the inert program heart is handed |
| `test/fixtures/sample` | A real application, assembled by the test suite into a real release. Its appup is deliberately incomplete — see *Appup coverage* |
| `test/fixtures/sample/dep` | An application the relup never mentions, whose version moves with the sample's unless `SAMPLE_DEP_VSN` pins it, and which ships no appup of its own when `SAMPLE_DEP_APPUP=none` |
| `test/support` | The workspace the fixture is built in, the case template for tests that assemble it, and `mix castle.relup` between two of them. Everything here knows the sample by name, which is why none of it is in `lib` |

## Working on this project

- Run `mix precommit` before committing. It is the single validation gate —
  `compile --warnings-as-errors`, `deps.unlock --unused`, `format`,
  `credo --strict`, `test --include e2e`. Do not run the individual checks
  piecemeal.
- **`mix precommit` green does not mean CI green, and the gap is structural
  rather than bad luck.** `mix.exs` allows `~> 1.18` and the CI matrix runs
  1.18, 1.19 and 1.20, while `mix precommit` runs whatever Elixir is on the
  developer's path — so a warning that exists on 1.20 alone is invisible to
  precommit and turns up only once the matrix has run. Two concrete instances so
  far: `File.stream!/3` with modes before the byte count, deprecated in 1.20,
  which merged on #26 and was only found later; and a `defp` fallback clause
  that 1.20's set-theoretic inference proves dead, which failed every 1.20 cell.
  When touching code near either, compile against the top of the supported range
  before pushing:
  `mise x elixir@1.20.3-otp-28 -- mix compile --warnings-as-errors --force`.

  This note used to say that the matrix cells run a plain `mix test` and so
  catch no warning at all. They do not: every cell of the `test` job runs
  `mix compile --warnings-as-errors` before its `mix test --include e2e`, and
  has since the workflow was added. The remedy above is unchanged — what a
  1.20 cell catches, it catches after a push rather than before one.
- **CI failing on one OS and not the other is a signal, not flakiness.** Two
  instances now: bsdtar and GNU tar disagree about hard links, and `/lib` is a
  real directory on Linux and absent on macOS — which is what let a nonsense
  `rel:` spec resolve to something readable and pass the coverage check. When a
  cell splits by platform, find what differs about the filesystem or the tool
  before touching the assertion.
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
| `test/forecastle/relup_test.exs` | `mix castle.relup` as a command, against three assembled releases: argument handling, exit status, all three upgrade strategies, and `--dry-run` against an ordinary run of the same command |
| `test/forecastle/assembly_relup_test.exs` | The relup a single `mix release` produces from `upgrade_from:` — in the version path and in the tarball — what the option does when it names nothing, and what happens when a step of the project's changes it after the build has started |
| `test/forecastle/baseline_test.exs` | The baseline grammar and all three sources. `tar:` against a release-shaped tree built in the test; `ref:` against a throwaway git repository holding a Mix project of its own |
| `test/forecastle/appup_check_test.exs` | `mix castle.appup` as a command, against two assembled releases: what it reports, what it passes over, and the exit status |
| `test/forecastle/appup_draft_test.exs` | The decision table, against module attribute lists built in the test — plus the two rows that are measured rather than stated: `code_change/3` against real compiled modules, and the American `-behavior` spelling against real Erlang |
| `test/forecastle/appup_source_test.exs` | The line between an appup that states a term and one that computes it, against real files in a scratch directory, and what a merge does to the file it merges into |
| `test/forecastle/appup_gen_test.exs` | `mix castle.appup.gen` as a command, against two assembled releases: the three writing cases, everything it refuses, what it writes for a dependency, and `mix castle.appup` run over the output |
| `test/forecastle/dep_appup_test.exs` | `rel/appups` through real assemblies: the same transition built with a project-supplied appup and without, everything the assembly step refuses, and the merge of two sources for one application |
| `test/forecastle/deployment_test.exs` | The shipped harness without a running system: laying a baseline out, the modes it preserves, the destinations it refuses, what it leaves the cache holding, and the environment scrub |
| `test/forecastle/upgrade_case_test.exs` | `use Forecastle.UpgradeCase` on its own, which is how a project takes it and which every other suite here pairs with `Forecastle.ReleaseCase`: the alias, the timeout, and the scratch directory it names |
| `test/forecastle/upgrade_test.exs` | Booting a release and hot-upgrading it, including the code path of an application the relup does not load and the module the appup does not mention, tagged `:e2e` |
| `test/forecastle/restart_upgrade_test.exs` | The same shape through an emulator restart: the OS pid changes, an uncommitted release rolls back when killed, and a commit makes it what an ordinary start boots. Tagged `:e2e` |
| `test/forecastle/downstream_upgrade_test.exs` | The upgrade test a project outside this repository writes, written that way: `upgrade_from:`, a `tar:` deployment and nothing but shipped API below the build. Tagged `:e2e` |

The `:e2e` suite is excluded by default and included by `mix precommit`. Run it
on its own with `mix test --include e2e`. It needs no epmd daemon: the fixture
configures distribution without one.

`restart_upgrade_test.exs` is the hot suite's opposite where it counts —
`refute provisional.os_pid == booted.os_pid` against the hot suite's
`assert installed.os_pid == booted.os_pid` — and it has one thing no other suite
does: **it is the supervisor.** Nothing in the release restarts it after
`init:reboot()`, deliberately, so `Forecastle.Deployment.install_supervised/3`
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

That first start also inherits `ELIXIR_ERL_OPTIONS` with a **tab-separated**
`-heart` in it, which no e2e start used to set at all: the fixture scrubs the
variable, so every boot here had the fragment *assigning* it rather than finding
one, and the case where it has to recognise an inherited flag was covered only by
a unit test asserting the exact string `-heart`. Two `-heart` flags hang the boot,
so the suite failing to start is the regression. The value carries
`-env CASTLE_TAB_PROBE tabbed` behind the tab so that the node answering with
`"tabbed"` says the tabs were field separators, and
`:init.get_argument(heart) == {ok, [[]]}` says the emulator got one flag.

**Which is why `Forecastle.Deployment.start!/2` puts a deadline on the launcher.**
That regression does not fail, it *hangs*, and it hangs inside `daemon` rather
than after it: `env.sh` runs the preboot VM synchronously on a first start and
that VM inherits the same options, so the whole suite stops there.
`System.cmd/3` has no deadline and `setup_all` has no ExUnit timeout, so the
deadline is the only thing turning it into a named failure. Measured by putting
the old guard back — the run had to be killed. Do not remove it as
belt-and-braces.

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
