defmodule Sample do
  @moduledoc false

  def greeting, do: Application.get_env(:sample, :greeting)
  def env_marker, do: Application.get_env(:sample, :env_marker)

  @doc "The release variables that were visible while runtime.exs was evaluated."
  def release_env do
    for key <- [:release_node, :release_cookie_set, :release_tmp, :release_mode, :release_vm_args],
        into: %{},
        do: {key, Application.get_env(:sample, key)}
  end
end
