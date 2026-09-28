defmodule Forecastle.Appup.Draft do
  @moduledoc """
  Drafts appup instructions for modules that changed between two builds.

  The draft uses BEAM behaviour attributes to choose an instruction:

  | Module | Instruction |
  | --- | --- |
  | Supervisor | `{:update, module, :supervisor}` |
  | GenServer, `:gen_server`, `:gen_statem`, `:gen_event` or `:gen_fsm` | `{:update, module, {:advanced, []}}` |
  | Other changed module | `{:load_module, module}` |
  | Added module | `{:add_module, module}` |
  | Removed module | `{:delete_module, module}` |

  Supervisor classification takes precedence when a module declares several
  behaviours. The draft comments on decisions that require review, including
  the `Extra` value, missing `code_change` callbacks, changed behaviour roles,
  unsupervised processes, child upgrades, module ordering, and modules absent
  from the application's `.app` resource.
  """

  alias Forecastle.Build

  @typedoc "An instruction and the comment lines rendered above it."
  @type annotated :: {tuple(), [binary()]}

  @typedoc """
  One from-version entry, ready to render.

  `preamble` holds comments about the entry as a whole.
  """
  @type entry :: %{from_vsn: binary(), preamble: [binary()], instructions: [annotated()]}

  # The two rows of the decision table that name a behaviour, in the order they
  # are tried. Supervisor first: see the moduledoc for why a module carrying both
  # is drafted as a supervisor rather than as a gen_server.
  @supervisor [Supervisor, :supervisor]
  @advanced [GenServer, :gen_server, :gen_statem, :gen_event, :gen_fsm]

  @doc """
  Drafts one from-version entry from two application builds.

  The result has instructions in a stable order, with review comments, for
  changed, added and removed modules.
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
      para("#{inspect(module)}: added by this transition."),
      module,
      new
    )
  end

  defp removed(module) do
    {{:delete_module, module},
     para(
       "#{inspect(module)}: removed by this transition. delete_module purges the module " <>
         "and loads nothing, so never use it for a module the target build still has."
     )}
  end

  defp changed(module, old, new) do
    was = Build.behaviours(old, module)
    now = Build.behaviours(new, module)

    # `callback/3` is asked of both `update` branches and of neither
    # `load_module`: an update is what makes `release_handler` call
    # `sys:change_code`, and a `load_module` swaps code and calls nothing. The
    # supervisor form is an advanced change with a `static` module type -
    # `expand_script/1` rewrites it to `{update, Mod, static, default,
    # {advanced, []}, …}` - so it reaches `change_code` exactly as the other one
    # does.
    {instruction, comments} =
      case classify(now) do
        {:supervisor, match} ->
          {{:update, module, :supervisor},
           supervisor_comment(module, match, now) ++ callback(module, was, new)}

        {:advanced, matches} ->
          {{:update, module, {:advanced, []}},
           advanced_comment(module, matches, now) ++ callback(module, was, new)}

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
  # **Three review rounds asked this the wrong way round before the rule was
  # stated, so state it once:**
  #
  # > The callback called on this edge is the one the **old** side's behaviour
  # > calls, on the **new** side's module.
  #
  # `sys:change_code` is a system message, and it is handled by the behaviour the
  # process was *started* under. A hot upgrade does not restart the process, so
  # that is the old code's behaviour, and it is what decides whether
  # `code_change/3` or `code_change/4` is sent. The module it is invoked on is the
  # one just loaded. Every round that got this wrong read the destination for
  # both halves:
  #
  #   * classifying on the destination alone, so a role change said nothing.
  #   * asking the destination's arity, so `GenServer` to `:gen_statem` exporting
  #     only `code_change/4` passed while a still-running `gen_server` would ask
  #     for `code_change/3`.
  #   * asking it only in the advanced branch, so `GenServer` to `Supervisor`
  #     passed - `expand_script/1` turns the supervisor form into an advanced
  #     change too, so `change_code` reaches a `use Supervisor` module that
  #     exports no `code_change/3` at all.
  #
  # One rule covers all three, and the four transitions fall out of it rather
  # than needing cases: an old side with **no** advanced behaviour requires
  # nothing, because no process is running that module under one - which is why
  # plain-to-`GenServer` and `Supervisor`-to-`GenServer` are silent, and right to
  # be. A `load_module` never reaches here at all, since it suspends nothing and
  # calls nothing.
  defp callback(module, was, new) do
    behaviours = present(was, @advanced) || []

    case Enum.reject(arities(behaviours), &Build.exports?(new, module, :code_change, &1)) do
      [] -> []
      missing -> missing_callback(module, behaviours, missing)
    end
  end

  defp missing_callback(module, behaviours, missing) do
    [
      ""
      | para(
          "WARNING: #{inspect(module)} does not export #{callbacks(missing)}, so the " <>
            "install will fail with undef. The running process was started under " <>
            "#{list(behaviours)}, which calls it on the target code. `use GenServer` " <>
            "defines a default; `@behaviour` alone and Erlang modules do not."
        )
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
        "WARNING: #{inspect(module)} changed behaviour role in this transition:",
        "  was: #{phrase(was)}",
        "  now: #{phrase(now)}"
      ] ++
        para(
          "The instruction suits the target code, but the running process was started " <>
            "by the current code. Decide what should happen to that process."
        )
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
  defp phrase(:plain), do: "a module with no supervisor or process behaviour"

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
           ""
           | para(
               "WARNING: #{inspect(module)} is missing from the modules list in the target " <>
                 "build's .app, so relup generation will fail with no_such_module. Fix the " <>
                 ".app, not this instruction."
             )
         ]}
    end
  end

  defp supervisor_comment(module, match, behaviours) do
    para(
      "#{inspect(module)}: #{signal(match, behaviours)} The update re-runs init/1 and updates the " <>
        "child specs. The children themselves are not upgraded; give them their own " <>
        "instructions."
    )
  end

  # Deliberately says nothing about whether a `code_change` is there: it cannot
  # tell a hand-written one from Elixir's injected identity, which is §3.2, and
  # `callback/3` is what says the one thing about it that *is* decidable.
  defp advanced_comment(module, matches, behaviours) do
    para(
      "#{inspect(module)}: #{signal(hd(matches), behaviours)} The update suspends the process and " <>
        "calls #{callbacks(arities(matches))} with Extra = []. Replace [] if the " <>
        "migration needs data."
    ) ++ ambiguous(module, matches)
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
      ""
      | para(
          "#{inspect(module)} declares more than one behaviour that migrates state: " <>
            "#{list(matches)}. The running process's behaviour decides which callback " <>
            "is called, and the beam does not say which that is."
        )
    ]
  end

  # The row that carries the most risk, so it is the one that says the most. A
  # `load_module` swaps the code and calls nothing: no suspend, no
  # `code_change/3`. For a module with no process behind it that is exactly
  # right, and for a stateful process built on a behaviour this table does not
  # know about - `GenStage`, or anything else out of a library - it is not
  # enough, and only the author can say so.
  defp plain_comment(module, []) do
    para("#{inspect(module)}: no behaviour. The code is replaced without suspending anything.")
  end

  defp plain_comment(module, behaviours) do
    para(
      "#{inspect(module)}: #{noun(behaviours)} #{list(behaviours)}. release_handler " <>
        "migrates no state for it, so the code is replaced without suspending anything. " <>
        "If the module holds state that changes shape, load_module is not enough."
    )
  end

  # Which behaviour decided it, and what else the module declares. Naming the
  # rest is what makes the choice visible where a module carries more than one -
  # the alternative is a reader who cannot tell that anything was chosen.
  defp signal(match, [_only]), do: "behaviour #{inspect(match)}."

  defp signal(match, behaviours) do
    "behaviours #{list(behaviours)}; drafted as #{inspect(match)}."
  end

  defp noun([_only]), do: "behaviour"
  defp noun(_behaviours), do: "behaviours"

  defp list(behaviours), do: Enum.map_join(behaviours, ", ", &inspect/1)

  # What has to be said about the entry as a whole. Emitted only where it applies,
  # so that an entry with one instruction in it does not carry a paragraph about
  # an ordering that cannot arise.
  defp preamble([], _new) do
    para(
      "No modules changed between these builds. The empty entry is still required: " <>
        "relup generation fails for a from-version with no entry."
    )
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
    para(
      "WARNING: the target build's .app has no usable modules list (it is missing, or " <>
        "not a list of atoms). No instruction below will work until the .app is fixed."
    )
  end

  defp unlisted(_new), do: []

  defp supervision(false), do: []

  defp supervision(true) do
    para(
      "An update only reaches processes in the supervision tree. An unsupervised " <>
        "process keeps running the old code."
    )
  end

  defp ordering(false), do: []

  defp ordering(true) do
    para(
      "add_module comes first and delete_module last, but changed modules are not " <>
        "ordered by dependency. Reorder them, or add DepMods, where one depends on " <>
        "another."
    )
  end

  # Comment text is written as paragraphs and wrapped here, so that lines stay
  # even whatever length the interpolated module names are.
  @width 80

  defp para(text) do
    text
    |> String.split(" ")
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | rest] ->
        if String.length(line) + 1 + String.length(word) > @width,
          do: [word, line | rest],
          else: [line <> " " <> word | rest]
    end)
    |> Enum.reverse()
  end
end
