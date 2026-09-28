defmodule Sample.EchoProvider do
  @moduledoc false

  # A config provider that hands its init argument straight back, so that
  # whatever the project declared can be read out of the assembled sys.config
  # and compared with what was written there.
  #
  # `Mix.Release` allows any term as a provider's init argument. Forecastle used
  # to rewrite anything that was not a keyword list into `[path: arg]` and add an
  # `:env` key to whatever was left, so a provider declared with a binary, a map
  # or a plain list was handed something else entirely - which is the corruption
  # this exists to notice.

  @behaviour Config.Provider

  @impl true
  def init(arg), do: arg

  @impl true
  def load(config, _arg), do: config
end
