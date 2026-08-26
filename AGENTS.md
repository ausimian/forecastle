# Forecastle

Build-time support for hot-code upgrades in Elixir releases. Forecastle is the
build-time half of a pair: [Castle](https://github.com/ausimian/castle) is the
runtime half. Consumers depend on Castle, which pulls Forecastle in as a
build-time dependency — Forecastle is not intended to be taken directly.

## What it does

`Forecastle.steps/1` wraps a Mix release's `:steps` list, injecting three hooks
around `:assemble`:

- **`pre_assemble/1`** — checks and stages any `relup`, refuses a project-root
  `relup` and an `upgrade_from:` option together, and adds a `:preboot` boot
  script that starts `:sasl`, `:compiler`, `:elixir` and `:castle`.
- **`post_assemble/1`** — writes `bin/castle` and `bin/start`, appends the Castle
  hook to the generated `env.sh`, and copies the `.rel` file and any staged
  `relup` into the release.
- **`generate_relup/1`** — generates this release's relup from its
  `upgrade_from:` option and writes it into the version path. Immediately before
  `:tar`, *after* any function step the project put between `:assemble` and
  `:tar`; see *The relup generated during assembly*.

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
verdict is *returned* by `plan!/5` and printed by `generate!/6` only once
`write_relup!/2` has come back. An announcement is a claim about a file, and
encoding, opening, writing, closing and renaming can each fail — every one of
them leaving either no relup or, by the publication contract, the older one that
was already there. Printed before publication, a run could report that every
transition was a hot upgrade and then produce no relup at all, or leave one
describing something else. `relup_test.exs` pins it by standing a *directory*
where the relup goes, which fails the rename and nothing before it, and asserting
the all-hot line is absent. Do not move the printing back into the planning
clauses.

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

That mode is also the one place the fixture calls `Forecastle.steps/1` rather
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
  `generate!/6` takes that map, or `nil` to resolve for itself, which is what
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

**A caller step that rewrites `upgrade_from:` resolves late, and that is the
boundary rather than a defect.** `Mix.Release` is a caller's to rewrite, and
`generate_relup/1` re-reads the option rather than trusting what `pre_assemble/1`
saw — so a step that adds a baseline leaves the staged map not answering for it.
`staged_baselines/2` is what makes that safe: the map is used only where it
covers *every* spec the step is about to generate from, and anything else
re-resolves. That is the correct branch and not merely the safe one, because what
the option says now is what the relup should be generated from; indexing into the
stale map instead raised a `KeyError` naming a map, which is what review round 3
found. Rejecting the mutation outright was the alternative and was refused: it
would refuse a customisation Mix supports in order to protect an optimisation.

What such a build cannot have is early resolution of a baseline nobody had
mentioned by `pre_assemble/1`. It is resolved late and a failure there is retried
with `--overwrite`, exactly as the `:systools` half is. **This is the third
appearance of one class — work that can only happen after `:assemble` — and the
answer is deliberately structural rather than another special case: everything
nameable before `:assemble` is settled there, the irreducible remainder is listed
above, and its cost is documented and tested rather than engineered around. Do
not reopen it with a fourth narrower case.**

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

**The fixture sets the option directly and names the step functions by hand.**
`test/fixtures/sample/mix.exs` does not go through `Castle.customize/1`, so this
half is testable without Castle's API — castle#34 is a separate issue and lands
after this. It is also why the fixture's `steps/0` writes the list out rather
than calling `Forecastle.steps/1`: a splice bug would otherwise produce both
sides of the comparison.

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

**The arity is the *old* side's and the export is the *new* side's**, which a
later round found. `sys:change_code` is handled by the behaviour the process was
*started* under, so the old code decides whether `code_change/3` or
`code_change/4` is called and the newly loaded module is what it is called on. A
module going from `GenServer` to `:gen_statem` is therefore asked for both, and
the role comparison distinguishes them: within the advanced row, roles are
compared by which arity the behaviour calls, so `GenServer` for `:gen_server` is
the same role spelled two ways and says nothing while `GenServer` for
`:gen_statem` is a different callback contract and does.

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

**A `<<…>>` bitstring needs its own clause too**, which Codex raised on the PR.
`Extra` is an arbitrary term, so `{:advanced, <<1, 2>>}` is an ordinary thing for
an appup to carry, and it parses to a `{:<<>>, …}` rather than to a plain binary —
so without a clause the whole file read as computed and the documented merge case
failed on a literal. Only whole literal bytes are taken. A `::` segment falls
through, which is what keeps an *interpolated string* refused since that parses
to a `<<>>` as well; and an integer outside `0..255` falls through rather than
having Elixir's truncation rule reproduced by hand. Both are narrower than
`Macro.quoted_literal?/1`, which is the direction this is allowed to be wrong in.

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
- **An application that is neither this project nor an umbrella child has no
  source here to write.** Its entry is printed. Umbrella children are reached
  through `Mix.Project.in_project/3`, because the `:appup` key is in the child's
  own `mix.exs` and there is no other way to ask; there is no umbrella fixture
  here, so that path is exercised by no test.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/forecastle.ex` | Release step hooks (the whole of the build-time logic) |
| `lib/forecastle/baseline.ex` | The baseline resolver — `rel:`, `tar:` and `ref:` specs, and the cache under `_build/castle/baselines` |
| `lib/forecastle/appup.ex` | Reading appups and asking them what `systools` asks: the from-version matching, what an instruction covers, and which applications the project owns the appups for |
| `lib/forecastle/appup/draft.ex` | The decision table — behaviours out of the beam's `Attr` chunk — and the comments that go beside each drafted instruction |
| `lib/forecastle/appup/source.ex` | Reading and rewriting an appup *source* file: whether its AST is a pure literal, and splicing a from-version entry into one that is |
| `lib/forecastle/build.ex` | Reading one build of an application and diffing two of them: the library-directory refusals, the `ebin` discovery, the `.app` resource, and the module fingerprints. Shared by the check and the generator |
| `lib/forecastle/relup.ex` | Generating a relup: resolving baselines, classifying each transition, the three strategies, the announcement and the atomic publication. Shared by the task and the assembly step |
| `lib/mix/tasks/compile/appup.ex` | `:appup` compiler — evaluates the file named by the `:appup` project key and writes `<app>.appup` into `ebin` |
| `lib/mix/tasks/castle.appup.ex` | `mix castle.appup` — the read-only coverage check. Non-zero when a module that moved is mentioned nowhere |
| `lib/mix/tasks/castle.appup.gen.ex` | `mix castle.appup.gen` — drafts the entry for a transition and writes or merges it into the appup source |
| `lib/mix/tasks/castle.relup.ex` | `mix castle.relup` — the command line over `Forecastle.Relup`: argument handling, `--target`, `--outdir` and the strategy switches |
| `priv/castle.sh.eex` | EEx template for `bin/castle`, the release management CLI |
| `priv/env.sh.eex` | EEx template for the fragment appended to the release's `env.sh` |
| `priv/start.sh.eex` | EEx template for `bin/start`, the inert program heart is handed |
| `test/fixtures/sample` | A real application, assembled by the test suite into a real release. Its appup is deliberately incomplete — see *Appup coverage* |
| `test/fixtures/sample/dep` | An application the relup never mentions, whose version moves with the sample's unless `SAMPLE_DEP_VSN` pins it |
| `test/support` | The workspace the fixture is built in, the case template for tests that build it, and the helpers that drive one once it is built |

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
| `test/forecastle/relup_test.exs` | `mix castle.relup` as a command, against three assembled releases: argument handling, exit status, and all three upgrade strategies |
| `test/forecastle/assembly_relup_test.exs` | The relup a single `mix release` produces from `upgrade_from:` — in the version path and in the tarball — and what the option does when it names nothing |
| `test/forecastle/baseline_test.exs` | The baseline grammar and all three sources. `tar:` against a release-shaped tree built in the test; `ref:` against a throwaway git repository holding a Mix project of its own |
| `test/forecastle/appup_check_test.exs` | `mix castle.appup` as a command, against two assembled releases: what it reports, what it passes over, and the exit status |
| `test/forecastle/appup_draft_test.exs` | The decision table, against module attribute lists built in the test — plus the two rows that are measured rather than stated: `code_change/3` against real compiled modules, and the American `-behavior` spelling against real Erlang |
| `test/forecastle/appup_source_test.exs` | The line between an appup that states a term and one that computes it, against real files in a scratch directory, and what a merge does to the file it merges into |
| `test/forecastle/appup_gen_test.exs` | `mix castle.appup.gen` as a command, against two assembled releases: the three writing cases, everything it refuses, and `mix castle.appup` run over the output |
| `test/forecastle/upgrade_test.exs` | Booting a release and hot-upgrading it, including the code path of an application the relup does not load and the module the appup does not mention, tagged `:e2e` |
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
