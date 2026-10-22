### Added

- `relup: :required` release option, which rejects a build without
  `upgrade_from:` before assembly instead of producing a release with no relup.
  A project-root `relup` does not satisfy it. Set it conditionally so that local
  builds and `ref:` baseline builds, which inherit the environment, can still
  leave `upgrade_from:` out, for example
  `relup: if(System.get_env("CI") && !System.get_env("CASTLE_BASELINE"), do: :required)`.
  ([forecastle#56](https://github.com/ausimian/forecastle/issues/56))
