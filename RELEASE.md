### Fixed

- `Forecastle.Deployment.await_exit!/2` and `install_supervised/3` count a process
  that has exited but not yet been collected by its parent (a zombie) as gone. A
  daemonised release's parent is PID 1, and where PID 1 does not collect orphans
  promptly - a container without an init, for instance - a node that had already
  rebooted was read as still running: `install_supervised/3` waited out its
  timeout, or reported a failed install as one that never rebooted.
