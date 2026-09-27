# Evaluated by the :appup compiler. Must not introduce top-level bindings.
#
# **This appup is deliberately incomplete, and must stay that way.**
# `Sample.Counter` and `Sample.Unmentioned` both carry a compile-time version
# tag, so both differ between the 0.1.0 and 0.1.1 builds; only the first is
# named here. `:systools.make_relup/4` cannot see that, so the relup generates
# and the upgrade succeeds with `Sample.Unmentioned` still running the code that
# was loaded before - which is the failure `design/upgrade-tooling.md` §1.1
# states and `mix castle.appup` exists to catch.
#
# `Forecastle.UpgradeTest` asserts the stale outcome against a real booted
# release; `Forecastle.AppupCheckTest` asserts that `mix castle.appup` reports
# it. Completing this appup would take away both.
case System.get_env("SAMPLE_VSN", "0.1.0") do
  "0.1.0" ->
    {~c"0.1.0", [], []}

  vsn ->
    {to_charlist(vsn), [{~c"0.1.0", [{:update, Sample.Counter, {:advanced, []}}]}],
     [{~c"0.1.0", [{:update, Sample.Counter, {:advanced, []}}]}]}
end
