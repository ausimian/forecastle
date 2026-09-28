defmodule Forecastle.Appup do
  @moduledoc """
  Reads appups and applies OTP's entry-selection and instruction semantics.

  `mix castle.relup` uses this module to decide whether an appup covers a
  transition. `mix castle.appup` uses it to check what the selected entry loads
  and removes.

  From-version charlists match exactly. Binary keys are regular expressions,
  selected through `:systools_relup.appup_search_for_version/2`.

  `script/2` expands short instructions and splices one level of list fragments
  in the same order as `:systools`. Coverage credits only legal instructions:

  - `update`, `load_module`, `add_module` and `load` load a module.
  - `delete_module` and `remove` remove a module.
  - `add_application`, `remove_application` and `restart_application` affect the
    modules listed in the corresponding `.app` resources.

  Dependency-order lists and `apply` instructions do not load code. An edge that
  ends with `restart_emulator` needs no module coverage because the new VM loads
  the release from disk. An upgrade using `restart_new_emulator` still runs the
  remaining relup after the emulator restart and is rejected by Forecastle.
  """

  # The instructions that name one module, split by what they do to it. `Mod` is
  # `elem(instruction, 1)` in every arity of every one of them; see the moduledoc
  # for why that is measured rather than assumed, and for why the split matters
  # more than the list.
  # `load` and `remove` are the *low-level* pair, and they belong here for the
  # reason the high-level ones do: `check_op/1` accepts them in an appup, and
  # they are what the high-level ones translate *into*, so they decide whether
  # code is present just as surely. They carry their module inside a tuple rather
  # than as the second element - see `subject/1`.
  @load_instructions [:update, :load_module, :add_module, :load]
  @removal_instructions [:delete_module, :remove]

  # The instructions that are about a whole application, split the same way: each
  # expands to a per-module instruction for every module in the application, and
  # which per-module instruction it expands to is the whole of the difference.
  @load_applications [:add_application, :restart_application]
  @removal_applications [:remove_application, :restart_application]

  # The per-module instructions that become a vertex in `systools_rc`'s dependency
  # digraph, and so the ones a module may only be named by once. It is the four
  # high-level ones and not the low-level pair: `translate_dep_to_low/3` is what
  # builds the graph, and a hand-written `load` or `remove` is already low-level
  # and carries no `DepMods`. See `multiply_defined/3`.
  @dependency_ordered [:update, :load_module, :add_module, :delete_module]

  # Every instruction this module reasons about, which is exactly the set whose
  # shape it therefore has to be right about. See `refused/1`.
  @ours Enum.uniq(
          @load_instructions ++
            @removal_instructions ++ @load_applications ++ @removal_applications
        )

  @typedoc "An appup term: the application version and its upgrade and downgrade entries."
  @type t :: {charlist(), [entry()], [entry()]}

  @typedoc "A from-version and its script."
  @type entry :: {charlist() | binary(), [term()]}

  @typedoc "The upgrade or downgrade list of an appup."
  @type direction :: :up | :down

  @typedoc """
  What an instruction does to a module.

  Changed and added modules need `:load`; removed modules need `:removal`. No
  instruction does both.
  """
  @type effect :: :load | :removal

  @typedoc """
  The effect of a script on one module.

  `{:conflict, instructions}` means the instructions disagree and the outcome
  depends on an order that `effects/4` does not model.
  """
  @type resolution :: effect() | {:conflict, [term()]}

  @doc """
  Makes `:systools` and `:systools_relup` available.

  Elixir prunes unused OTP applications from the build's code path, so these
  `:sasl` modules are missing in projects that do not depend on `:sasl`.
  """
  @spec ensure_systools!() :: :ok
  def ensure_systools! do
    Mix.ensure_application!(:sasl)
    {:ok, _started} = :application.ensure_all_started(:sasl)
    :ok
  end

  @doc """
  Returns the applications whose appups the project owns.

  The list contains the current application and all umbrella children. Relup
  generation uses it to distinguish owned applications from dependencies, and
  `mix castle.appup` uses it as the default application set.
  """
  @spec project_apps() :: [atom()]
  def project_apps do
    umbrella =
      case Mix.Project.apps_paths() do
        nil -> []
        paths -> Map.keys(paths)
      end

    Enum.reject([Mix.Project.config()[:app] | umbrella], &is_nil/1)
  end

  @doc """
  Reads an appup file.

  Returns `{:error, phrase}` for a missing, unreadable or malformed file so the
  caller can place the reason in its own diagnostic.
  """
  @spec read(Path.t()) :: {:ok, t()} | {:error, binary()}
  def read(file) do
    case :file.consult(to_charlist(file)) do
      {:ok, [{_appup_vsn, up, down} = appup]} when is_list(up) and is_list(down) ->
        {:ok, appup}

      {:ok, _terms} ->
        {:error, "#{shorten(file)} cannot be read as an appup"}

      {:error, :enoent} ->
        {:error, "there is no appup at #{shorten(file)}"}

      {:error, reason} ->
        {:error, "#{shorten(file)} could not be read: #{inspect(reason)}"}
    end
  end

  @doc """
  Returns the upgrade or downgrade entries from an appup.

  The two directions are independent.
  """
  @spec entries(t(), direction()) :: [entry()]
  def entries({_appup_vsn, up, _down}, :up), do: up
  def entries({_appup_vsn, _up, down}, :down), do: down

  @doc """
  Returns the version named by the appup.

  `:systools_relup` warns with `bad_vsn` when it differs from the application
  version, but still uses matching entries.
  """
  @spec vsn(t()) :: charlist()
  def vsn({appup_vsn, _up, _down}), do: appup_vsn

  @doc """
  Returns the first binary entry key that is not a valid regular expression.

  Binary from-version keys are regexes. OTP raises while selecting an entry when
  one cannot be compiled, so callers should check before calling `script/2`.
  """
  @spec uncompilable_key([entry()]) :: binary() | nil
  def uncompilable_key(entries) do
    case Enum.find(entries, &uncompilable?/1) do
      {pattern, _script} -> pattern
      nil -> nil
    end
  end

  defp uncompilable?({vsn, _script}) when is_binary(vsn) do
    match?({:error, _reason}, :re.compile(vsn, [:unicode]))
  end

  defp uncompilable?(_entry), do: false

  @doc """
  Selects and expands the script for a from-version using OTP semantics.

  Returns `:error` when no entry matches. Malformed scripts that are not lists
  are returned unchanged for the caller to report.
  """
  @spec script([entry()], binary()) :: {:ok, [term()]} | :error
  def script(entries, from_vsn) do
    # Through `apply/3`, as `:systools.make_relup/4` is, and for the same
    # reason: `:sasl` is not a dependency, so the module is not on the code path
    # this is compiled against. The arguments go into a variable first because a
    # literal list would make `credo --strict` ask for a direct call, which is
    # the thing that cannot be written here.
    args = [to_charlist(from_vsn), entries]

    case apply(:systools_relup, :appup_search_for_version, args) do
      {:ok, script} -> {:ok, expand(script)}
      :error -> :error
    end
  end

  @doc """
  Returns the final load or removal effect for each module touched by a script.

  A result is `:load`, `:removal`, or `{:conflict, instructions}` when load and
  removal effects disagree. The function does not guess the order after
  `:systools` reorders dependency-connected instructions. Repeated effects that
  agree retain that effect. A single `restart_application` leaves modules in
  the target inventory loaded.

  `load_inventory` and `removal_inventory` are the target and source module
  lists from their `.app` resources. Application-level instructions use these
  inventories rather than every BEAM file in `ebin`.
  """
  @spec effects([term()], atom(), Enumerable.t(module()), Enumerable.t(module())) ::
          %{module() => resolution()}
  def effects(script, app, load_inventory, removal_inventory) do
    script
    |> Enum.flat_map(&touches(&1, app, load_inventory, removal_inventory))
    |> Enum.group_by(&elem(&1, 0), fn {_module, effect, instruction} -> {effect, instruction} end)
    |> Map.new(fn {module, contributions} -> {module, resolve(contributions)} end)
  end

  # One effect, or several that agree, is an answer no ordering can change. A
  # single `restart_application` disagreeing with itself is the measured
  # exception. Anything else is handed back unresolved rather than guessed at.
  defp resolve(contributions) do
    case Enum.uniq(Enum.map(contributions, &elem(&1, 0))) do
      [effect] ->
        effect

      _disagreeing ->
        case Enum.uniq(Enum.map(contributions, &elem(&1, 1))) do
          [{:restart_application, _app} = restart] when is_tuple(restart) -> :load
          instructions -> {:conflict, instructions}
        end
    end
  end

  @doc """
  Returns modules named directly by instructions with the requested effect.

  Application-level instructions are not expanded. Use `effects/4` when checking
  coverage across a complete application.
  """
  @spec named([term()], effect()) :: MapSet.t(module())
  def named(script, effect) when effect in [:load, :removal] do
    for instruction <- script,
        module = named_module(instruction, effect),
        into: MapSet.new(),
        do: module
  end

  @doc """
  Returns whether an edge ends by restarting the emulator.

  A downgrade containing `restart_new_emulator` becomes a trailing
  `restart_emulator`; an upgrade remains a two-stage transition.
  """
  @spec restarts_emulator?([term()], direction()) :: boolean()
  def restarts_emulator?(script, direction) do
    :restart_emulator in script or
      (direction == :down and :restart_new_emulator in script)
  end

  @doc """
  Returns whether an upgrade requests unsupported `restart_new_emulator`.
  """
  @spec two_stage_restart?([term()], direction()) :: boolean()
  def two_stage_restart?(script, direction) do
    direction == :up and :restart_new_emulator in script
  end

  @doc """
  Returns instructions in this module's vocabulary that OTP will reject.

  Coverage functions ignore malformed instructions. This function returns them
  for diagnostics. It also reports list fragments left after one expansion
  level, which OTP treats as bad instructions.
  """
  @spec refused([term()]) :: [term()]
  def refused(script) do
    for instruction <- script, refused?(instruction), do: instruction
  end

  defp refused?(instruction) when is_list(instruction), do: true

  defp refused?(instruction) when is_tuple(instruction) and tuple_size(instruction) >= 1 do
    elem(instruction, 0) in @ours and not legal?(instruction)
  end

  defp refused?(_instruction), do: false

  @doc """
  Returns module instructions placed before `point_of_no_return`.

  OTP permits only `load_object_code` and `apply` before this marker. A script
  without the marker returns an empty list.
  """
  @spec misplaced([term()]) :: [term()]
  def misplaced(script) do
    case Enum.split_while(script, &(&1 != :point_of_no_return)) do
      {_before, []} -> []
      {before, [:point_of_no_return | _after]} -> Enum.filter(before, &ours_instruction?/1)
    end
  end

  defp ours_instruction?(instruction)
       when is_tuple(instruction) and tuple_size(instruction) >= 1 do
    elem(instruction, 0) in @ours
  end

  defp ours_instruction?(_instruction), do: false

  @doc """
  Returns modules defined by more than one dependency-ordered instruction.

  OTP rejects these as `muldef_module`. Module-level load and delete instructions
  contribute one definition. `add_application` and `restart_application`
  contribute every module in the target inventory. Low-level `load` and
  `remove` instructions do not contribute dependency-graph vertices.
  """
  @spec multiply_defined([term()], atom(), Enumerable.t(module())) :: [module()]
  def multiply_defined(script, app, load_inventory) do
    script
    |> Enum.flat_map(&vertices(&1, app, load_inventory))
    |> Enum.frequencies()
    |> Enum.filter(fn {_module, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp vertices(instruction, app, load_inventory) do
    cond do
      not legal?(instruction) ->
        []

      whole_application?(instruction, app) ->
        loads(instruction, load_inventory) |> Enum.map(&elem(&1, 0))

      true ->
        for {kind, module} <- List.wrap(subject(instruction)),
            kind in @dependency_ordered,
            do: module
    end
  end

  @doc """
  Returns `remove_application` instructions for the application owning the appup.

  OTP rejects such an instruction while the application remains in the target
  release.
  """
  @spec self_removals([term()], atom()) :: [term()]
  def self_removals(script, app) do
    for instruction <- script, self_removal?(instruction, app), do: instruction
  end

  defp self_removal?({:remove_application, app}, app), do: true
  defp self_removal?(_instruction, _app), do: false

  # `systools_rc:expand_script/1`, in the two things it does and in the order it
  # does them - which is the part that matters, because a flatten followed by a
  # rewrite is not the same function and the difference is a false pass.
  #
  # Its shape is: run each element through a `case` that rewrites the short forms
  # into the long ones, then, *if the result is a list*, append it into the
  # script rather than consing it on. No clause of that `case` matches a list and
  # none of them returns one, so the two branches never meet: a list element is
  # spliced verbatim, and everything else is expanded. The spliced members are
  # never passed back through the expansion.
  #
  # So the same instruction is legal at the top level and illegal one list
  # deeper, and that is measured rather than inferred (OTP 28.3, `sasl-4.3`,
  # through `translate_scripts/4`):
  #
  #   - `[{load_module, m}]` passes the syntax check; `[[{load_module, m}]]` is
  #     `{bad_instruction, {load_module, m}}`. Same for `{update, Mod}` and
  #     `{add_application, App}` - the three heads whose short forms only exist
  #     because the expansion rewrites them.
  #   - `[[{delete_module, m}]]` is fine, and so are nested `add_module`,
  #     `remove_application`, `restart_application` and
  #     `{add_application, App, Type}`: `check_op/1` has those arities itself, so
  #     they need no expansion to be legal.
  #   - `[[[restart_emulator]]]` gives `{ok, [point_of_no_return,
  #     restart_emulator]}`, so a nested restart really does exempt the edge; and
  #     a nested `{delete_module, Mod, []}` translates to the `remove` and
  #     `purge` pair, which is the nested instruction that turns a coverage into
  #     a gap.
  #   - two levels are refused: `[[[[restart_emulator]]]]` is
  #     `{bad_instruction, [restart_emulator]}`.
  #
  # Hence: expand the top level, splice a fragment as it stands, and leave
  # `legal?/1` to be exactly `check_op/1` - which is what the expanded script is
  # then checked against, so a fragment member is held to it too. Flattening
  # first and expanding afterwards would credit a nested short form that
  # `:systools` refuses, and is what this used to do.
  defp expand(script) when is_list(script) do
    Enum.flat_map(script, fn
      fragment when is_list(fragment) -> fragment
      instruction -> [expanded(instruction)]
    end)
  end

  defp expand(malformed), do: malformed

  # The rewrite where it produces something legal, and the instruction as written
  # where it does not.
  #
  # The second half is only about what `refused/1` reports, and it costs nothing
  # anywhere else: `covers`, `named` and `effects` all credit a legal instruction
  # only, so an illegal one contributes the same nothing either way. What it buys
  # is that the report quotes the appup. The rewrite fills in `brutal_purge`
  # defaults, so `{update, Foo, {:bogus, 1}}` became
  # `{update, Foo, {:bogus, 1}, brutal_purge, brutal_purge, []}` and the reader
  # went looking in their appup for a line that is not in it.
  #
  # Nothing legal is lost by preferring the original, because the short forms
  # exist *because* `check_op/1` has no clause for them - if the rewrite is
  # illegal, so is what it was rewritten from.
  defp expanded(instruction) do
    rewritten = rewritten(instruction)

    if legal?(rewritten), do: rewritten, else: instruction
  end

  # `systools_rc:expand_script/1`'s `case`, and only that: the short forms of the
  # three heads that have them, rewritten into the long ones. Anything it does
  # not match is its own `_ -> I`, which is what leaves an instruction for
  # `legal?/1` to refuse.
  #
  # The guards are the Erlang ones rather than a reading of `appup(4)`, because
  # they are what decides whether a form expands at all: `{update, Mod, X}` is
  # rewritten for `X` a tuple, `soft`, `supervisor` or a list, and for no other
  # `X`. An atom that is none of those falls through to arity 3, which
  # `check_op/1` has no clause for, so `{update, Mod, :whatever}` is a
  # `bad_instruction` - and a tuple that is not `{advanced, _}` expands and is
  # then refused by `check_change/1` instead. Both end up refused; only the route
  # differs.
  defp rewritten({:load_module, mod}), do: {:load_module, mod, :brutal_purge, :brutal_purge, []}

  defp rewritten({:load_module, mod, deps}) when is_list(deps),
    do: {:load_module, mod, :brutal_purge, :brutal_purge, deps}

  defp rewritten({:update, mod}), do: {:update, mod, :soft, :brutal_purge, :brutal_purge, []}

  defp rewritten({:update, mod, :supervisor}),
    do: {:update, mod, :static, :default, {:advanced, []}, :brutal_purge, :brutal_purge, []}

  defp rewritten({:update, mod, change}) when is_tuple(change),
    do: {:update, mod, change, :brutal_purge, :brutal_purge, []}

  defp rewritten({:update, mod, :soft}),
    do: {:update, mod, :soft, :brutal_purge, :brutal_purge, []}

  defp rewritten({:update, mod, deps}) when is_list(deps),
    do: {:update, mod, :soft, :brutal_purge, :brutal_purge, deps}

  defp rewritten({:update, mod, change, deps}) when is_tuple(change) and is_list(deps),
    do: {:update, mod, change, :brutal_purge, :brutal_purge, deps}

  defp rewritten({:update, mod, :soft, deps}) when is_list(deps),
    do: {:update, mod, :soft, :brutal_purge, :brutal_purge, deps}

  defp rewritten({:add_application, app}), do: {:add_application, app, :permanent}

  defp rewritten(instruction), do: instruction

  # `systools_rc:check_op/1`, for the heads this module reasons about, and
  # nothing else. It is the whole of what `check_syntax/1` accepts, and it runs
  # on the script *after* `expand_script/1` and before `normalize_instrs/1` -
  # which is exactly the script `expand/1` above produces, so this can be one for
  # one with it rather than a union of source and expanded shapes.
  #
  # That equivalence is the point. A fragment member reaches here unexpanded,
  # because `expand_script/1` never expands one, so holding everything to
  # `check_op/1` alone is what makes a nested short form refused and a top-level
  # one accepted - without carrying an origin flag around to remember which was
  # which. There is no `{load_module, Mod}`, `{update, Mod}` or
  # `{add_application, App}` clause here for that reason: those exist only as
  # something the expansion rewrites.
  #
  # Being *narrower* than `:systools` costs a false gap with the instruction
  # printed beside it; being wider costs a false pass. That asymmetry is why the
  # default is `false` and every accepted shape has to be written down.
  defp legal?({:update, mod, change, pre, post, deps}),
    do: is_atom(mod) and change?(change) and purge?(pre) and purge?(post) and modules?(deps)

  defp legal?({:update, mod, timeout, change, pre, post, deps}) do
    is_atom(mod) and timeout?(timeout) and change?(change) and purge?(pre) and purge?(post) and
      modules?(deps)
  end

  defp legal?({:update, mod, mod_type, timeout, change, pre, post, deps}) do
    is_atom(mod) and mod_type?(mod_type) and timeout?(timeout) and change?(change) and
      purge?(pre) and purge?(post) and modules?(deps)
  end

  defp legal?({:load_module, mod, pre, post, deps}),
    do: is_atom(mod) and purge?(pre) and purge?(post) and modules?(deps)

  defp legal?({:add_module, mod}), do: is_atom(mod)
  defp legal?({:add_module, mod, deps}), do: is_atom(mod) and modules?(deps)

  defp legal?({:delete_module, mod}), do: is_atom(mod)
  defp legal?({:delete_module, mod, deps}), do: is_atom(mod) and modules?(deps)

  defp legal?({:add_application, app, type}), do: is_atom(app) and start_type?(type)
  defp legal?({:remove_application, app}), do: is_atom(app)
  defp legal?({:restart_application, app}), do: is_atom(app)

  defp legal?({:load, {mod, pre, post}}), do: is_atom(mod) and purge?(pre) and purge?(post)
  defp legal?({:remove, {mod, pre, post}}), do: is_atom(mod) and purge?(pre) and purge?(post)

  defp legal?(_instruction), do: false

  # `check_change/1`, `check_purge/1`, `check_timeout/1`, `check_mod_type/1`,
  # `check_start_type/1`, and `check_list/1` followed by `check_mod/1` on each
  # element. One for one with `systools_rc`.
  defp change?(:soft), do: true
  defp change?({:advanced, _extra}), do: true
  defp change?(_change), do: false

  defp purge?(purge), do: purge in [:soft_purge, :brutal_purge]

  defp timeout?(:default), do: true
  defp timeout?(:infinity), do: true
  defp timeout?(timeout), do: is_integer(timeout) and timeout > 0

  defp mod_type?(mod_type), do: mod_type in [:static, :dynamic]

  defp start_type?(type), do: type in [:none, :load, :temporary, :transient, :permanent]

  defp modules?(modules), do: is_list(modules) and Enum.all?(modules, &is_atom/1)

  # What one instruction does, as `{module, effect, instruction}` per module it
  # touches. The instruction is carried along because a module touched by more
  # than one of them is reported rather than resolved, and the report has to name
  # them - see `resolve/1`.
  #
  # An illegal instruction does nothing, which is what makes a refusal safe to
  # report rather than having to be acted on.
  defp touches(instruction, app, load_inventory, removal_inventory) do
    cond do
      not legal?(instruction) ->
        []

      self_removal?(instruction, app) ->
        []

      whole_application?(instruction, app) ->
        removals(instruction, removal_inventory) ++ loads(instruction, load_inventory)

      true ->
        module(instruction)
    end
  end

  defp removals(instruction, inventory) do
    if elem(instruction, 0) in @removal_applications,
      do: Enum.map(inventory, &{&1, :removal, instruction}),
      else: []
  end

  defp loads(instruction, inventory) do
    if elem(instruction, 0) in @load_applications,
      do: Enum.map(inventory, &{&1, :load, instruction}),
      else: []
  end

  defp module(instruction) do
    case subject(instruction) do
      {kind, module} when kind in @load_instructions -> [{module, :load, instruction}]
      {kind, module} when kind in @removal_instructions -> [{module, :removal, instruction}]
      _other -> []
    end
  end

  # One total clause rather than a guarded one and a fallback, because Elixir
  # 1.20 proves the fallback dead and `mix compile --warnings-as-errors` then
  # fails: both callers reach this only once `legal?/1` has said yes, and every
  # shape `legal?/1` accepts is a tuple of at least two elements, so the
  # set-theoretic inference can see that a non-tuple never arrives here. Writing
  # the guard as the first conjunct keeps it honest without the dead clause -
  # `and` short-circuits, so `elem/2` is never reached for a non-tuple.
  defp whole_application?(instruction, app) do
    is_tuple(instruction) and tuple_size(instruction) >= 2 and
      elem(instruction, 0) in (@load_applications ++ @removal_applications) and
      elem(instruction, 1) == app
  end

  # Which module an instruction is about, and under which head. The four
  # high-level instructions carry it as the second element - `expand_script/1`
  # and `normalize_instrs/1` expand every short form and leave `Mod` where it
  # was - while the two low-level ones carry it inside the tuple that sits there
  # instead. Anything whose second element is not an atom names no single module,
  # which is what keeps `{purge, Mods}`, `{apply, {M, F, A}}` and
  # `{load_object_code, {Lib, Vsn, Mods}}` out without naming them.
  defp subject({:load, {module, _pre, _post}}) when is_atom(module), do: {:load, module}
  defp subject({:remove, {module, _pre, _post}}) when is_atom(module), do: {:remove, module}

  defp subject(instruction)
       when is_tuple(instruction) and tuple_size(instruction) >= 2 and
              is_atom(elem(instruction, 1)) do
    {elem(instruction, 0), elem(instruction, 1)}
  end

  defp subject(_instruction), do: nil

  defp named_module(instruction, effect) do
    case subject(instruction) do
      {kind, module} ->
        if kind in instructions(effect) and legal?(instruction), do: module

      nil ->
        nil
    end
  end

  defp instructions(:load), do: @load_instructions
  defp instructions(:removal), do: @removal_instructions

  defp shorten(path), do: Path.relative_to_cwd(path)
end
