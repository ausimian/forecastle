### Added

- `bin/castle`, a release management CLI, is now installed alongside the
  standard launcher. It provides `releases`, `unpack`, `install`, `commit` and
  `remove`, and delegates to the running system through the standard launcher.
- `bin/castle commit` may now be given no version, in which case it commits
  whichever release is currently running.

### Changed

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

### Fixed

- `mix forecastle.relup` failed with `:systools is not available` in projects
  that do not themselves depend on `:sasl`, because Elixir prunes unused OTP
  applications from the build's code path.
- The `RELEASES` file was created relative to the working directory, so
  starting a release from anywhere other than its root left the system unable
  to manage its own releases.
- The `GitHub` link in the Hex package metadata pointed at the Castle
  repository rather than Forecastle's.
