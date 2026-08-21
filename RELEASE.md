### Added

- `bin/castle`, a release management CLI, is now installed alongside the
  standard launcher. It provides `releases`, `unpack`, `install`, `commit` and
  `remove`, and delegates to the running system through the standard launcher.
- `bin/castle commit` may now be given no version, in which case it commits
  whichever release is currently running. It exits non-zero if there was no
  such release, so that automation can tell nothing was committed.
- A test suite. It assembles a real release from a fixture application and, in
  the `:e2e` suite, boots it and performs a hot upgrade.

### Changed

- Assembling a release that includes Windows executables now warns that it
  will not boot. Configuration is expanded at boot by the `env.sh`
  integration, which has no `env.bat` counterpart. This has always been the
  case; it was previously silent.
- **Breaking:** the `:appup` compiler now fails the build when the `:appup`
  project key names a file that does not exist, rather than warning and
  carrying on. The project asked for an appup and cannot have one, and the
  alternative is a release whose missing upgrade instructions only surface
  later — in `:systools.make_relup/4`, or during the upgrade itself. Its
  messages also reach the shell now: diagnostics returned by a compiler are
  for editors to display inline, and nothing prints them on the command line.
- **Breaking:** the standard Mix launcher, `bin/<release>`, is no longer
  replaced. It keeps everything Mix gives it — cookie handling, distribution,
  `eval`/`rpc`/`remote`, daemon mode, version selection — and stays current with
  Elixir's own launcher. The release management commands that Forecastle used
  to graft onto it have moved to `bin/castle`; `bin/<release> unpack`,
  `install`, `commit`, `remove` and `releases` are now `bin/castle unpack` and
  so on.
- The Castle boot integration is installed by extending the release's `env.sh`
  rather than by replacing the launcher. An `env.sh` supplied through
  `rel/env.sh.eex` is preserved and runs first.
- Raised the minimum Elixir requirement to 1.18.

### Security

- `bin/castle` built its RPC expression by interpolating the version
  argument into Elixir source, so a version such as `1.2.3));System.stop(1)#`
  closed the sigil and ran arbitrary code on the node with the release
  cookie's authority. `bin/castle` now refuses the characters that can end
  the sigil, escape within it, or start an interpolation, along with the
  path separator. Everything else is passed through, since Mix does not
  constrain a release version. The same sink existed in the launcher
  Forecastle used to generate.

### Fixed

- `mix forecastle.relup` failed with `:systools is not available` in projects
  that do not themselves depend on `:sasl`, because Elixir prunes unused OTP
  applications from the build's code path.
- Runtime configuration could not read the standard release variables.
  The launcher sources `env.sh`, and so runs the preboot VM that expands
  configuration, before it assigns `RELEASE_COOKIE`, `RELEASE_NODE`,
  `RELEASE_TMP` and the rest, leaving them unset for `runtime.exs`. The
  integration now applies the launcher's own defaults first.
- `bin/castle` looked for the launcher at `bin/$RELEASE_NAME`. `RELEASE_NAME`
  names the node, not the executable, so setting it sent the CLI looking for
  a launcher that does not exist. It is now passed through to the launcher
  and the executable is the one named at build time.
- The `RELEASES` file was created relative to the working directory, so
  starting a release from anywhere other than its root left the system unable
  to manage its own releases.
- The `GitHub` link in the Hex package metadata pointed at the Castle
  repository rather than Forecastle's.
- The `:appup` compiler left `<app>.appup` behind in `ebin` once the project
  stopped asking for one, whether because the source file was deleted or
  because the `:appup` key was removed. It only worked out where the output
  went on its way to writing it, so neither of those cases could remove
  anything. An incremental build — which is what a CI cache produces —
  therefore went on packaging upgrade instructions from an earlier version of
  the application, and `release_handler` applied that obsolete plan during a
  hot upgrade. The stale output is now deleted instead. Leaving the `:appup`
  key unset is a supported way to turn an appup off for an environment: the
  earlier output is removed, and beyond saying so once, nothing is reported.
  Removal needs the compiler to stay in `:compilers` — dropping it from the
  list stops it running at all, as it would any Mix compiler.
- The `:appup` project key is resolved relative to the project file, as the
  README has always said it is, rather than to whatever the working directory
  happens to be. That is what makes "the source is missing" a trustworthy
  verdict, now that it deletes the output and fails the build.
- The `:appup` compiler returned a bare diagnostic where `Mix.Task.Compiler`
  expects a list of them, so Mix discarded it and reported that the compiler
  had misbehaved instead of saying what was wrong. It also ignored the result
  of writing the appup, and so reported success when the write had failed.

### Upgrading an existing deployment

OTP's `release_handler` extracts release tarballs with `keep_old_files`, so a
hot upgrade never replaces files that already exist at the top level. Upgrading
a deployment that was built by an earlier Forecastle therefore leaves its old
`bin/<release>` in place: the upgrade succeeds and `bin/castle` appears, since
that file is new, but the old launcher and its release management commands
remain until they are replaced out of band.

Replace the contents of `bin` from the new release when migrating, or the
deployment keeps running the launcher Forecastle used to generate - including
the version argument handling fixed in this release.

This applies to `bin/castle` too: once installed, later changes to it will not
reach an existing deployment through a hot upgrade. That is the same property
Mix's own `bin/<release>` has always had.

### Known limitations

- Castle prints `release_handler` failures and returns normally, so a failed
  `bin/castle unpack`/`install`/`commit`/`remove` still exits 0. Automation
  cannot yet distinguish a failed release operation from a successful one.
  Tracked in [castle#15](https://github.com/ausimian/castle/issues/15).
- Configuration is expanded into the version directory's `sys.config`, so
  concurrent `start`/`daemon`/`eval` invocations with differing environments can
  race on it. Fixing this needs Castle to accept a destination path, also
  tracked in [castle#15](https://github.com/ausimian/castle/issues/15).
- Windows releases are not supported; see above.
