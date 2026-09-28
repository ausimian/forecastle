# Evaluated by the :appup compiler. Must not introduce top-level bindings.
#
# The instruction lists are empty on purpose. This application's version changes
# between the fixture's two builds, so systools requires an appup for it, but
# the relup it produces carries no instruction that loads this application's
# code. Whether the running system's code path follows the version change is
# then decided entirely by whether release_handler knows the version changed,
# and it only knows that from the release records in RELEASES.
#
# Keyed off SampleDep.MixProject.version/0 rather than SAMPLE_VSN directly, so
# that the appup's version tag cannot drift from the application's when
# SAMPLE_DEP_VSN pins one and not the other - which systools would report as a
# bad_vsn warning against a fixture that meant nothing of the sort.
case SampleDep.MixProject.version() do
  "0.1.0" ->
    {~c"0.1.0", [], []}

  vsn ->
    {to_charlist(vsn), [{~c"0.1.0", []}], [{~c"0.1.0", []}]}
end
