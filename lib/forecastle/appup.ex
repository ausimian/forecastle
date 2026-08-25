defmodule Forecastle.Appup do
  @moduledoc """
  Reading appup files, and asking them the questions `systools` asks of them.

  An appup is read in two places here, for two different questions.
  `mix castle.relup`'s `auto` strategy asks whether an appup covers a particular
  transition *at all*, because an application the project does not own whose
  version moved with nothing to cover the move makes that edge a restart.
  `mix castle.appup` asks what the entry it finds actually *does*, because an
  entry that exists and mentions half the modules that changed is the failure
  that check exists for.

  Both are questions about one file, keyed by one from-version, and the two must
  not be able to disagree: a check that pronounced an appup adequate while
  `auto` restarted the same edge - or the reverse - would be worse than no check
  at all. So the reading and the matching live here, once, and both callers go
  through them.

  ## Matching a from-version is `systools_relup`'s job

  `appup_search_for_version/2` is what `systools` and `release_handler` both
  select an entry with, and it is not a string comparison. A from-version given
  as a charlist matches by term equality; one given as a **binary** is a regular
  expression, run against the from-version with
  `re:run(BaseVsn, Vsn, [unicode, {capture, first, list}])` and accepted only on
  `{match, [BaseVsn]}` - so the whole match has to be the from-version, and a
  prefix regex does not match a longer version.

  The function is exported for reuse ("Used by `release_handler:find_script/4`.
  Also used by kernel, stdlib and sasl tests"), so it is called here rather than
  reimplemented. Verified against OTP 28.3, `sasl-4.3`.

  ## A script element may itself be a list

  `systools_rc:expand_script/1` expands each instruction's short form into its
  long one, and it has a second effect that `appup(4)` does not document: a
  script element that is a *list* is spliced into the script. So
  `[[restart_emulator]]` is a script that restarts the emulator, and `:systools`
  accepts it.

  **The two effects are exclusive, and the order is the whole of it.** A list
  element matches no clause of the expansion, so it is spliced *instead of* being
  expanded and its members are never passed back through. That is why the same
  instruction can be legal at the top level and illegal one list deeper:
  `[{load_module, m}]` passes the syntax check, `[[{load_module, m}]]` is a
  `{bad_instruction, {load_module, m}}`. Splicing first and expanding afterwards
  is a different function, and the difference is a false pass.

  `script/2` therefore does what `expand_script/1` does, in that order, and every
  question here is asked of its result. It matters in both directions - a nested
  `delete_module` is an instruction that turns a coverage into a gap, so missing
  one failed *silently* - and it happens exactly once, since `:systools` refuses
  two levels of nesting as readily as it accepts one. See `expand/1` for the
  measurements.

  ## An instruction is credited only once its whole shape is legal

  Recognising an instruction by its head and the position of its module is a
  false *pass*, which is the one answer a gate must never give.
  `{restart_application, App, Anything}` is not an instruction -
  `systools_rc:check_syntax/1` refuses it as a `bad_instruction` and the edge
  produces no relup at all - but read by leading elements alone it looked like a
  whole-application instruction and covered the entire inventory.

  So `effects/4` and `named/2` credit nothing until `legal?/1` says the shape is
  one `:systools` accepts, and `refused/1` hands the rest back for a caller to
  report. `legal?/1` is `check_op/1` and nothing more, which is exact rather than
  approximate for the reason above: `check_syntax/1` runs on the expanded script,
  `script/2` produces the expanded script, so the same vocabulary applies to a
  top-level instruction and to a fragment member without either of them carrying
  a note about where it came from. It is deliberately allowed to be *narrower*
  than `:systools`: too narrow costs a false gap with the instruction printed
  beside it, too wide costs a false pass.

  ## What an instruction covers, and of what

  Four high-level instructions name one module, and in every arity `appup(4)`
  allows the module is the **second element** of the tuple. That is not an
  assumption: `systools_rc:expand_script/1` expands every short form into the long
  one and leaves `Mod` where it was, and `normalize_instrs/1` does the same for
  the two `update` forms it has left.

  **They do not all do the same thing, and asking only whether a module is
  "mentioned" gets the dangerous case backwards.** Measured in
  `systools_rc:translate_dep_to_low/3` and `translate_add_module_instrs/2`:

    * `update` and `load_module` become `{load, {Mod, …}}` plus a
      `load_object_code` for it, and `add_module` is rewritten into a
      `load_module` first. All three put the new code into the system, so all
      three cover a module whose code **changed** or that was **added**.
    * `delete_module` becomes `{remove, {Mod, …}}` and `{purge, [Mod]}`, and
      **nothing loads it**. It covers a module that was **removed** - and a
      changed module named only by a `delete_module` is not covered at all. It
      is deleted, which is worse than being left stale.

  So coverage is asked per *effect*: `:load` for a module that has to arrive,
  `:removal` for one that has to go. A model that treated the four alike
  reported a `delete_module` on a changed module as covered and exited zero.

  **The `load` and `remove` those translate into can also be written by hand, and
  they count too.** `check_op/1` accepts both in an appup - measured: an appup
  script of `[{load_module, M, …}, {remove, {M, …}}]` is translated to a `load`
  followed by a `remove`, and `release_handler_1` implements the second with
  `code:purge/1` and `code:delete/1`, so `M` is loaded and then made unavailable.
  Ignoring them was wrong in both directions: a low-level `remove` undoing a
  covered load was a false pass, and a removal expressed as one rather than as a
  `delete_module` was a false gap. They are the one pair whose module sits inside
  a tuple rather than at the second element, which is what `subject/1` is for.

  `DepMods` is deliberately not coverage either. It is the last element of most
  of those instructions and names modules the instruction's own module depends
  on, which `systools_rc` uses only to order the script - a module appearing
  only in somebody else's `DepMods` list is never loaded, and counting it would
  turn the exact question this module answers into a substring search. The same
  goes for `{apply, {M, F, A}}`: naming a module in a function call says nothing
  about loading it.

  Three instructions are about a whole application, and they split along the
  same line. Measured in `systools_rc:translate_application_instrs/3`:
  `add_application` expands to an `add_module` per module of the new application
  (`:load` only); `remove_application` to a `remove` per module of the old one
  (`:removal` only); and `restart_application` to both - every old module
  removed and purged, every new one added.

  **"Every module" there is the `.app` resource's `modules` list, not the beams
  on disk**, because that is what `#application.modules` holds - and the two can
  differ. So `effects/4` takes the inventories rather than assuming them: see its
  documentation for what that costs a build whose `.app` and `ebin` disagree.

  `restart_application` being *both*, in that order, is also why the question is
  "what state does the script leave this module in" rather than "which sets is it
  in". Order settles it; two sets need a rule about which to subtract, and any
  such rule is blind to a load followed by a removal.

  ## Which scripts need no module coverage at all

  An edge that ends by restarting the emulator needs none: module-level
  instructions are moot when the code is going to be loaded from scratch by a
  new VM.

  Which edges those are is `systools_rc:sort_emulator_restart/3`'s answer rather
  than a reading of the appup's own ordering, and the two differ. Measured
  against OTP 28.3, `sasl-4.3`:

    * `restart_emulator` is filtered out of the script wherever the appup put it
      and appended to the end. So its **position in the appup does not matter**,
      and a check that looked at the last instruction would miss an appup that
      wrote it first.
    * `restart_new_emulator` in a **downgrade** script is removed and a plain
      `restart_emulator` appended in its place. So a two-stage instruction on
      the way down is a one-stage restart, and needs no coverage either.
    * `restart_new_emulator` in an **upgrade** script is hoisted to the front,
      before the point of no return: the emulator is replaced and the rest of
      the relup then runs on the way up, so the module instructions still
      matter. It is also the transition Castle does not support at all - see
      `mix castle.relup`, which refuses it.
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

  @typedoc "An appup term: the application version it belongs to, and its two instruction lists."
  @type t :: {charlist(), [entry()], [entry()]}

  @typedoc "One from-version and the script that goes with it."
  @type entry :: {charlist() | binary(), [term()]}

  @typedoc "Which of an appup's two independent lists a question is about."
  @type direction :: :up | :down

  @typedoc """
  What an instruction does to a module.

  `:load` puts new code into the running system; `:removal` takes code out. A
  module that changed or was added needs the first, one that was removed needs
  the second, and no instruction does both.
  """
  @type effect :: :load | :removal

  @typedoc """
  What `effects/4` could settle about one module.

  An effect where order cannot change the answer, and the instructions involved
  where it can - which the caller reports rather than resolving. See `effects/4`
  for why the ordering is deliberately not modelled.
  """
  @type resolution :: effect() | {:conflict, [term()]}

  @doc """
  Makes `:sasl`'s build-time modules available.

  Elixir prunes unused OTP applications from the build's code path, which would
  otherwise leave `:systools` - and `:systools_relup`, which answers whether an
  appup covers a transition - unavailable in projects that do not already depend
  on `:sasl`. Every caller here needs one or the other, and a missing module
  looks the same either way, so it is asked for once.
  """
  @spec ensure_systools!() :: :ok
  def ensure_systools! do
    Mix.ensure_application!(:sasl)
    {:ok, _started} = :application.ensure_all_started(:sasl)
    :ok
  end

  @doc """
  The applications the project is taken to own the appups for: its own, plus
  every child of an umbrella.

  Everything else in a release is something whose upgrade instructions, if it
  has any, were written for somebody else's transitions. `mix castle.relup` uses
  that to decide which moved applications can make an edge a restart;
  `mix castle.appup` uses it as the default set of applications to check.
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

  Returns `{:error, phrase}` rather than raising, because both callers have
  something of their own to say about a missing or unreadable appup and the
  phrase is the middle of that sentence rather than the whole of it.
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
  One of an appup's two instruction lists.

  They are independent: a from-version present in one need not be present in the
  other, so every question about an appup is a question about a direction.
  """
  @spec entries(t(), direction()) :: [entry()]
  def entries({_appup_vsn, up, _down}, :up), do: up
  def entries({_appup_vsn, _up, down}, :down), do: down

  @doc """
  The version the appup says it belongs to.

  `systools_relup` compares this against the application's own version and warns
  `bad_vsn` when they differ - it does *not* refuse, and it still uses the entry
  it found, which is why this is exposed rather than checked here.
  """
  @spec vsn(t()) :: charlist()
  def vsn({appup_vsn, _up, _down}), do: appup_vsn

  @doc """
  The script for a from-version, selected the way `systools_relup` selects it,
  and expanded the way `systools_rc` expands it.

  `:error` means no entry matched, which is what `:systools.make_relup/4` fails
  on outright. A script that is not a list is handed back untouched, because
  what a caller has to say about one is not something this can decide - see
  `mix castle.appup`, which reports it.

  The expansion is the second half of the journey from the appup file to a
  question about instructions, and it is done here so that it is done exactly
  once, and so that what comes out is the script `check_syntax/1` would see -
  which is what makes `legal?/1` able to be `check_op/1` exactly. See the
  moduledoc.
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
  What the script leaves each module in: `:load` if its code ends up in the
  running system, `:removal` if it ends up out of it, or `{:conflict, …}` where
  that is not answerable without knowing an order this task cannot know.

  **The order instructions run in is deliberately not modelled, and that is the
  answer to five review rounds of getting it wrong rather than a gap in this
  one.** Reading the script as two sets could not tell a load from a load undone
  by a later removal. Reading it as a sequence in source order was wrong too,
  because `systools_rc` reorders: measured on OTP 28.3, `sasl-4.3`,
  `[{update, dict, …, [lists]}, {remove, {lists, …}}, {update, lists, …}]` is
  accepted and translated to `[{load, lists}, {load, dict}, {remove, lists}]` -
  the dependency-connected updates are hoisted *past* the independent low-level
  `remove`, so `lists` ends up removed where source order says it ends up loaded.
  Modelling that faithfully means building `translate_dependent_instrs/4`'s
  digraph, which is reimplementing the thing this module exists to avoid
  reimplementing.

  So the question is asked only where order cannot change the answer:

    * a module with exactly **one** effect in the script has that effect,
      whatever order anything runs in. This is the overwhelmingly common case -
      an ordinary appup names each module once.
    * a module whose effects all **agree** has that effect. Loading a module
      twice still leaves it loaded.
    * a module whose effects **disagree** is a `{:conflict, instructions}`, and
      the caller reports it rather than resolving it. Every measured script of
      that shape is one an author needs to be told about: it is either refused
      outright as a `muldef_module` (see `multiply_defined/3`) or it turns on a
      translation order that is not visible in the file.

  The one exception is measured rather than assumed: a `restart_application` is
  *itself* a removal of every old module and a load of every new one, and
  `translate_application_instrs/3` emits them in that order within the one
  instruction - verified to come out as `remove, remove, purge, load, load` in
  both directions. So where a module's only effects come from a single
  `restart_application`, the answer is `:load`.

  `load_inventory` and `removal_inventory` are the application's **`.app` module
  lists** - the *new* side's and the *old* side's respectively - because that is
  what an application-level instruction expands over.
  `translate_application_instrs/3` reads `#application.modules`, which comes from
  the `.app` resource, so a beam sitting in `ebin` that the `.app` does not name
  is not touched by a `restart_application`. An earlier version of this treated
  one as covering everything, which reported exactly that module as covered while
  a successful upgrade left its old copy loaded. `Mix.Tasks.Compile.App` fills
  `:modules` in with `Keyword.put_new_lazy/3`, so a project supplying its own list
  in `application/0` keeps it, which is how an ordinary build reaches the
  mismatch.

  A module named only in another instruction's `DepMods`, or only inside an
  `{apply, {M, F, A}}`, is in neither state - it is not in the map at all.
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
  The modules a script names outright for one effect, without the expansion an
  application-level instruction implies.

  This is what a report can say something *about*. "You named a module that did
  not change" is a remark about what somebody wrote, and an `add_application`
  names no module at all - so expanding it here would turn every unchanged module
  in the application into a remark about a leftover that nobody left.

  `effects/4` is the question to ask about a *gap*; this one is for the notes
  beside it.
  """
  @spec named([term()], effect()) :: MapSet.t(module())
  def named(script, effect) when effect in [:load, :removal] do
    for instruction <- script,
        module = named_module(instruction, effect),
        into: MapSet.new(),
        do: module
  end

  @doc """
  Whether this edge ends with the emulator being restarted, and so needs no
  module-level coverage.

  The direction matters: a `restart_new_emulator` on the way down is rewritten
  into a trailing `restart_emulator`, while on the way up it is the two-stage
  transition and the rest of the relup still runs. See the moduledoc.
  """
  @spec restarts_emulator?([term()], direction()) :: boolean()
  def restarts_emulator?(script, direction) do
    :restart_emulator in script or
      (direction == :down and :restart_new_emulator in script)
  end

  @doc """
  Whether this edge asks for the two-stage emulator restart Castle does not
  support.

  Only ever true on the way up: see `restarts_emulator?/2`.
  """
  @spec two_stage_restart?([term()], direction()) :: boolean()
  def two_stage_restart?(script, direction) do
    direction == :up and :restart_new_emulator in script
  end

  @doc """
  The instructions in a script that `:systools` will refuse, among those this
  module reasons about.

  **This exists because recognising an instruction by its head and the position
  of its module was a false *pass*, which is the one answer a gate must never
  give.** `{restart_application, App, Anything}` is not an instruction:
  `systools_rc:check_syntax/1` refuses it as a `bad_instruction` and no relup is
  produced for the edge at all. Read by leading elements alone it looked like a
  whole-application instruction, so it covered the entire inventory and the check
  reported that every module was covered - of an appup that cannot be used.

  So `effects/4` and `named/2` credit an instruction only once its whole shape is
  one `:systools` accepts, and this is the other half of that: the instructions
  they declined to credit, for a caller to report. An unrecognised instruction
  covering nothing is the conservative direction on its own, but silently
  covering nothing is not enough - a reader told that a module is uncovered needs
  to know that the instruction naming it is the reason.

  Only the instructions in this module's own vocabulary are judged. `{apply, …}`,
  `point_of_no_return`, `{load_object_code, …}` and the rest are legal, name no
  module here whatever their shape, and were never credited with anything - so
  saying something about their shape would be a claim outside what this module
  is for, and `:systools` makes it anyway.
  """
  @spec refused([term()]) :: [term()]
  def refused(script) do
    for instruction <- script,
        is_tuple(instruction),
        tuple_size(instruction) >= 1,
        elem(instruction, 0) in @ours,
        not legal?(instruction),
        do: instruction
  end

  @doc """
  The modules that more than one dependency-ordered instruction defines, which
  `:systools` refuses as `muldef_module`.

  **This is the other way a script `:systools` will not accept can look complete,
  and unlike a bad instruction it is reachable by an appup somebody might
  plausibly write.** `systools_rc` builds a digraph of the instructions that carry
  `DepMods` and throws `{muldef_module, Mod}` when a module has more than one
  vertex in it, so no relup is produced at all - while asking only what state the
  script leaves each module in says "covered" and exits zero.

  What counts as a vertex is measured (OTP 28.3, `sasl-4.3`) rather than read off
  the instruction list, because the application-level instructions contribute
  through their expansion and only *half* of each one does:

    * `update`, `load_module`, `add_module` and `delete_module` each contribute
      the module they name. So `update` with `load_module`, or `update` with
      `delete_module`, on one module is a `muldef_module`.
    * `add_application` and `restart_application` contribute **every module of
      the new inventory**, because `translate_application_instrs/3` expands them
      to an `add_module` apiece and `translate_add_module_instrs/2` rewrites that
      into a `load_module`. Hence `{restart_application, App}` beside an explicit
      `{update, M, …}` for one of `App`'s own modules is refused - which is the
      case worth catching, since restarting an application and special-casing one
      of its modules is a reasonable-looking thing to write.
    * `remove_application`'s half contributes **nothing**: it expands straight to
      the low-level `remove` and `purge`, which carry no `DepMods` and are not in
      the graph. Nor are a hand-written `load` or `remove` - measured,
      `[{update, M, …}, {remove, {M, …}}]` is accepted, which is exactly why
      `effects/4` has to order that pair rather than refuse it.
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
