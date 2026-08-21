# Evaluated by the :appup compiler. Must not introduce top-level bindings.
case System.get_env("SAMPLE_VSN", "0.1.0") do
  "0.1.0" ->
    {~c"0.1.0", [], []}

  vsn ->
    {to_charlist(vsn), [{~c"0.1.0", [{:update, Sample.Counter, {:advanced, []}}]}],
     [{~c"0.1.0", [{:update, Sample.Counter, {:advanced, []}}]}]}
end
