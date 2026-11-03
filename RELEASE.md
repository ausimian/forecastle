### Fixed

- A hot relup that removes an application now also takes it off the code path.
  OTP's `remove_application` stops and unloads the application but leaves its
  `lib/<app>-<vsn>/ebin` on the path, so while the superseded release was still
  on disk the application's `.app` could still be found. An application added by
  a later upgrade, with an optional dependency on the removed one, then took it
  for present. A restart never had the problem. Adding the application back,
  whether by downgrading or by a later relup, puts the path back as before.
- A hot relup that adds an application with no modules now starts it. Nothing
  gave such an application a code path, so its `.app` could not be found and the
  start failed with an error `release_handler` ignores; the install succeeded
  and the application stayed stopped until the node restarted.
