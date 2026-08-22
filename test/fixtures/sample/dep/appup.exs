# Evaluated by the :appup compiler. Must not introduce top-level bindings.
#
# The instruction lists are empty on purpose. This application's version changes
# between the fixture's two builds, so systools requires an appup for it, but
# the relup it produces carries no instruction that loads this application's
# code. Whether the running system's code path follows the version change is
# then decided entirely by whether release_handler knows the version changed,
# and it only knows that from the release records in RELEASES.
case System.get_env("SAMPLE_VSN", "0.1.0") do
  "0.1.0" ->
    {~c"0.1.0", [], []}

  vsn ->
    {to_charlist(vsn), [{~c"0.1.0", []}], [{~c"0.1.0", []}]}
end
