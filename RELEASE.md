### Changed

- Raised the minimum Elixir requirement to 1.18.

### Fixed

- `mix forecastle.relup` failed with `:systools is not available` in projects
  that do not themselves depend on `:sasl`, because Elixir prunes unused OTP
  applications from the build's code path.
- The `GitHub` link in the Hex package metadata pointed at the Castle
  repository rather than Forecastle's.
