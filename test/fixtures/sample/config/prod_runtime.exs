import Config

# The file a release names through `:runtime_config_path`, while
# `config/runtime.exs` sits in the same directory. Whichever one the release
# evaluates says which it was, so a release that reads the other one is
# recognisable from the outside.
config :sample,
  greeting: System.get_env("SAMPLE_GREETING", "from-prod-runtime"),
  env_marker: "prod-runtime"
