### Added

- `CASTLE_ENV_FILE`: a release's `env.sh` now sources the file this variable
  names, for every launcher command and before the project's own `env.sh`
  content. A Castle that supports the file
  ([castle#56](https://github.com/ausimian/castle/issues/56)) reads it too when a
  hot install or a commit resolves the target's configuration, so a hot install
  and a restart configure the release from the same values. The path is absolute
  or relative to the release root. A file that is missing, unreadable or fails
  stops the command. See *Environment file* in the README.
  ([forecastle#60](https://github.com/ausimian/forecastle/issues/60))
