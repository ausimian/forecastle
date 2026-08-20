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
  `sys.config`, renames `sys.config` to `build.config`, replaces the generated
  `bin/<name>` launcher with the EEx template in `priv/script.sh`, and copies
  `runtime.exs`, the `.rel` file and any `relup` into the release.

The renaming and provider-stashing exist so that Castle, at runtime, controls
configuration evaluation rather than the standard Mix launcher.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/forecastle.ex` | Release step hooks (the whole of the build-time logic) |
| `lib/mix/tasks/compile/appup.ex` | `:appup` compiler — evaluates the file named by the `:appup` project key and writes `<app>.appup` into `ebin` |
| `lib/mix/tasks/forecastle.relup.ex` | `mix forecastle.relup` — wraps `:systools.make_relup/4` |
| `priv/script.sh` | EEx template for the replacement release launcher; supports unpack/install |

## Working on this project

- Run `mix precommit` before committing. It is the single validation gate —
  `compile --warnings-as-errors`, `deps.unlock --unused`, `format`,
  `credo --strict`, `test`. Do not run the individual checks piecemeal.
- `@version` in `mix.exs` is the single source of truth for the version.
- Add user-visible changes to `RELEASE.md` on the feature branch, using
  [Keep a Changelog](https://keepachangelog.com/) sections. Do not defer release
  notes to release time, and exclude internal CI/lint churn.
- Release with `mix publisho <patch|minor|major>`, which bumps `@version`, folds
  `RELEASE.md` into `CHANGELOG.md` at the `<!-- %% CHANGELOG_ENTRIES %% -->`
  placeholder, commits and tags. Tags are bare semver — no `v` prefix. Pushing
  a tag triggers `.github/workflows/publish.yml`, which publishes to Hex.
- Never commit directly to `main`; work on a feature branch and open a PR.

## Compatibility

Forecastle manipulates `Mix.Release` internals and the layout Mix generates, so
it is sensitive to changes in Elixir's release tooling. The CI matrix builds
across Elixir 1.18–1.20 and OTP 27–29 to catch that early. There is no test
suite at present, so the matrix is effectively a compile check — treat a green
CI run as weaker evidence than usual and verify release changes by building a
real release.
