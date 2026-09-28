import Config

# Evaluated by Elixir's own Config.Provider pipeline: in the booting VM on a
# cold start, and in the peer Castle boots to work out what this version's
# configuration is on the way into an upgrade.
config :sample,
  greeting: System.get_env("SAMPLE_GREETING", "runtime-default"),
  env_marker: System.get_env("SAMPLE_ENV_MARKER", "unset")

# fetch_env! is deliberate. Both of the places this file is evaluated are meant
# to see the release variables the launcher assigns - the booting VM because the
# launcher exports them before it starts, and Castle's peer because it inherits
# the environment of the node that started it - so a release that loses them
# fails to boot, or fails the install, rather than coming up with these silently
# missing.
config :sample,
  release_node: System.fetch_env!("RELEASE_NODE"),
  release_cookie_set: System.fetch_env!("RELEASE_COOKIE") != "",
  release_tmp: System.fetch_env!("RELEASE_TMP"),
  release_mode: System.fetch_env!("RELEASE_MODE"),
  release_vm_args: System.fetch_env!("RELEASE_VM_ARGS")
