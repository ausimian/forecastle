# Forecastle

Build-time support for hot-code upgrades in Elixir releases. Forecastle is the
build-time half of a pair: [Castle](https://github.com/ausimian/castle) is the
runtime half. Consumers depend on Castle, which pulls Forecastle in as a
build-time dependency — Forecastle is not intended to be taken directly.

## What it does

`Forecastle.steps/1` wraps a Mix release's `:steps` list, injecting a
`pre_assemble` and `post_assemble` hook around `:assemble`:

- **`pre_assemble/1`** — strips runtime configuration and config providers out
  of the release (stashing them under the `Forecastle` key in `release.options`)
  and adds a `:preboot` boot script that starts `:sasl`, `:compiler`, `:elixir`
  and `:castle`.
- **`post_assemble/1`** — replays the stashed config providers into
  `sys.config`, renames `sys.config` to `build.config`, writes `bin/castle`,
  appends the Castle integration to the generated `env.sh`, and copies
  `runtime.exs`, the `.rel` file and any `relup` into the release.

The renaming and provider-stashing exist so that Castle, at runtime, controls
configuration evaluation rather than the standard Mix launcher.

`bin/<name>` is left exactly as Mix generated it. Everything Forecastle needs
around it composes instead:

- `bin/castle` is a thin wrapper that shells back through
  `bin/<name> rpc "Castle.<command>(...)"`, so it inherits cookie handling,
  distribution and node naming from the standard launcher.
- The `env.sh` fragment expands `build.config` into `sys.config` in a preboot
  VM, for the commands that boot the system. It is appended, so a project's own
  `rel/env.sh.eex` survives and runs first.
- Version selection needs no code at all: `release_handler` writes the
  committed version to `releases/start_erl.data`, which is where the standard
  launcher already reads `RELEASE_VSN` from.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/forecastle.ex` | Release step hooks (the whole of the build-time logic) |
| `lib/mix/tasks/compile/appup.ex` | `:appup` compiler — evaluates the file named by the `:appup` project key and writes `<app>.appup` into `ebin` |
| `lib/mix/tasks/forecastle.relup.ex` | `mix forecastle.relup` — wraps `:systools.make_relup/4` |
| `priv/castle.sh.eex` | EEx template for `bin/castle`, the release management CLI |
| `priv/env.sh.eex` | EEx template for the fragment appended to the release's `env.sh` |
| `test/fixtures/sample` | A real application, assembled by the test suite into a real release |
| `test/support` | The workspace the fixture is built in, and the case template for tests that build it |

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
| `test/forecastle/upgrade_test.exs` | Booting a release and hot-upgrading it, tagged `:e2e` |

The `:e2e` suite is excluded by default and included by `mix precommit`. Run it
on its own with `mix test --include e2e`. It needs no epmd daemon: the fixture
configures distribution without one.

## Known limitations

- **Windows is not supported.** Configuration is expanded at boot by the
  `env.sh` integration and there is no `env.bat` counterpart, so a `.bat`
  launcher looks for a `sys.config` nothing creates. Assembly warns. Real
  support is a feature, not a fix.
- **Failed Castle operations exit 0.** Castle catches `release_handler` errors
  and returns `:ok`, and `rpc` only reports whether evaluation completed, so
  `bin/castle` cannot surface them. Needs Castle to report failures —
  [castle#15](https://github.com/ausimian/castle/issues/15).
- **Concurrent boots race on `sys.config`.** `Castle.generate/1` hardcodes the
  version directory, so per-invocation config files aren't reachable from here.
  Same issue.

Do not work the last two around in this repo: putting Castle's logic back into
shell-embedded Elixir is the coupling `bin/castle` exists to remove.

## Compatibility

Forecastle manipulates `Mix.Release` internals and the layout Mix generates, so
it is sensitive to changes in Elixir's release tooling. The CI matrix runs the
whole suite, `:e2e` included, across Elixir 1.18–1.20 and OTP 27–29 to catch
that early.
