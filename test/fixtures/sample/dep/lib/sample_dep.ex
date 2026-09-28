defmodule SampleDep do
  @moduledoc false

  # Baked in at compile time so that the two builds of this application really
  # differ, though nothing in the relup reloads this module - which is the
  # point. What moves, or fails to move, is the code path the application is
  # reached through.
  @vsn_tag System.get_env("SAMPLE_VSN", "0.1.0")

  @doc "The version this module was compiled from."
  def vsn, do: @vsn_tag

  @doc "The directory this application is currently reached through."
  def lib_dir, do: to_string(:code.lib_dir(:sample_dep))
end
