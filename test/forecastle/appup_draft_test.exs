defmodule Forecastle.AppupDraftTest do
  @moduledoc """
  The decision table, against module attributes rather than against a release.

  `Forecastle.Appup.Draft` needs nothing from a build but the module map
  `Forecastle.Build` produces - `%{module => {md5, attributes}}` - so the whole
  table can be exercised on maps built here, which is what lets this suite cover
  the rows the fixture has no module for. The e2e half is
  `Forecastle.AppupGenTest`.

  **Two things here are measured rather than stated, and both are the reason a
  row of the table exists.** The `code_change/3` case compiles real modules,
  because the point of it is that a module Elixir injected one into and a module
  that hand-wrote one are indistinguishable by their exports - so a fixture that
  hand-wrote the attribute list would be asserting the classifier's own
  assumption back at it. The American `-behavior` spelling compiles real Erlang
  for the same reason: that the attribute *key* keeps the spelling the source
  used is a property of the Erlang compiler, not of this code.
  """

  use ExUnit.Case, async: true

  alias Forecastle.Appup.Draft

  @from "0.1.0"

  describe "the decision table" do
    test "a changed GenServer gets an advanced update, in both spellings" do
      for behaviour <- [GenServer, :gen_server] do
        assert [{{:update, Mod, {:advanced, []}}, _comments}] =
                 instructions(changed(Mod, behaviour: [behaviour]))
      end
    end

    test "the other three gen_* behaviours get an advanced update too" do
      for behaviour <- [:gen_statem, :gen_event, :gen_fsm] do
        assert [{{:update, Mod, {:advanced, []}}, _comments}] =
                 instructions(changed(Mod, behaviour: [behaviour]))
      end
    end

    test "a changed supervisor gets a supervisor update, in both spellings" do
      for behaviour <- [Supervisor, :supervisor] do
        assert [{{:update, Mod, :supervisor}, _comments}] =
                 instructions(changed(Mod, behaviour: [behaviour]))
      end
    end

    test "a changed module with no behaviour gets a load_module" do
      assert [{{:load_module, Mod}, _comments}] = instructions(changed(Mod, []))
    end

    test "a changed module with a behaviour that is not in the table gets a load_module" do
      # `Application` and `Config.Provider` are behaviours whose state
      # `release_handler` does not migrate, and there is nothing to suspend.
      assert [{{:load_module, Mod}, _comments}] =
               instructions(changed(Mod, behaviour: [Application]))
    end

    test "a module carrying both is drafted as a supervisor, and the comment names both" do
      # Reachable in ordinary code: `use GenServer` beside `@behaviour Supervisor`
      # compiles to `behaviour: [GenServer, Supervisor]`. Supervisor is the
      # conservative choice - a supervisor upgraded as a plain gen_server has its
      # child specs left alone silently - and the comment has to make the choice
      # visible rather than leave it implied.
      assert [{{:update, Mod, :supervisor}, comments}] =
               instructions(changed(Mod, behaviour: [GenServer, Supervisor]))

      text = Enum.join(comments, " ")

      assert text =~ "GenServer"
      assert text =~ "Supervisor"
      assert text =~ "classified on"
    end

    test "an added module is an add_module whatever it implements" do
      old = side(%{})
      new = side(%{Mod => {"a", [behaviour: [GenServer]]}})

      assert [{{:add_module, Mod}, _comments}] = instructions({old, new})
    end

    test "a removed module is a delete_module whatever it implemented" do
      old = side(%{Mod => {"a", [behaviour: [Supervisor]]}})
      new = side(%{})

      assert [{{:delete_module, Mod}, _comments}] = instructions({old, new})
    end
  end

  describe "the signal" do
    test "is the behaviour and not code_change/3 being exported" do
      # The trap this row of the table exists for. Every `use GenServer` module
      # exports `code_change/3` because Elixir injects an overridable one, and a
      # module that hand-writes one without declaring a behaviour exports exactly
      # the same function - so a classifier reading exports would call the second
      # a gen_server. Compiled here rather than described, because the whole
      # claim is about what the compiler produces.
      [injected, handwritten] =
        compiled("""
        defmodule Probe.Injected do
          use GenServer
          def init(a), do: {:ok, a}
        end

        defmodule Probe.Handwritten do
          def code_change(_old, state, _extra), do: {:ok, state}
        end
        """)

      assert function_exported?(Probe.Injected, :code_change, 3)
      assert function_exported?(Probe.Handwritten, :code_change, 3)

      assert [{{:update, Probe.Injected, {:advanced, []}}, _up}] = instructions(changed(injected))
      assert [{{:load_module, Probe.Handwritten}, _down}] = instructions(changed(handwritten))
    end

    test "is read under the American attribute key too" do
      # Measured on OTP 28.3: the Erlang compiler keeps the spelling the source
      # used, so `-behavior(gen_server).` is stored under the key `behavior` and
      # `-behaviour(...)` under `behaviour`. An Erlang dependency is exactly
      # where the American spelling turns up, and reading only one of them would
      # classify such a module as a plain `load_module`.
      american = erlang_module(:draft_american, :behavior)
      british = erlang_module(:draft_british, :behaviour)

      assert {:behavior, [:gen_server]} in elem(american, 1)
      assert {:behaviour, [:gen_server]} in elem(british, 1)

      assert [{{:update, :draft_american, {:advanced, []}}, _a}] =
               instructions(changed_named(:draft_american, american))

      assert [{{:update, :draft_british, {:advanced, []}}, _b}] =
               instructions(changed_named(:draft_british, british))
    end

    test "is the side being moved to, not the side being moved from" do
      # `release_handler` calls `code_change/3` on the code that will be running
      # afterwards, so a module that stops being a GenServer needs no suspend on
      # the way up - and needs one on the way down, where the GenServer is what
      # it becomes.
      old = side(%{Mod => {"a", [behaviour: [GenServer]]}})
      new = side(%{Mod => {"b", []}})

      assert [{{:load_module, Mod}, _up}] = instructions({old, new})
      assert [{{:update, Mod, {:advanced, []}}, _down}] = instructions({new, old})
    end
  end

  describe "an advanced update on a module that exports no code_change" do
    test "says so, and says the install fails with undef until one is written" do
      # Raised in review, and measured on OTP 28 before it was acted on: a
      # `@behaviour GenServer` module with no `code_change/3` answers
      # `{error, {'EXIT', {undef, ...}}}` to `sys:change_code/4`, and
      # `release_handler_1` matches `ok = sys:change_code(...)`. §3.3's "safe
      # whether or not a code_change/3 was written" holds for `use GenServer`
      # and for nothing else.
      old = side(%{Mod => {"a", [behaviour: [GenServer]]}}, nil, %{Mod => none()})
      new = side(%{Mod => {"b", [behaviour: [GenServer]]}}, nil, %{Mod => none()})

      assert [{{:update, Mod, {:advanced, []}}, comments}] = instructions({old, new})

      text = Enum.join(comments, " ")

      assert text =~ "exports NO code_change/3"
      assert text =~ "undef"
    end

    test "says nothing when the callback is there" do
      assert [{{:update, Mod, {:advanced, []}}, comments}] =
               instructions(changed(Mod, behaviour: [GenServer]))

      refute Enum.join(comments, " ") =~ "exports NO"
    end

    test "asks for arity 4 where the behaviour calls code_change/4" do
      # `gen_statem` and `gen_fsm` call `Mod:code_change/4`, with the state and
      # the data apart, so a module exporting only the gen_server arity has none
      # of the callback that will actually be called.
      only_three = %{Mod => MapSet.new([{:code_change, 3}])}
      old = side(%{Mod => {"a", [behaviour: [:gen_statem]]}}, nil, only_three)
      new = side(%{Mod => {"b", [behaviour: [:gen_statem]]}}, nil, only_three)

      assert [{{:update, Mod, {:advanced, []}}, comments}] = instructions({old, new})

      assert Enum.join(comments, " ") =~ "exports NO code_change/4"
    end

    test "asks for every arity the module's behaviours need, not just the first" do
      # Raised in review. A module declaring `:gen_statem` and `GenServer`
      # needs `code_change/4` for one and `code_change/3` for the other, and
      # which of the two the running process asks for is decided at run time -
      # so exporting one of them is not enough. Checking only the behaviour that
      # decided the instruction passed this silently.
      only_four = %{Mod => MapSet.new([{:code_change, 4}])}
      both = [behaviour: [:gen_statem, GenServer]]
      old = side(%{Mod => {"a", both}}, nil, only_four)
      new = side(%{Mod => {"b", both}}, nil, only_four)

      assert [{{:update, Mod, {:advanced, []}}, comments}] = instructions({old, new})

      text = Enum.join(comments, " ")

      assert text =~ "exports NO code_change/3"
      refute text =~ "exports NO code_change/4"

      # And the ambiguity itself is said, because nothing in a beam says which
      # behaviour drives the process.
      assert text =~ "declares more than one behaviour that migrates state"
    end

    test "does not ask a supervisor for one at all" do
      # `supervisor:system_code_change/4` re-reads `init/1` and calls no
      # `code_change`, so the export says nothing about a supervisor update.
      old = side(%{Mod => {"a", [behaviour: [Supervisor]]}}, nil, %{Mod => none()})
      new = side(%{Mod => {"b", [behaviour: [Supervisor]]}}, nil, %{Mod => none()})

      assert [{{:update, Mod, :supervisor}, comments}] = instructions({old, new})

      refute Enum.join(comments, " ") =~ "exports NO"
    end
  end

  describe "against real beams read through Forecastle.Build" do
    @describetag :tmp_dir

    test "the missing-callback note follows the beam that really lacks the callback", ctx do
      # **Every other case in this suite hands `Draft` a side built by hand, so
      # none of them exercises the read that produces one.** Raised in review: a
      # regression where `Forecastle.Build` misread the `ExpT` chunk, or
      # associated one module's exports with another's, would pass all of them.
      # So this one goes through `Build.side!/2` against real beams in a real
      # `ebin`, and asserts the note lands on exactly one of two modules that
      # differ only in whether the callback is there.
      old = ebin!(ctx, "0.1.0")
      new = ebin!(ctx, "0.1.1")

      from = Forecastle.Build.side!(old, :probe_app)
      to = Forecastle.Build.side!(new, :probe_app)

      assert Forecastle.Build.exports?(to, Probe.Real.Injected, :code_change, 3)
      refute Forecastle.Build.exports?(to, Probe.Real.Declared, :code_change, 3)

      notes =
        Map.new(Draft.entry("0.1.0", from, to).instructions, fn {instruction, comments} ->
          {elem(instruction, 1), Enum.join(comments, " ")}
        end)

      assert notes[Probe.Real.Declared] =~ "exports NO code_change/3"
      refute notes[Probe.Real.Injected] =~ "exports NO code_change"
    end

    # Two modules that differ only in how they come by `code_change/3`: one
    # through `use GenServer`, which injects an overridable one, and one through
    # `@behaviour GenServer`, which does not. Both are `behaviour: [GenServer]`
    # in the `Attr` chunk, so the *only* thing that can tell them apart is the
    # export table - which is exactly the read under test.
    #
    # The version tag makes the two builds differ, so both modules are `changed`.
    defp ebin!(ctx, vsn) do
      ebin = Path.join([ctx.tmp_dir, vsn, "probe_app-#{vsn}", "ebin"])
      File.mkdir_p!(ebin)

      source = """
      defmodule Probe.Real.Injected do
        @vsn "#{vsn}"
        use GenServer
        def init(a), do: {:ok, a}
      end

      defmodule Probe.Real.Declared do
        @vsn "#{vsn}"
        @behaviour GenServer
        def init(a), do: {:ok, a}
        def handle_call(_m, _f, s), do: {:reply, :ok, s}
        def handle_cast(_m, s), do: {:noreply, s}
      end
      """

      # The two builds define the same module names, and `Code.compile_string/1`
      # loads what it compiles - so without this the second call warns about
      # redefining a module that is loaded, and a warning in a passing suite is
      # what hides the next real one.
      for module <- [Probe.Real.Injected, Probe.Real.Declared] do
        :code.purge(module)
        :code.delete(module)
      end

      modules =
        for {module, binary} <- Code.compile_string(source) do
          File.write!(Path.join(ebin, "#{module}.beam"), binary)
          module
        end

      resource = {:application, :probe_app, [vsn: to_charlist(vsn), modules: modules]}
      File.write!(Path.join(ebin, "probe_app.app"), :io_lib.format(~c"~tp.~n", [resource]))

      ebin
    end
  end

  describe "a module whose behaviour role changed" do
    test "is drafted for what it becomes, and the change is said" do
      # Raised in review. The classification is the side being moved *to*,
      # because that is the code that will be running - but the process running
      # now was started by the old code, and an instruction only swaps code under
      # it. Neither direction is mechanically decidable, so both are said.
      genserver = side(%{Mod => {"a", [behaviour: [GenServer]]}})
      plain = side(%{Mod => {"b", []}})

      assert [{{:load_module, Mod}, up}] = instructions({genserver, plain})
      assert [{{:update, Mod, {:advanced, []}}, down}] = instructions({plain, genserver})

      assert Enum.join(up, " ") =~ "changed behaviour role between the two builds"
      assert Enum.join(up, " ") =~ "was: a process with migratable state"
      assert Enum.join(down, " ") =~ "now: a process with migratable state"
      assert Enum.join(up, " ") =~ "yours to decide"
    end

    test "says nothing when only the spelling of the behaviour changed" do
      # `GenServer` and `:gen_server` are one row of the table, so a module that
      # swapped one for the other did not change role.
      old = side(%{Mod => {"a", [behaviour: [GenServer]]}})
      new = side(%{Mod => {"b", [behaviour: [:gen_server]]}})

      assert [{{:update, Mod, {:advanced, []}}, comments}] = instructions({old, new})

      refute Enum.join(comments, " ") =~ "changed behaviour role"
    end

    test "says nothing when the role is the same" do
      assert [{{:update, Mod, :supervisor}, comments}] =
               instructions(changed(Mod, behaviour: [Supervisor]))

      refute Enum.join(comments, " ") =~ "changed behaviour role"
    end
  end

  describe "ordering" do
    test "is add_module, then the changed modules, then delete_module" do
      old =
        side(%{
          Kept => {"a", []},
          Gone => {"a", []},
          Same => {"a", []}
        })

      new =
        side(%{
          Kept => {"b", []},
          New => {"a", []},
          Same => {"a", []}
        })

      assert [
               {{:add_module, New}, _one},
               {{:load_module, Kept}, _two},
               {{:delete_module, Gone}, _three}
             ] = instructions({old, new})
    end
  end

  describe "what it says rather than decides" do
    test "an advanced update says the Extra term is [] and nothing derives it" do
      [{_instruction, comments}] = instructions(changed(Mod, behaviour: [GenServer]))
      text = Enum.join(comments, " ")

      assert text =~ "Extra = []"
      assert text =~ "Nothing can derive Extra"
    end

    test "a supervisor update says it reconciles specs and does not upgrade the children" do
      [{_instruction, comments}] = instructions(changed(Mod, behaviour: [Supervisor]))
      text = Enum.join(comments, " ")

      assert text =~ "child *specs*"
      assert text =~ "does not upgrade the"
    end

    test "an entry with an update says update only reaches supervised processes" do
      entry =
        Draft.entry(
          @from,
          elem(changed(Mod, behaviour: [GenServer]), 0),
          elem(changed(Mod, behaviour: [GenServer]), 1)
        )

      assert Enum.join(entry.preamble, " ") =~ "supervision tree"
    end

    test "an entry with more than one instruction says the ordering is stable, not correct" do
      old = side(%{A => {"a", []}})
      new = side(%{A => {"b", []}, B => {"a", []}})
      entry = Draft.entry(@from, old, new)

      assert Enum.join(entry.preamble, " ") =~ "Ordering is stable, not correct"
      assert Enum.join(entry.preamble, " ") =~ "DepMods"
    end

    test "an entry with one instruction says nothing about ordering" do
      entry = Draft.entry(@from, elem(changed(Mod, []), 0), elem(changed(Mod, []), 1))

      refute Enum.join(entry.preamble, " ") =~ "Ordering"
    end

    test "every drafted instruction carries a comment" do
      old = side(%{A => {"a", []}, B => {"a", [behaviour: [GenServer]]}, C => {"a", []}})
      new = side(%{A => {"b", []}, B => {"b", [behaviour: [Supervisor]]}, D => {"a", []}})

      for {instruction, comments} <- Draft.entry(@from, old, new).instructions do
        refute comments == [], "#{inspect(instruction)} was drafted with no comment"

        # A `""` is a paragraph break within the block, so one is allowed between
        # lines and not at either end - a leading or trailing one renders as a
        # bare `#` against nothing.
        refute List.first(comments) == "", "#{inspect(instruction)} leads with a blank comment"
        refute List.last(comments) == "", "#{inspect(instruction)} ends with a blank comment"
      end
    end

    test "a module the new .app does not name is drafted with the reason it cannot work" do
      # `systools_rc:get_lib/2` resolves object code through `#application.modules`,
      # so an instruction naming a module no application in the release lists is a
      # `no_such_module` and the whole relup fails. The instruction is still
      # drafted - leaving it out would produce an appup that builds a relup and
      # leaves the module running its old code, which is the failure this tooling
      # exists to catch - but the draft has to say the fix is the `.app`.
      old = side(%{Mod => {"a", []}})
      new = side(%{Mod => {"b", []}}, [])

      assert [{{:load_module, Mod}, comments}] = instructions({old, new})

      text = Enum.join(comments, " ")

      assert text =~ "NOT in the modules list"
      assert text =~ "no_such_module"
    end

    test "a module the new .app does name is drafted without that note" do
      assert [{{:load_module, Mod}, comments}] = instructions(changed(Mod, []))

      refute Enum.join(comments, " ") =~ "no_such_module"
    end

    test "a .app systools refuses outright says so once, not against every instruction" do
      # The inventory read from such a resource is empty, so a per-instruction
      # note would repeat itself for the whole application and would say the
      # wrong thing: the module is not missing from the list, the list is
      # unusable.
      old = side(%{A => {"a", []}, B => {"a", []}})
      new = unlisted(%{A => {"b", []}, B => {"b", []}})
      entry = Draft.entry(@from, old, new)

      assert Enum.join(entry.preamble, " ") =~ "no modules list :systools will accept"

      for {_instruction, comments} <- entry.instructions do
        refute Enum.join(comments, " ") =~ "NOT in the modules list"
      end
    end

    test "a delete_module gets no resolution note, because it loads nothing" do
      # `delete_module` translates to a `remove` and a `purge`, neither of which
      # goes through `get_lib/2`, so the old side's `.app` has nothing to say
      # about it.
      old = side(%{Gone => {"a", []}}, [])
      new = side(%{})

      assert [{{:delete_module, Gone}, comments}] = instructions({old, new})

      refute Enum.join(comments, " ") =~ "no_such_module"
    end

    test "an empty diff is an entry with an empty script that says why it is empty" do
      # The case that must not be a silent success: nothing moved, so there is no
      # instruction to draft - but :systools selects an entry by from-version and
      # refuses an edge that has none, so the entry is still required. The
      # comment is what stops an empty script reading as an omission.
      entry = Draft.entry(@from, side(%{A => {"a", []}}), side(%{A => {"a", []}}))

      assert entry.instructions == []

      text = Enum.join(entry.preamble, " ")

      assert text =~ "No module moved"
      assert text =~ "make_relup/4 refuses an edge that has none"
    end
  end

  ## Building the two sides

  defp instructions({old, new}), do: Draft.entry(@from, old, new).instructions

  # The `.app` inventory defaults to the beams, which is what an ordinary build
  # produces: `Mix.Tasks.Compile.App` derives `:modules` from the compiled
  # modules and only fills it in with `put_new_lazy/3`. The case about the two
  # disagreeing passes its own.
  # The `.app` inventory defaults to the beams, and every module defaults to
  # exporting `code_change` at both arities - which is what a `use GenServer`
  # module has and what keeps the missing-callback note out of every case that is
  # about something else. The cases that are about it pass their own.
  defp side(modules, inventory \\ nil, exports \\ nil) do
    %{
      modules: modules,
      inventory: MapSet.new(inventory || Map.keys(modules)),
      listed?: true,
      exports: exports || Map.new(modules, &{elem(&1, 0), both_arities()})
    }
  end

  defp both_arities, do: MapSet.new([{:code_change, 3}, {:code_change, 4}])

  defp none, do: MapSet.new()

  # A `.app` whose `modules` value `:systools` refuses outright, which
  # `Forecastle.Build` reads as an empty inventory paired with `listed?: false`.
  defp unlisted(modules), do: %{side(modules, []) | listed?: false}

  # One module that changed, with the attributes given. The md5 half is what
  # makes it changed and the attributes half is what classifies it.
  defp changed(module, attributes) do
    {side(%{module => {"before", attributes}}), side(%{module => {"after", attributes}})}
  end

  defp changed({module, attributes}), do: changed(module, attributes)

  defp changed_named(module, {_module, attributes}), do: changed(module, attributes)

  ## Real beams

  # `{module, attributes}` per module in the source, read the way
  # `Forecastle.Build` reads them.
  defp compiled(source) do
    for {module, binary} <- Code.compile_string(source) do
      {:ok, {^module, [attributes: attributes]}} = :beam_lib.chunks(binary, [:attributes])

      {module, attributes}
    end
  end

  # An Erlang module declaring `gen_server` under the attribute name given, built
  # from forms so that the test needs no scratch directory. The warnings are
  # about the callbacks it does not implement, which is not what is under test.
  defp erlang_module(name, attribute) do
    forms = [
      {:attribute, 1, :module, name},
      {:attribute, 2, attribute, :gen_server},
      {:attribute, 3, :export, [{:init, 1}]},
      {:function, 4, :init, 1,
       [
         {:clause, 4, [{:var, 4, :A}], [], [{:tuple, 4, [{:atom, 4, :ok}, {:var, 4, :A}]}]}
       ]}
    ]

    {:ok, ^name, binary, _warnings} =
      :compile.forms(forms, [:binary, :return_errors, :return_warnings])

    {:ok, {^name, [attributes: attributes]}} = :beam_lib.chunks(binary, [:attributes])

    {name, attributes}
  end
end
