### Fixed

- A hot relup starts the applications it adds in dependency order, and stops the
  ones it removes with each application before the ones it depends on. They used
  to follow the order of the `.rel` file, which Mix writes alphabetically, so an
  added application could be started before an added application it depends on.
  `release_handler` ignores the error that follows, so the install succeeded and
  the application stayed stopped until the node restarted.
  ([forecastle#66](https://github.com/ausimian/forecastle/issues/66))
