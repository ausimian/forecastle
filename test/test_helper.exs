{:ok, _} = Forecastle.Fixture.start_link()

# The end-to-end suite boots a real release and performs a hot upgrade. It is
# opt-in: `mix test --include e2e`.
ExUnit.start(exclude: [:e2e])
