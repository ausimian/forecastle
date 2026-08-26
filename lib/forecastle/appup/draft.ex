defmodule Forecastle.Appup.Draft do
  @moduledoc """
  What instruction each module that moved needs, and what has to be said beside
  it rather than decided for it.

  This is the half of `mix castle.appup.gen` that turns a diff of two builds into
  a script. It decides *which modules moved* - which is tedious and error-prone
  for a person and entirely mechanical - and it refuses to pretend it has decided
  *what happens to the state*, which only the author knows.
  `design/upgrade-tooling.md` §3.3 and §3.4 in ausimian/castle are where the line
  between those two is drawn.

  ## The signal is the behaviour, and `code_change/3` is not one

  Behaviours are read from the beam's `Attr` chunk - by `Forecastle.Build`, out
  of the same read that fingerprinted the module - and that is the only signal.
  `{:update, M}` (soft) is the unsafe alternative, since it does not call
  `code_change/3` at all and so leaves a state that did need migrating alone,
  silently - and nothing here emits it.

  **§3.3's "`{:advanced, []}` is safe whether or not a `code_change/3` was
  written" holds for `use GenServer` and for nothing else, and that was found in
  review.** `code_change/3` is in `gen_server`'s and `gen_event`'s
  `-optional_callbacks`, and `code_change/4` in `gen_statem`'s and `gen_fsm`'s,
  so `@behaviour GenServer` without `use`, and every Erlang callback module, can
  declare the behaviour and export neither. Measured on OTP 28, `sys:change_code/4`
  on such a process answers `{error, {'EXIT', {undef, …}}}` and
  `release_handler_1` matches `ok = sys:change_code(…)`, so the install fails.
  The instruction is unchanged for it - see `callback/3` for why neither
  alternative is better - and the draft says so beside it.

  | Signal in `Attr` | Instruction |
  | --- | --- |
  | `Supervisor` / `:supervisor` | `{:update, M, :supervisor}` |
  | `GenServer` / `:gen_server` / `:gen_statem` / `:gen_event` / `:gen_fsm` | `{:update, M, {:advanced, []}}` |
  | anything else | `{:load_module, M}` |
  | absent from the old build | `{:add_module, M}` |
  | absent from the new build | `{:delete_module, M}` |

  **Do not classify on `code_change/3` being exported, and the reason is
  measured.** Elixir 1.19.5's `gen_server.ex:953` injects an overridable
  `@doc false def code_change(_old, state, _extra), do: {:ok, state}`, so
  **every** `use GenServer` module exports it and its presence says nothing. Nor
  can the injected default be told from a hand-written one at a release's beams:
  distinguishing them would need the `Docs` chunk (`:hidden` versus `:none`) or
  the abstract code, and `Mix.Release.strip_beam/2` removes both.

  Both attribute spellings are handled, and both are measured rather than
  assumed: Elixir modules carry `behaviour: [GenServer]`, Erlang ones
  `behaviour: [:gen_server]`, and an Erlang module written `-behavior(...)`
  carries the American spelling as its attribute *key*. See
  `Forecastle.Build.behaviours/2`.

  **A module carrying more than one behaviour is classified by the first row of
  the table that matches, and supervisor wins.** That is reachable in ordinary
  code - measured on Elixir 1.19.5, a module that is `use GenServer` and
  `@behaviour Supervisor` compiles to `behaviour: [GenServer, Supervisor]` - and
  choosing the supervisor instruction is the conservative direction: it is the
  one whose `init/1` is re-read, and a supervisor upgraded as a plain
  `gen_server` would have its child specs left alone silently. The comment beside
  the instruction names every behaviour found, so the choice is visible rather
  than implied.

  ## What it says rather than decides

  Every instruction is drafted with the comment lines that go beside it, because
  a draft that hides its uncertainty is worse than no draft. Four things can
  never be derived here:

    * **The `Extra` term is always `[]`.** Nothing can derive it. It is what
      `code_change/3` receives as its third argument, and only the author knows
      what the migration needs.
    * **`{:update, M, :supervisor}` re-reads `init/1` and reconciles child
      *specs*.** It does not upgrade the children; those need their own
      instructions.
    * **`update` only reaches processes found through the supervision tree.** A
      process nobody supervises keeps its old code, silently, and the appup will
      look as though it covered it.
    * **Ordering is stable, not correct.** `add_module` comes before the modules
      that use it and `delete_module` after, which is the part that is decidable.
      `DepMods` *between* changed modules is derivable from import tables and is
      not computed, so nothing here orders two changed modules against each
      other.

  Three more are said where they apply rather than always, and each is a fact
  about *this* module rather than a property of the table:

    * an instruction naming a module the new side's `.app` does not list cannot
      resolve object code and fails the whole relup with `no_such_module` - see
      `annotate/4`.
    * an advanced update on a module that exports no `code_change` fails the
      install with `undef` - see `callback/3`.
    * a module whose behaviour *role* differs between the two builds is drafted
      for what it becomes, while the process running now was started by the old
      code - see `role_change/3`.

  All three still draft the instruction. Refusing an entry over one module would
  take the other twenty with it, and leaving an instruction out silently is the
  §1.1 failure this tooling exists to catch, arriving from the other direction.
  """

  alias Forecastle.Build

  @typedoc "An instruction, and the comment lines that belong above it in the source."
  @type annotated :: {tuple(), [binary()]}

  @typedoc """
  One from-version entry, ready to be rendered.

  `preamble` is what has to be said about the entry as a whole rather than about
  any one instruction in it.
  """
  @type entry :: %{from_vsn: binary(), preamble: [binary()], instructions: [annotated()]}

  # The two rows of the decision table that name a behaviour, in the order they
  # are tried. Supervisor first: see the moduledoc for why a module carrying both
  # is drafted as a supervisor rather than as a gen_server.
  @supervisor [Supervisor, :supervisor]
  @advanced [GenServer, :gen_server, :gen_statem, :gen_event, :gen_fsm]

  @doc """
  The entry for one direction of one transition.

  `old` and `new` are the two sides in the order the *direction* runs in: for an
  upgrade the baseline is old and the target is new; for a downgrade they are the
  other way round. `from_vsn` is the baseline's version either way, because an
  appup's `dn` list is keyed by the version being downgraded *to*.

  A changed module is classified on the behaviours of the side being moved **to**,
  which is the code that will be running afterwards and whose `code_change/3`
  `release_handler` calls. The same side's `.app` inventory is what says whether
  the instruction can resolve object code at all - see `annotate/4`.
  """
  @spec entry(binary(), Build.side(), Build.side()) :: entry()
  def entry(from_vsn, old, new) do
    {changed, added, removed} = Build.moved(old.modules, new.modules)

    # `add_module` before the modules that use it, `delete_module` after: the
    # only part of the ordering that is decidable without building
    # `systools_rc`'s dependency digraph. Within each group the order is
    # `Build.moved/2`'s, which is sorted, so a rerun that found the same diff
    # produces the same file.
    instructions =
      Enum.map(added, &added(&1, new)) ++
        Enum.map(changed, &changed(&1, old, new)) ++ Enum.map(removed, &removed/1)

    %{from_vsn: from_vsn, preamble: preamble(instructions, new), instructions: instructions}
  end

  defp added(module, new) do
    annotate(
      {:add_module, module},
      ["#{inspect(module)} is in the new build and not in the old one."],
      module,
      new
    )
  end

  defp removed(module) do
    {{:delete_module, module},
     [
       "#{inspect(module)} is in the old build and not in the new one. systools_rc turns this",
       "into a remove and a purge and loads nothing, so it must not name a module the new",
       "build still has."
     ]}
  end

  defp changed(module, old, new) do
    was = Build.behaviours(old, module)
    now = Build.behaviours(new, module)

    {instruction, comments} =
      case classify(now) do
        {:supervisor, match} ->
          {{:update, module, :supervisor}, supervisor_comment(module, match, now)}

        {:advanced, matches} ->
          {{:update, module, {:advanced, []}},
           advanced_comment(module, matches, now) ++ callback(module, matches, was, new)}

        :plain ->
          {{:load_module, module}, plain_comment(module, now)}
      end

    annotate(instruction, comments ++ role_change(module, was, now), module, new)
  end

  # The decision table, as one function, so that the two questions asked of it -
  # which instruction a module needs, and whether the module's role changed - can
  # never be answered by two different readings of the same list.
  #
  # The advanced row answers with **every** behaviour that matched it, not just
  # the first. Which one decided the instruction is a presentation question - all
  # of them draft the same `{:advanced, []}` - but which `code_change` arity has
  # to exist is a question about each of them, and a module declaring two
  # different ones needs both asked. Raised in review, where a module declaring
  # `:gen_statem` and `GenServer` and exporting only `code_change/4` passed
  # silently.
  defp classify(behaviours) do
    cond do
      match = Enum.find(behaviours, &(&1 in @supervisor)) ->
        {:supervisor, match}

      matches = present(behaviours, @advanced) ->
        {:advanced, matches}

      true ->
        :plain
    end
  end

  defp present(behaviours, row) do
    case Enum.filter(behaviours, &(&1 in row)) do
      [] -> nil
      matches -> matches
    end
  end

  # **An advanced update calls a callback that the behaviour makes optional, and
  # a module can legitimately declare the behaviour and not export it.** That is
  # the half of §3.3 that is Elixir-specific: "worst case the injected identity
  # runs" holds for `use GenServer`, and holds for nothing else. `@behaviour
  # GenServer` without `use`, and every Erlang callback module, get no injected
  # anything - `code_change/3` is in `gen_server`'s and `gen_event`'s
  # `-optional_callbacks`, and `code_change/4` in `gen_statem`'s and
  # `gen_fsm`'s.
  #
  # Measured on OTP 28, against a `@behaviour GenServer` module exporting no
  # `code_change/3`: `sys:change_code/4` answers
  # `{error, {'EXIT', {undef, [{Mod, code_change, [Vsn, State, Extra], []}, ...]}}}`,
  # and `release_handler_1:change_code/5` matches `ok = sys:change_code(...)`, so
  # the install fails and rolls back.
  #
  # **The instruction is not changed for it, and the export is not a
  # classification signal.** §3.2 forbids reading `code_change/3`'s *presence*,
  # because Elixir's injected one makes it meaningless; absence is a different
  # fact and is decidable. What the alternatives would cost says the rest: a
  # `load_module` swaps the code under a live process with no suspend at all, and
  # a soft `{:update, M}` suspends but migrates nothing - which §3.3 names as the
  # unsafe one, since a state that did need migrating is left alone silently. So
  # the draft says the module needs a `code_change` and lets the author write one.
  #
  # **Every matched behaviour is asked, not just the one that decided the
  # instruction.** A module declaring `:gen_statem` and `GenServer` needs
  # `code_change/4` for one and `code_change/3` for the other, and which of them
  # the running process asks for is decided at run time - so exporting one of the
  # two is not enough, and checking only the first was a silent pass. Raised in
  # review.
  #
  # **The arity is the *running* process's and the export is the *new* module's,
  # which are two different sides.** Raised in a later round. `sys:change_code`
  # is handled by the behaviour the process was started under - the old code's -
  # and that is what decides whether `code_change/3` or `code_change/4` is
  # called; the module it is called *on* is the one just loaded. So a module
  # going from `GenServer` to `:gen_statem` is asked for both, because a process
  # still running as a `gen_server` will ask for `code_change/3` of a module that
  # may only export the `gen_statem` one. Asking only the destination's arity let
  # that through.
  defp callback(module, matches, was, new) do
    behaviours = Enum.uniq(matches ++ (present(was, @advanced) || []))

    case Enum.reject(arities(behaviours), &Build.exports?(new, module, :code_change, &1)) do
      [] -> []
      missing -> missing_callback(module, behaviours, missing)
    end
  end

  defp missing_callback(module, behaviours, missing) do
    [
      "",
      "#{inspect(module)} exports NO #{callbacks(missing)}, which #{list(behaviours)} needs",
      "and makes optional. release_handler calls sys:change_code, which the *running*",
      "process's behaviour handles - so the arity is the old code's and the module it is",
      "called on is the new one. Without it the install fails with undef. Elixir's `use",
      "GenServer` injects one; @behaviour alone and Erlang callback modules do not."
    ]
  end

  # `gen_server` and `gen_event` call `Mod:code_change/3`; `gen_statem` and
  # `gen_fsm` call `Mod:code_change/4`, with the state and the data apart. A
  # `supervisor` calls neither - `supervisor:system_code_change/4` re-reads
  # `init/1` - which is why this is only asked of the advanced row.
  defp code_change_arity(behaviour) when behaviour in [:gen_statem, :gen_fsm], do: 4
  defp code_change_arity(_behaviour), do: 3

  # **A module that changes behaviour role between the two builds is not
  # something an instruction can decide, and saying nothing about it would be the
  # draft hiding exactly what it cannot know.** The classification is the side
  # being moved *to*, because that is the code that will be running - but the
  # process that is running *now* was started by the old code, and an appup
  # instruction only swaps code under it. A `GenServer` that becomes a plain
  # module is drafted as a `load_module`, which loads new code under a live
  # `gen_server` with no suspend and no migration; the reverse is drafted as an
  # advanced update whose `code_change` runs against a process that was never a
  # `gen_server`.
  #
  # Neither is mechanically decidable - what the process should *become* is a
  # design decision - so the instruction stands and the entry says what changed.
  # Refusing the whole entry over one such module would take the other twenty
  # with it.
  defp role_change(module, old, new) do
    was = role(old)
    now = role(new)

    # Compared by row of the table *and*, within the advanced row, by which
    # `code_change` arity the behaviour calls - so `GenServer` for `:gen_server`
    # is the same role spelled the other way and says nothing, while `GenServer`
    # for `:gen_statem` is a different callback contract and does. Comparing the
    # row alone collapsed the second into silence; raised in review.
    if was == now do
      []
    else
      [
        "",
        "#{inspect(module)} changed behaviour role between the two builds:",
        "  was: #{phrase(was)}",
        "  now: #{phrase(now)}",
        "The instruction above is for what it becomes, but the process running now was",
        "started by the old code and an instruction only swaps code under it. What that",
        "process should become is yours to decide; nothing here can."
      ]
    end
  end

  defp role(behaviours) do
    case classify(behaviours) do
      {:supervisor, _match} -> :supervisor
      {:advanced, matches} -> {:advanced, arities(matches)}
      :plain -> :plain
    end
  end

  defp phrase(:supervisor), do: "a supervisor"
  defp phrase(:plain), do: "neither a supervisor nor a process with migratable state"

  defp phrase({:advanced, arities}) do
    "a process with migratable state, through #{callbacks(arities)}"
  end

  # **An instruction that loads a module the new side's `.app` does not name
  # cannot work, and the draft has to say so rather than leave it to be met
  # later.** `systools_rc:get_lib/2` resolves object code through
  # `#application.modules`, so an `update`, a `load_module` or an `add_module`
  # naming a module no application in the release lists is a `{no_such_module,
  # Mod}` and the whole relup fails.
  #
  # The instruction is still drafted, deliberately. Leaving it out would produce
  # an appup that builds a relup and leaves the module running its old code -
  # the exact §1.1 failure this tooling exists to catch - where drafting it fails
  # loudly at the moment a relup is generated. `mix castle.appup` reports the
  # same thing from the other side, and names the resource rather than the appup,
  # because the `modules` list is where the fix is.
  #
  # A `delete_module` needs no resolution: it translates to a `remove` and a
  # `purge` and loads nothing, so it gets no note.
  #
  # A `modules` value `:systools` will not accept at all is a different fact, and
  # it is said once in the preamble rather than against every instruction: the
  # inventory read from such a resource is empty, so a per-instruction note would
  # repeat itself for the whole application and would say the wrong thing - the
  # module is not missing from the list, the list is unusable.
  defp annotate(instruction, comments, module, new) do
    if not new.listed? or MapSet.member?(new.inventory, module) do
      {instruction, comments}
    else
      {instruction,
       comments ++
         [
           "#{inspect(module)} is NOT in the modules list of the new build's .app, so",
           "systools_rc:get_lib/2 cannot resolve object code for it and make_relup/4 will",
           "fail with no_such_module. The fix is that list, not this instruction."
         ]}
    end
  end

  defp supervisor_comment(module, match, behaviours) do
    [
      "#{inspect(module)}: #{signal(match, behaviours)}",
      "This re-reads init/1 and reconciles the child *specs*. It does not upgrade the",
      "children - those need instructions of their own."
    ]
  end

  # Deliberately says nothing about whether a `code_change` is there: it cannot
  # tell a hand-written one from Elixir's injected identity, which is §3.2, and
  # `callback/3` is what says the one thing about it that *is* decidable.
  defp advanced_comment(module, matches, behaviours) do
    [
      "#{inspect(module)}: #{signal(hd(matches), behaviours)}",
      "The process is suspended and #{callbacks(arities(matches))} is called with Extra = [].",
      "Nothing can derive Extra: what a migration needs is the author's to choose, and [] is",
      "what a draft can say."
    ] ++ ambiguous(module, matches)
  end

  defp callbacks([arity]), do: "code_change/#{arity}"
  defp callbacks(arities), do: "code_change/" <> Enum.join(arities, " or code_change/")

  defp arities(matches),
    do: matches |> Enum.map(&code_change_arity/1) |> Enum.uniq() |> Enum.sort()

  # A module declaring two different advanced behaviours is ambiguous about which
  # one drives the process, and nothing in a beam says which. `release_handler`
  # asks the *process*, through `sys:change_code`, and gets whatever that
  # process's behaviour module requires - so the arity that will be called is
  # decided at run time and not here.
  defp ambiguous(_module, [_only]), do: []

  defp ambiguous(module, matches) do
    [
      "",
      "#{inspect(module)} declares more than one behaviour that migrates state:",
      "#{list(matches)}. Which one drives the running process is not visible in a beam -",
      "release_handler asks the process, so the callback that gets called is whichever its",
      "behaviour module requires."
    ]
  end

  # The row that carries the most risk, so it is the one that says the most. A
  # `load_module` swaps the code and calls nothing: no suspend, no
  # `code_change/3`. For a module with no process behind it that is exactly
  # right, and for a stateful process built on a behaviour this table does not
  # know about - `GenStage`, or anything else out of a library - it is not
  # enough, and only the author can say so.
  defp plain_comment(module, []) do
    [
      "#{inspect(module)}: its Attr chunk declares no behaviour, so its code is swapped",
      "with nothing suspended and no state migrated."
    ]
  end

  defp plain_comment(module, behaviours) do
    [
      "#{inspect(module)}: declares #{list(behaviours)}, none of which is a behaviour whose",
      "state release_handler migrates, so its code is swapped with nothing suspended and",
      "no state migrated. If this module holds state that has to change shape, a",
      "load_module is not enough and only you can say what it needs instead."
    ]
  end

  # Which behaviour decided it, and what else the module declares. Naming the
  # rest is what makes the choice visible where a module carries more than one -
  # the alternative is a reader who cannot tell that anything was chosen.
  defp signal(match, [_only]), do: "behaviour #{inspect(match)}."

  defp signal(match, behaviours) do
    "declares #{list(behaviours)}; classified on #{inspect(match)}."
  end

  defp list(behaviours), do: Enum.map_join(behaviours, ", ", &inspect/1)

  # What has to be said about the entry as a whole. Emitted only where it applies,
  # so that an entry with one instruction in it does not carry a paragraph about
  # an ordering that cannot arise.
  defp preamble([], _new) do
    [
      "No module moved between these two builds. The entry is here because :systools",
      "selects one by from-version and make_relup/4 refuses an edge that has none - an",
      "empty script is the instruction that nothing has to be loaded, not an omission."
    ]
  end

  defp preamble(instructions, new) do
    updates? = Enum.any?(instructions, &match?({{:update, _module, _change}, _comments}, &1))
    ordered? = length(instructions) > 1

    [unlisted(new), supervision(updates?), ordering(ordered?)]
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([""])
    |> Enum.concat()
  end

  # Said once about the build rather than against every instruction: an
  # application resource whose `modules` value `:systools` will not accept
  # resolves nothing at all, so nothing below can be carried whatever it says.
  # `systools_make:check_item/2` refuses such a value as a missing_param or a
  # bad_param before it builds anything, and `mix castle.appup` reports it as a
  # gap for the same reason.
  defp unlisted(%{listed?: false}) do
    [
      "The new build's .app has no modules list :systools will accept - it is missing, or",
      "it is not a list of atoms. systools_rc resolves object code through that list, so no",
      "instruction below can be carried until the resource is fixed."
    ]
  end

  defp unlisted(_new), do: []

  defp supervision(false), do: []

  defp supervision(true) do
    [
      "update only reaches processes found through the supervision tree. A process nobody",
      "supervises keeps its old code, silently, and this entry will look as though it",
      "covered it."
    ]
  end

  defp ordering(false), do: []

  defp ordering(true) do
    [
      "Ordering is stable, not correct: add_module comes first and delete_module last,",
      "which is the decidable part. DepMods between changed modules is not computed, so",
      "nothing here orders two changed modules against each other."
    ]
  end
end
