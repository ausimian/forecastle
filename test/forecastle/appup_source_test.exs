defmodule Forecastle.AppupSourceTest do
  @moduledoc """
  Reading and rewriting an appup source file, against real files in a scratch
  directory.

  What is under test here is the line between an appup that states a term and one
  that computes it, because that line is what decides whether
  `mix castle.appup.gen` may rewrite the file at all. The cases are chosen to sit
  either side of it rather than to cover a shape each: a charlist sigil is a
  literal and a charlist sigil with a modifier is not; a tuple of literals is one
  and a tuple with one call in it is not.

  **Every case that expects a refusal is written so that it would pass against a
  rewrite too**, which is what makes it an assertion rather than a description:
  the file is read back afterwards and compared with what was there before.
  """

  use ExUnit.Case, async: true

  alias Forecastle.Appup.Source

  @moduletag :tmp_dir

  @up %{
    from_vsn: "0.1.0",
    preamble: ["Ordering is stable, not correct."],
    instructions: [
      {{:update, Sample.Counter, {:advanced, []}}, ["Sample.Counter: behaviour GenServer."]}
    ]
  }

  @down %{
    from_vsn: "0.1.0",
    preamble: ["No module moved."],
    instructions: []
  }

  describe "a file that states its appup" do
    test "reads as a literal, with the term it denotes", ctx do
      path = write!(ctx, ~s|{~c"0.1.1", [{~c"0.1.0", [{:load_module, Sample}]}], []}\n|)

      assert {:literal, literal} = Source.read(path)
      assert literal.term == {~c"0.1.1", [{~c"0.1.0", [{:load_module, Sample}]}], []}
    end

    test "reads a single-quoted charlist too", ctx do
      # Deprecated spelling, and still a plain list of integers to the parser -
      # so it needs no clause of its own and must not be refused.
      path = write!(ctx, "{'0.1.1', [{'0.1.0', []}], []}\n")

      assert {:literal, %{term: {~c"0.1.1", [{~c"0.1.0", []}], []}}} = Source.read(path)
    end

    test "reads both charlist sigils, which differ in escape processing", ctx do
      # Measured on Elixir 1.19.5: a sigil's contents reach the AST *raw*,
      # because they are handed to the sigil function unprocessed and it is the
      # function that decides. `Kernel.sigil_c/2` unescapes and
      # `Kernel.sigil_C/2` does not. Reading both the same way made every `~c`
      # carrying an escape disagree with the evaluated term and be refused.
      #
      # The assertion is against `Code.eval_string/1` rather than against a
      # literal, because what has to hold is that this reads a file the way the
      # `:appup` compiler evaluates it.
      for source <- [~S|{~c"a\nb", [], []}|, ~S|{~C"a\nb", [], []}|] do
        path = write!(ctx, source <> "\n")
        {evaluated, []} = Code.eval_string(source)

        assert {:literal, %{term: ^evaluated}} = Source.read(path)
      end
    end

    test "reads a map and a nested tuple in an Extra term", ctx do
      path = write!(ctx, ~s|{~c"1", [{~c"0", [{:update, M, {:advanced, %{a: {1, 2}}}}]}], []}\n|)

      assert {:literal, %{term: {_vsn, [{_from, [instruction]}], []}}} = Source.read(path)
      assert instruction == {:update, M, {:advanced, %{a: {1, 2}}}}
    end

    test "reads a bitstring Extra term", ctx do
      # `Extra` is an arbitrary term, so `<<1, 2>>` is an ordinary thing for an
      # appup to carry - and it parses to a `{:<<>>, …}` rather than to a plain
      # binary, so without a clause of its own the whole file read as computed
      # and the documented merge case failed on a literal. Raised in review.
      path = write!(ctx, ~s|{~c"1", [{~c"0", [{:update, M, {:advanced, <<1, "ab">>}}]}], []}\n|)

      assert {:literal, %{term: {_vsn, [{_from, [instruction]}], []}}} = Source.read(path)
      assert instruction == {:update, M, {:advanced, <<1, "ab">>}}
    end
  end

  describe "a file that computes its appup" do
    test "is refused, and the file is left alone", ctx do
      source = """
      case System.get_env("SAMPLE_VSN", "0.1.0") do
        "0.1.0" -> {~c"0.1.0", [], []}
        vsn -> {to_charlist(vsn), [{~c"0.1.0", []}], []}
      end
      """

      path = write!(ctx, source)

      assert {:computed, phrase} = Source.read(path)
      assert phrase =~ "computes its appup rather than stating one"
      assert File.read!(path) == source
    end

    test "is refused when only part of the term computes", ctx do
      # The case a shape check on the outside of the file would pass: the tuple,
      # both lists and the instruction are all literal, and one element of the
      # instruction is a call. Rewriting this would drop the call.
      path = write!(ctx, ~s|{~c"1", [{~c"0", [{:update, M, {:advanced, extra()}}]}], []}\n|)

      assert {:computed, _phrase} = Source.read(path)
    end

    test "is refused for a charlist sigil carrying a modifier", ctx do
      # `~c"0.1.0"` is a literal here and `~c"0.1.0"i` is not, because the
      # modifier is what a sigil implementation is free to act on. The two differ
      # only in that one character, which is the point of having the case.
      literal = write!(ctx, ~s|{~c"0.1.1", [], []}\n|, "literal.exs")
      modified = write!(ctx, ~s|{~c"0.1.1"i, [], []}\n|, "modified.exs")

      assert {:literal, _read} = Source.read(literal)
      assert {:computed, _phrase} = Source.read(modified)
    end

    test "is refused for a bitstring segment that is not a whole literal byte", ctx do
      # The two ways a `<<…>>` stops being something this reproduces exactly: a
      # `::` segment, which is a size, a type, or the call an interpolation
      # expands to; and an integer Elixir would truncate. Both are narrower than
      # `Macro.quoted_literal?/1`, which is the direction this is allowed to be
      # wrong in - and the first is what keeps an interpolated string refused,
      # since that parses to a `<<>>` as well.
      for extra <- ["<<1::4>>", "<<256>>", "<<x::binary>>"] do
        path = write!(ctx, ~s|{~c"1", [{~c"0", [{:update, M, {:advanced, #{extra}}}]}], []}\n|)

        assert {:computed, _phrase} = Source.read(path)
      end
    end

    test "is refused for an interpolated string", ctx do
      path = write!(ctx, ~S|{"0.1.#{1}", [], []}| <> "\n")

      assert {:computed, _phrase} = Source.read(path)
    end

    test "is refused for a file holding more than one expression", ctx do
      path = write!(ctx, "x = 1\n{~c\"0.1.1\", [], []}\n")

      assert {:computed, _phrase} = Source.read(path)
    end

    test "is what Macro.quoted_literal?/1 alone would get wrong", ctx do
      # The measurement the extra clauses in `to_term/1` exist for: a charlist
      # sigil is not a `Macro.quoted_literal?/1`, so a purity test built on that
      # function would refuse every appup written the way Elixir spells a
      # charlist since 1.15 - including the ones this task writes.
      {:ok, sigil} = Code.string_to_quoted(~s|~c"0.1.0"|)

      refute Macro.quoted_literal?(sigil)

      path = write!(ctx, ~s|{~c"0.1.1", [], []}\n|)

      assert {:literal, _read} = Source.read(path)
    end
  end

  describe "a file that is not an appup" do
    test "is refused even when it is a literal", ctx do
      path = write!(ctx, ":not_an_appup\n")

      assert {:malformed, phrase} = Source.read(path)
      assert phrase =~ "does not read as an appup"
    end

    test "is refused when an entry is not a {FromVsn, Instructions} pair", ctx do
      path = write!(ctx, ~s|{~c"0.1.1", [:nonsense], []}\n|)

      assert {:malformed, phrase} = Source.read(path)
      assert phrase =~ "{FromVsn, Instructions} pair"
    end

    test "is refused when it is not valid Elixir", ctx do
      path = write!(ctx, "{~c\"0.1.1\", [,\n")

      assert {:malformed, phrase} = Source.read(path)
      assert phrase =~ "is not valid Elixir"
    end

    test "is absent when there is no file", ctx do
      assert Source.read(Path.join(ctx.tmp_dir, "nothing.exs")) == :absent
    end

    test "a version that is not valid UTF-8 is refused before it can be printed", ctx do
      # Refused by `Forecastle.Build.fetch_vsn!/2` at the point a version enters,
      # which is what lets everything downstream take one as printable and
      # writable. Asserted here through the `.app` because that is the only way
      # such a version can arrive: `~tp` writes a charlist of codepoints, and
      # `List.to_string/1` of those is always valid.
      ebin = Path.join(ctx.tmp_dir, "probe_bad-1/ebin")
      File.mkdir_p!(ebin)

      resource = {:application, :probe_bad, [vsn: <<0xFF, 0xFE>>, modules: []]}
      File.write!(Path.join(ebin, "probe_bad.app"), :io_lib.format(~c"~w.~n", [resource]))

      assert_raise Mix.Error, ~r/not valid UTF-8/, fn ->
        Forecastle.Build.side!(ebin, :probe_bad)
      end
    end
  end

  describe "the boundary of what counts as a literal" do
    # **Three review rounds each found one more shape that was a literal and was
    # refused, and a list that grows one round at a time is a list nobody can
    # tell is finished.** So the boundary is pinned here against Elixir's own
    # predicate rather than rediscovered: `to_term/1` and
    # `Macro.quoted_literal?/1` must agree over this corpus except at the
    # exceptions named below, and each exception has a reason.
    #
    # A new shape, or a future Elixir widening its own predicate, fails this
    # instead of arriving as a review finding.
    @corpus [
      ":atom",
      "1",
      "1.5",
      "-1",
      ~s|"str"|,
      "[]",
      "[1, 2]",
      "[a: 1, b: 2]",
      "{1, 2}",
      "{1, 2, 3}",
      "{}",
      "%{a: 1}",
      "%{}",
      "<<>>",
      "<<1, 2>>",
      ~s|<<"ab", 3>>|,
      "<<1::4>>",
      "Sample.Counter",
      ~S|"a#{1}b"|,
      ~s|System.get_env("X")|,
      "1..2",
      "[{:load_module, Sample}, {:update, Foo, {:advanced, %{a: <<1>>}}}]"
    ]

    # Literals this accepts and Elixir's predicate does not, each for a reason
    # the rule covers: a charlist sigil is a *call* to that predicate, and
    # refusing one would refuse every appup written the way Elixir has spelled a
    # charlist since 1.15; and a cons cell's term is determined by the AST alone,
    # which is the rule, even though `Macro.quoted_literal?/1` does not walk one.
    @ours_only [
      ~s|~c"abc"|,
      ~s|~C"abc"|,
      "[1 | 2]",
      "[1 | [2, 3]]",
      "%{{1, 2} => [3 | 4]}",
      "[{:update, Sample.Counter, {:advanced, [1 | 2]}}]"
    ]

    # Literals by Elixir's predicate that this refuses, because their term is not
    # determined by the AST alone: a struct needs the module's compile-time
    # defaults, and `<<256>>` needs the language's truncation rule.
    @theirs_only ["%Range{first: 1, last: 2, step: 1}", "<<256>>"]

    test "agrees with Macro.quoted_literal?/1 everywhere it is not a named exception" do
      for source <- @corpus do
        {:ok, plain} = Code.string_to_quoted(source)

        assert literal?(source) == Macro.quoted_literal?(plain),
               "#{source}: to_term says #{literal?(source)}, " <>
                 "Macro.quoted_literal?/1 says #{Macro.quoted_literal?(plain)}"
      end
    end

    test "reads every accepted shape as the term it evaluates to" do
      for source <- @corpus ++ @ours_only, literal?(source) do
        {value, []} = Code.eval_string(source)

        assert Source.to_term(encoded(source)) == {:ok, value},
               "#{source} did not read as the term it evaluates to"
      end
    end

    test "the exceptions are exactly the two named sets" do
      # Asserted rather than described: if a future Elixir made a sigil a
      # `quoted_literal?`, or stopped calling a struct one, this fails and the
      # reasoning above has to be revisited rather than quietly drifting.
      for source <- @ours_only do
        {:ok, plain} = Code.string_to_quoted(source)

        assert literal?(source)
        refute Macro.quoted_literal?(plain)
      end

      for source <- @theirs_only do
        {:ok, plain} = Code.string_to_quoted(source)

        refute literal?(source)
        assert Macro.quoted_literal?(plain)
      end
    end

    defp literal?(source), do: match?({:ok, _term}, Source.to_term(encoded(source)))

    defp encoded(source) do
      {:ok, ast} =
        Code.string_to_quoted(source,
          literal_encoder: fn literal, meta -> {:ok, {:__block__, meta, [literal]}} end,
          token_metadata: true,
          columns: true,
          emit_warnings: false
        )

      ast
    end
  end

  describe "what gets evaluated" do
    test "a source that computes is never evaluated", ctx do
      # The promise the module makes: evaluation happens only after the AST has
      # read as a literal, so nothing arbitrary is run on a file it refused. The
      # marker is the discriminator - a refusal that had evaluated first would
      # still return `{:computed, _}`, so asserting the return value alone would
      # assert nothing about this.
      marker = Path.join(ctx.tmp_dir, "side-effect")
      path = write!(ctx, ~s|File.write!("#{marker}", "ran")\n{~c"1.0.0", [], []}\n|)

      assert {:computed, _phrase} = Source.read(path)
      refute File.exists?(marker), "a computed appup was evaluated while being classified"
    end

    test "a literal is evaluated as the bytes that were parsed", ctx do
      # `Code.eval_file/1` would open the path a second time, so the literal
      # check would apply to one set of bytes and the evaluation to another -
      # and a replacement that computes would run before the term comparison
      # could refuse it. Raised in review. The evaluation now takes the captured
      # source with the path as metadata, which `Code.eval_file/1` is defined as
      # doing anyway, so there is no second read left to race.
      #
      # What is asserted here is the observable half: the term handed back is
      # the term the captured bytes denote.
      source = ~s|{~c"1.0.0", [{~c"0.9", [{:load_module, Sample}]}], []}\n|
      path = write!(ctx, source)

      assert {:literal, literal} = Source.read(path)
      assert literal.source == source
      assert {literal.term, []} == Code.eval_string(source, [], file: path, line: 1)
    end
  end

  describe "rendering a first appup" do
    test "reads back as the term it drafted" do
      assert {:ok, text} = Source.render("0.1.1", @up, @down)

      assert Code.eval_string(text) ==
               {{~c"0.1.1", [{~c"0.1.0", [{:update, Sample.Counter, {:advanced, []}}]}],
                 [{~c"0.1.0", []}]}, []}
    end

    test "is itself a literal, so the next run can merge into it", ctx do
      # The property that makes a generated file usable twice. A renderer that
      # produced something this module could not read back would work once and
      # refuse for ever after.
      {:ok, text} = Source.render("0.1.1", @up, @down)
      path = write!(ctx, text)

      assert {:literal, _read} = Source.read(path)
    end

    test "carries the comments beside the instructions", ctx do
      {:ok, text} = Source.render("0.1.1", @up, @down)
      _path = write!(ctx, text)

      assert text =~ "# Sample.Counter: behaviour GenServer."
      assert text =~ "# Ordering is stable, not correct."
      assert text =~ "# No module moved."
      assert text =~ "Nothing can derive it."
    end
  end

  describe "merging into a literal appup" do
    test "adds the entry and leaves the existing from-versions alone", ctx do
      path = write!(ctx, ~s|{~c"0.1.1", [{~c"0.0.9", [{:load_module, Old}]}], []}\n|)
      {:literal, literal} = Source.read(path)

      assert {:ok, text} = Source.merge(literal, up: @up, down: @down)

      File.write!(path, text)

      assert {:literal, merged} = Source.read(path)

      assert merged.term ==
               {~c"0.1.1",
                [
                  {~c"0.1.0", [{:update, Sample.Counter, {:advanced, []}}]},
                  {~c"0.0.9", [{:load_module, Old}]}
                ], [{~c"0.1.0", []}]}
    end

    test "keeps every comment the file already had", ctx do
      source = """
      # a header nobody wants to lose
      {~c"0.1.1",
       [
         # this entry is hand written
         {~c"0.0.9", []}
       ],
       # nothing on the way down yet
       []}
      """

      path = write!(ctx, source)
      {:literal, literal} = Source.read(path)

      assert {:ok, text} = Source.merge(literal, up: @up, down: @down)

      for comment <- [
            "# a header nobody wants to lose",
            "# this entry is hand written",
            "# nothing on the way down yet"
          ] do
        assert text =~ comment
      end
    end

    test "adds to one direction only when the other is already covered", ctx do
      path = write!(ctx, ~s|{~c"0.1.1", [], [{~c"0.1.0", [{:load_module, Old}]}]}\n|)
      {:literal, literal} = Source.read(path)

      assert {:ok, text} = Source.merge(literal, up: @up)

      assert Code.eval_string(text) ==
               {{~c"0.1.1", [{~c"0.1.0", [{:update, Sample.Counter, {:advanced, []}}]}],
                 [{~c"0.1.0", [{:load_module, Old}]}]}, []}
    end

    test "splices correctly when a grapheme cluster sits before the bracket", ctx do
      # The splice turns a (line, column) from the tokenizer into a split of the
      # line, so the two have to be counting the same thing. Measured on Elixir
      # 1.19.5: the tokenizer counts **graphemes**, which `String.split_at/2`
      # counts too - and a codepoint split, the obvious "fix", is what breaks
      # here. `👩‍💻` is three codepoints in one grapheme and the `á` below is a
      # decomposed two; both sit before the `[` on its line.
      #
      # A wrong split cannot corrupt the file - the `[` check and the read-back
      # both refuse first - so what this pins is that a legitimate source is not
      # *refused*.
      for marker <- ["👩‍💻", "á"] do
        path = write!(ctx, ~s|{~c"1.0.0", [{~c"0.0.9-#{marker}", []}], []}\n|, "g.exs")
        {:literal, literal} = Source.read(path)

        assert {:ok, text} = Source.merge(literal, up: @up)

        {{_vsn, [added, existing], _dn}, []} = Code.eval_string(text)

        assert added == {~c"0.1.0", [{:update, Sample.Counter, {:advanced, []}}]}
        assert existing == {to_charlist("0.0.9-#{marker}"), []}
      end
    end

    test "leaves no trailing whitespace behind", ctx do
      source = "{~c\"0.1.1\",\n [\n   {~c\"0.0.9\", []}\n ],\n []}\n"
      path = write!(ctx, source)
      {:literal, literal} = Source.read(path)

      {:ok, text} = Source.merge(literal, up: @up, down: @down)

      for line <- String.split(text, "\n") do
        assert line == String.trim_trailing(line), "trailing whitespace on #{inspect(line)}"
      end
    end

    test "the result is a literal, so a third run can merge again", ctx do
      path = write!(ctx, ~s|{~c"0.1.1", [], []}\n|)
      {:literal, first} = Source.read(path)
      {:ok, text} = Source.merge(first, up: @up, down: @down)
      File.write!(path, text)

      {:literal, second} = Source.read(path)
      later = %{@up | from_vsn: "0.1.2"}

      assert {:ok, again} = Source.merge(second, up: later)
      assert {{_vsn, [{~c"0.1.2", _new}, {~c"0.1.0", _old}], _dn}, []} = Code.eval_string(again)
    end
  end

  describe "publishing" do
    test "create/2 refuses a file that appeared after it was read as absent", ctx do
      # Everything drafted was drafted on the file being absent, so a file that
      # has appeared in between is somebody else's. `:exclusive` is what refuses
      # it in the same operation that would have created it, rather than in a
      # check before one.
      path = write!(ctx, "somebody else's\n")

      assert {:error, phrase} = Source.create(path, "mine\n")
      assert phrase =~ "appeared while this was running"
      assert File.read!(path) == "somebody else's\n"
    end

    test "create/2 writes when the file really is absent", ctx do
      path = Path.join(ctx.tmp_dir, "new.exs")

      assert Source.create(path, "mine\n") == :ok
      assert File.read!(path) == "mine\n"
    end

    test "replace/2 refuses a source that changed after it was read", ctx do
      # The window between reading and writing. Narrowed rather than closed -
      # there is no compare-and-swap on a file - but the failure it prevents is
      # discarding somebody's edit without a word, and turning that into a
      # refusal costs one read.
      path = write!(ctx, ~s|{~c"0.1.1", [], []}\n|)
      {:literal, literal} = Source.read(path)

      File.write!(path, ~s|{~c"0.1.1", [{~c"0.0.1", []}], []}\n|)

      assert {:error, phrase} = Source.replace(literal, "whatever\n")
      assert phrase =~ "changed after it was read"
      assert File.read!(path) =~ "0.0.1"
    end

    test "replace/2 writes when it has not, and leaves no staging file behind", ctx do
      path = write!(ctx, ~s|{~c"0.1.1", [], []}\n|)
      {:literal, literal} = Source.read(path)

      assert Source.replace(literal, "merged\n") == :ok
      assert File.read!(path) == "merged\n"
      assert File.ls!(ctx.tmp_dir) == ["appup.exs"]
    end

    test "replace/2 leaves a staging file it did not create alone", ctx do
      # Raised in review, and it was the rule this module cites `Baseline` for:
      # a name this run *believes* is unique is not something it may act on
      # destructively. Sharing one error branch between the exclusive create and
      # everything after it meant an `:eexist` - another run holding that name -
      # deleted that run's live staging file.
      #
      # The names carry random bytes, so a collision cannot be arranged. What is
      # arranged instead is the shape that made it possible: a staging file
      # beside the target that this run did not create must survive a successful
      # publish, and nothing but the run's own may be removed.
      path = write!(ctx, ~s|{~c"0.1.1", [], []}\n|)
      squatter = path <> ".castle-deadbeefdeadbeef"
      File.write!(squatter, "somebody else's work in progress")

      {:literal, literal} = Source.read(path)

      assert Source.replace(literal, "merged\n") == :ok
      assert File.read!(path) == "merged\n"
      assert File.read!(squatter) == "somebody else's work in progress"
    end

    test "replace/2 writes through a symlink rather than over it", ctx do
      # A rename replaces a directory entry, so renaming onto a symlink replaces
      # the *link*. `File.read/1` follows it, so the merge would have been
      # computed from the shared target and then written over the link - the
      # target unchanged, the project silently no longer following it, and the
      # run reporting a successful merge. Raised in review.
      target = Path.join(ctx.tmp_dir, "shared.exs")
      File.write!(target, ~s|{~c"0.1.1", [], []}\n|)

      link = Path.join(ctx.tmp_dir, "appup.exs")
      File.rm(link)
      File.ln_s!(target, link)

      {:literal, literal} = Source.read(link)

      assert Source.replace(literal, "merged\n") == :ok

      # The link is still a link, and what it names is what changed.
      assert {:ok, ^target} = File.read_link(link)
      assert File.read!(target) == "merged\n"
    end

    test "replace/2 keeps the file's mode" do
      # The rename replaces the inode, so a source somebody had made
      # group-writable for a shared checkout would otherwise come back with this
      # run's umask instead.
      dir = Path.join(System.tmp_dir!(), "forecastle-mode-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      path = Path.join(dir, "appup.exs")
      File.write!(path, ~s|{~c"0.1.1", [], []}\n|)
      File.chmod!(path, 0o640)

      {:literal, literal} = Source.read(path)

      assert Source.replace(literal, "merged\n") == :ok
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o777) == 0o640
    end
  end

  describe "the diff" do
    test "shows the added lines and nothing else", ctx do
      source = "{~c\"0.1.1\",\n [\n   {~c\"0.0.9\", []}\n ],\n []}\n"
      path = write!(ctx, source)
      {:literal, literal} = Source.read(path)
      {:ok, text} = Source.merge(literal, up: @up)

      lines = Source.diff(source, text)
      added = for "+ " <> line <- lines, do: line
      removed = for "- " <> line <- lines, do: line

      assert removed == []
      assert Enum.any?(added, &(&1 =~ "Sample.Counter"))
    end

    test "marks every run of unchanged lines it elides" do
      # A diff that silently dropped the head of the file would read as though
      # the change were at the top of it, which is the one thing a diff must not
      # do: the whole point of printing it is that the reader can see where the
      # entry landed.
      head = Enum.map_join(1..20, "\n", &"line #{&1}")
      tail = Enum.map_join(1..20, "\n", &"tail #{&1}")

      lines = Source.diff(head <> "\n" <> tail, head <> "\nADDED\n" <> tail)

      assert List.first(lines) == "  ..."
      assert List.last(lines) == "  ..."
      assert "+ ADDED" in lines
    end

    test "elides nothing when there is nothing to elide" do
      lines = Source.diff("a\nb\n", "a\nADDED\nb\n")

      refute "  ..." in lines
      assert "+ ADDED" in lines
    end
  end

  defp write!(ctx, source, name \\ "appup.exs") do
    path = Path.join(ctx.tmp_dir, name)
    File.write!(path, source)

    path
  end
end
