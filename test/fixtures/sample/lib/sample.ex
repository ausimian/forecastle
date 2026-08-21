defmodule Sample do
  @moduledoc false

  def greeting, do: Application.get_env(:sample, :greeting)
  def env_marker, do: Application.get_env(:sample, :env_marker)
end
