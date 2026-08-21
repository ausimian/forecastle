import Config

# Only reachable if Castle expanded build.config into sys.config before boot.
config :sample,
  greeting: System.get_env("SAMPLE_GREETING", "runtime-default"),
  env_marker: System.get_env("SAMPLE_ENV_MARKER", "unset")
