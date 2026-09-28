# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- %% CHANGELOG_ENTRIES %% -->

## 1.0.0 - 2026-09-28

Forecastle 1.0 stops intercepting runtime configuration and stops replacing the
Mix launcher. Release management moves to a separate `bin/castle`, relups can be
generated during `mix release`, and new tasks check and draft appups. It
requires Castle 1.x and Elixir 1.18 or later; an older Castle cannot install a
release built by this Forecastle. Read *Upgrading an existing deployment* below
before upgrading: the security fix in this release does not reach an existing
deployment through a hot upgrade.

### Added

- `bin/castle`, a release management CLI installed alongside the standard
  launcher, with `releases`, `upgradable`, `unpack`, `install`, `commit` and
  `remove`.
  - `upgradable` reports whether the node can be upgraded, and exits non-zero
    with the reason when it cannot.
  - `commit` with no version commits the release awaiting commit, and exits
    non-zero if there is none.
  - `install` confirms that the installed version is running before it reports
    success, waiting across an emulator restart. `CASTLE_INSTALL_TIMEOUT`
    (default 300 seconds) bounds the wait. A wrong cookie or a node that is down
    looks the same as a restart in progress, so `install` waits out the timeout
    before failing. Interrupting `install` stops the wait, not the upgrade.
    `install` refuses a `RELEASE_TMP` that is world-writable and not sticky.
    ([forecastle#13](https://github.com/ausimian/forecastle/issues/13))
- One-stage `restart_emulator` upgrades under systemd, Docker, Kubernetes or
  runit. The release starts OTP `heart` configured to do nothing, because
  `release_handler` needs it to prepare a restart. After the restart the node
  boots the installed version provisionally, until it is committed.
  ([forecastle#10](https://github.com/ausimian/forecastle/issues/10),
  [castle#14](https://github.com/ausimian/castle/issues/14))
- Upgrade strategies for `mix castle.relup`. `auto`, the default, keeps a
  transition hot unless the ERTS changes or a dependency changes version without
  a matching appup. `--hot` fails rather than restart. `--restart` makes every
  transition an emulator restart.
  ([forecastle#4](https://github.com/ausimian/forecastle/issues/4))
- Baseline specs for `mix castle.relup`: `rel:` an assembled release, `tar:` a
  shipped tarball, and `ref:` a git ref built in a worktree. A bare path means
  `rel:`. Resolved `tar:` and `ref:` baselines are cached under
  `_build/castle/baselines`. Prefer `tar:`, because a rebuilt baseline may differ
  from the release that was deployed.
  ([forecastle#26](https://github.com/ausimian/forecastle/issues/26))
- `mix castle.relup --dry-run`, which reports whether a relup could be generated,
  and which transitions would restart, without writing it.
  ([forecastle#31](https://github.com/ausimian/forecastle/issues/31))
- `mix castle.appup`, which fails when a module changed between two builds and no
  appup instruction mentions it.
  ([forecastle#27](https://github.com/ausimian/forecastle/issues/27))
- `mix castle.appup.gen`, which drafts missing appup entries for review.
  ([forecastle#29](https://github.com/ausimian/forecastle/issues/29))
- Appups for dependencies, supplied under `rel/appups` and placed into the
  assembled release, never into `deps/`.
  ([forecastle#30](https://github.com/ausimian/forecastle/issues/30))
- Relup generation during assembly. An `upgrade_from:` release option names the
  baselines, and one `mix release` produces a tarball containing the relup.
  ([forecastle#28](https://github.com/ausimian/forecastle/issues/28),
  [forecastle#40](https://github.com/ausimian/forecastle/issues/40))
- `Forecastle.UpgradeCase` and `Forecastle.Deployment`, a harness for testing
  upgrades of a project's own release.
  ([forecastle#32](https://github.com/ausimian/forecastle/issues/32))

### Changed

- **Breaking:** `mix forecastle.relup` is now `mix castle.relup`. There is no
  compatibility alias, so rename the task in build pipelines. `mix compile.appup`
  is unchanged.
  ([forecastle#24](https://github.com/ausimian/forecastle/issues/24))
- **Breaking:** the standard Mix launcher, `bin/<release>`, is no longer
  replaced. The release management commands move from `bin/<release>` to
  `bin/castle`. Castle's integration is appended to `env.sh`, after any
  `rel/env.sh.eex` the project supplies.
  ([forecastle#3](https://github.com/ausimian/forecastle/issues/3))
- **Breaking:** Forecastle no longer intercepts runtime configuration. Mix
  configures the release as it would without Forecastle, `sys.config` is no
  longer renamed to `build.config`, and Castle resolves the target's
  configuration when it installs. This requires Castle 1.x.
  ([forecastle#6](https://github.com/ausimian/forecastle/issues/6),
  [castle#13](https://github.com/ausimian/castle/issues/13))
- **Breaking:** the `:appup` compiler fails the build when the `:appup` key names
  a missing file. Set the key to `nil` to turn an appup off, for example
  `appup: if(Mix.env() == :prod, do: "appup.exs")`.
- Starts no longer run a preboot VM to expand configuration. Only the first
  start of a deployment runs one, to create `releases/RELEASES`; if it cannot,
  the start warns and continues, but the node cannot be upgraded.
- `bin/castle unpack` and `install` refuse a node that started without an
  accepted `RELEASES` file, because `release_handler` would upgrade it
  incompletely. Restart the node to recover. If the file exists but cannot be
  read, fix or remove it first.
- `mix castle.relup` with no strategy switch is `auto`, and two cases now
  generate differently. An ERTS change becomes a one-stage `restart_emulator`
  rather than the unsupported two-stage `restart_new_emulator`. An emulator
  restart requested by an appup is announced if it is `restart_emulator` and
  refused if it is `restart_new_emulator`.
- A failed `mix castle.relup` writes nothing, and a relup is published
  atomically.
- `mix castle.relup` requires at least one of `--fromto`, `--upfrom` or
  `--downto`.
- Windows releases now boot, but have no `bin/castle` and so cannot be upgraded.
  Assembly warns about this.
- The minimum supported Elixir version is 1.18.

### Security

- The launcher generated by Forecastle 0.1.x built its RPC expressions by
  interpolating the version argument into Elixir source, so a version such as
  `1.2.3));System.stop(1)#` ran arbitrary code on the node with the release
  cookie's authority. `bin/castle` refuses versions containing sigil, escape or
  interpolation characters, path separators or control characters, and shows
  rejected values percent-encoded so they cannot inject lines into its output.
  An existing deployment keeps the old launcher until its `bin` directory is
  replaced; see *Upgrading an existing deployment*.

### Fixed

- `mix castle.relup` failed in projects that do not depend on `:sasl`, because
  Elixir prunes unused OTP applications from the code path.
- `mix castle.relup` exited 0 when `:systools` could not generate a relup, so a
  build could go on to package a stale one. It now fails, and passes `:systools`
  warnings on.
  ([forecastle#7](https://github.com/ausimian/forecastle/issues/7))
- `mix castle.relup --outdir` was ignored, and the relup always went to the
  current directory.
  ([forecastle#7](https://github.com/ausimian/forecastle/issues/7))
- `mix castle.relup` ignored unrecognised arguments and raised `KeyError` without
  `--target`. Both are now errors, as is a repeated `--target` or `--outdir`.
- `mix castle.relup` refuses a baseline with the same version as the target,
  which produced an entry `release_handler` can never use.
- Assembly packaged any `relup` in the project root without checking it. The
  relup's target version and structure are now checked before assembly begins.
- A `:runtime_config_path` other than `config/runtime.exs` was ignored, and config
  providers declared with a non-keyword argument received a rewritten one. Mix
  now handles both.
  ([forecastle#6](https://github.com/ausimian/forecastle/issues/6))
- Concurrent `start`, `daemon` and `eval` invocations no longer overwrite each
  other's `sys.config`.
- `releases/RELEASES` was created relative to the working directory, so a release
  started from anywhere but its root could not manage its own releases. Such a
  node could then upgrade incompletely, leaving applications running from the
  superseded release's directory.
- The `:appup` compiler left a stale `<app>.appup` in `ebin` after its source or
  the `:appup` key was removed, so incremental builds packaged obsolete upgrade
  instructions.
  ([forecastle#8](https://github.com/ausimian/forecastle/issues/8))
- The `:appup` key is resolved relative to the project file, not the working
  directory.
- Mix discarded the `:appup` compiler's diagnostics, and the compiler reported a
  failed write as success.
- An appup containing non-ASCII characters failed to write, or was written in a
  form `:systools` cannot read. It is now encoded as UTF-8.
- The Hex package's GitHub link pointed at the Castle repository.

### Upgrading an existing deployment

- A hot upgrade from a release built by Forecastle 0.1.x keeps the old
  `bin/<release>`, because `release_handler` does not overwrite existing
  top-level files. `bin/castle` appears, but the old launcher and its release
  management commands remain, including the vulnerability fixed above. Replace
  the contents of `bin` from the new release when migrating. Later changes to
  `bin/castle` do not reach a deployment through a hot upgrade either.
- The first upgrade from a 0.1.x deployment cannot be a restart transition. The
  running node has no `heart` process, so the install fails before rebooting.
  Reach this release with a hot upgrade or a redeploy first; restart transitions
  work after that.
- A deployment part way through the migration stays coherent. The running
  version keeps its `build.config` and its own copy of Castle, and the new
  version uses its `sys.config`, resolved by the new Castle. Nothing needs
  converting in place.

### Known limitations

- Emulator restarts need an external supervisor such as systemd, Docker,
  Kubernetes or runit. The release does not restart itself, so a node started by
  hand stays down after such an upgrade until it is started again, and then
  boots the installed version.
- `restart_new_emulator` is not supported. An ERTS change is generated as a
  one-stage `restart_emulator` instead, and a `restart_new_emulator` in an appup
  is refused.
- A node that cannot write `releases/RELEASES` can run and restart but cannot be
  upgraded. Fix the reported error and restart once before upgrading.
- Windows releases have no `bin/castle`.

## 0.1.3 - 2025-01-19

### Fixed

- Elixir 1.18 compatibility fixes.

## 0.1.2 - 2023-06-10

### Fixed

- Corrected the release name used in the generated `bin` script.

## 0.1.1 - 2023-05-27

### Fixed

- Corrected the package URL.

## 0.1.0 - 2023-05-27

### Added

- Initial release.
