import Config

# Only reachable if Castle expanded build.config into sys.config before boot.
config :sample,
  greeting: System.get_env("SAMPLE_GREETING", "runtime-default"),
  env_marker: System.get_env("SAMPLE_ENV_MARKER", "unset")

# The launcher sources env.sh, and so runs the preboot VM that evaluates this
# file, before it assigns the release variables. fetch_env! is deliberate: if
# the Castle integration stops applying the launcher's defaults ahead of
# expanding configuration, the release fails to boot rather than booting with
# these silently missing.
config :sample,
  release_node: System.fetch_env!("RELEASE_NODE"),
  release_cookie_set: System.fetch_env!("RELEASE_COOKIE") != "",
  release_tmp: System.fetch_env!("RELEASE_TMP"),
  release_mode: System.fetch_env!("RELEASE_MODE"),
  release_vm_args: System.fetch_env!("RELEASE_VM_ARGS")
