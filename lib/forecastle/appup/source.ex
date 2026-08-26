defmodule Forecastle.Appup.Source do
  @moduledoc """
  Reading and rewriting an appup **source** file - the one named by the `:appup`
  project key, which a person reviews and commits.

  `Forecastle.Appup` reads the compiled `<app>.appup`, which is a term.  This
  reads the `.exs` it was compiled from, which is *arbitrary Elixir evaluated for
  its value*, and that difference is the whole of what this module is about.

  ## An appup source is a program, so the only safe rewrite is of one that is not

  `Mix.Tasks.Compile.Appup` evaluates the file with `Code.eval_file/1` and writes
  whatever comes back. The fixture in this repository is a `case` on an
  environment variable; a real one might key off `Mix.env/0`, read the version
  out of `mix.exs`, or build its instruction list with a comprehension.
  Flattening any of those into a static term would silently discard the logic -
  the file would still compile, still produce *an* appup, and no longer produce
  the one the author wrote.

  So a rewrite is offered only where the file's AST is a **pure literal**, and
  refused otherwise. `Code.string_to_quoted/2` makes that decidable, which is
  what makes the refusal exact rather than a guess about what the file looks
  like.

  **The predicate and the reader are one function, deliberately.** `to_term/1`
  either produces the term the AST denotes or answers `:error`, and "is this a
  pure literal?" is exactly "did `to_term/1` answer". There is no second
  predicate that could be wider than the reader - which is the shape a
  heuristic takes, and the shape this module exists not to have.

  What counts as a literal is written out, one clause per accepted shape, and the
  default is `:error`. That asymmetry is the same one `Forecastle.Appup.legal?/1`
  is built on: too narrow costs a refusal with the entry printed beside it, too
  wide costs a file rewritten to mean something else.

  Two shapes are accepted that `Macro.quoted_literal?/1` refuses, and both are
  measured rather than assumed:

    * **`~c"..."` and `~C"..."`**, over a string with no interpolation and no
      modifiers. Measured on Elixir 1.19.5: `~c"0.1.0"` parses to
      `{:sigil_c, meta, [{:<<>>, meta, ["0.1.0"]}, []]}`, which
      `Macro.quoted_literal?/1` answers `false` for. Refusing them would refuse
      every appup written the way Elixir 1.15 onwards spells a charlist -
      including every file this module writes - so the merge case would work only
      on files nobody writes any more.
    * a **`{:__block__, meta, [literal]}` wrapper** around each literal, which is
      not a shape of the source at all: it is what the `:literal_encoder` option
      produces, and it is asked for because it is the only way to get the
      position of a `[` and `]` out of the parser. See `merge/2`.

  A single-quoted `'0.1.0'` is a plain list of integers to the parser, so it is
  a literal without needing a clause of its own.

  ## The term is the compiler's, and the AST is what decides whether to write

  Once the AST reads as a literal, the term is taken from `Code.eval_file/1` -
  the same call `Mix.Tasks.Compile.Appup` makes, so what is merged into is what
  the build will produce - and it is compared against what `to_term/1` read. A
  disagreement is a refusal rather than a rewrite: it means one of the two is
  wrong about the file, and neither is worth acting on.

  The evaluation is safe because it happens only after the AST has been read as a
  literal. It is never run on a file this module has refused.

  ## A merge is a splice, not a re-render

  The obvious implementation - evaluate, merge the term, write the term back out
  - would take the file's comments with it, including the ones a previous run of
  `mix castle.appup.gen` wrote to say what it could not decide. Those comments
  are the point of the draft, so losing them on the next run would take the
  honesty out of the tool one generation at a time.

  So the new entry is inserted as *text*, immediately after the `[` that opens
  the `up` or `dn` list, and nothing else in the file is touched: comments,
  formatting and hand-written entries all survive byte for byte, and the printed
  diff is exactly what was added. `insertions/2` is where the position comes
  from, and why it is the opening bracket rather than the closing one.

  A text splice has to prove it did what it meant to, so it does: the result is
  parsed again, read as a literal again, and refused unless the term it denotes
  is exactly the merged term that was intended. A splice that landed in the wrong
  place cannot reach the file.
  """

  @typedoc "A source file that reads as a pure literal, and everything needed to rewrite it."
  @type t :: %{path: binary(), source: binary(), ast: Macro.t(), term: tuple()}

  @typedoc """
  What the source file at a path turned out to be.

  `:absent` is a first appup, `{:literal, t()}` one that can be merged into, and
  the other two are refusals with the phrase to report.
  """
  @type read ::
          :absent
          | {:literal, t()}
          | {:computed, binary()}
          | {:malformed, binary()}

  @doc """
  Reads an appup source file and says which of the three cases it is.

  See the moduledoc: `:absent` is written, `{:literal, _}` is merged into, and
  `{:computed, _}` and `{:malformed, _}` are refused with the drafted entry
  printed instead.
  """
  @spec read(binary()) :: read()
  def read(path) do
    case File.read(path) do
      {:ok, source} -> parse(path, source)
      {:error, :enoent} -> :absent
      {:error, reason} -> {:malformed, "could not be read: #{:file.format_error(reason)}"}
    end
  end

  defp parse(path, source) do
    case Code.string_to_quoted(source, parse_opts()) do
      {:ok, ast} -> literal(path, source, ast)
      {:error, {_meta, message, token}} -> {:malformed, "is not valid Elixir: #{message}#{token}"}
    end
  end

  defp literal(path, source, ast) do
    case to_term(ast) do
      {:ok, term} -> appup(path, source, ast, term)
      :error -> {:computed, computed_phrase()}
    end
  end

  defp computed_phrase do
    "computes its appup rather than stating one. An appup source is arbitrary Elixir " <>
      "evaluated for its value, and rewriting one that computes would discard the logic " <>
      "that decides what it produces, silently"
  end

  # The shape check is separate from the literal check and comes after it,
  # because the two say different things: one is "this file can be rewritten
  # without losing anything", the other is "this file is an appup". A literal
  # that is not an appup is refused rather than merged into, since there is no
  # `up` or `dn` list to put an entry in and inventing one would replace whatever
  # the author did mean.
  defp appup(path, source, ast, {tag, up, dn} = term)
       when (is_list(tag) or is_binary(tag)) and is_list(up) and is_list(dn) do
    if Enum.all?(up ++ dn, &entry?/1) do
      confirm(path, source, ast, term)
    else
      {:malformed,
       "does not read as an appup: every element of the up and dn lists has to be a " <>
         "{FromVsn, Instructions} pair"}
    end
  end

  defp appup(_path, _source, _ast, term) do
    {:malformed,
     "does not read as an appup: expected {Vsn, Up, Dn} with two lists, but got " <>
       "#{inspect(term, limit: 5)}"}
  end

  defp entry?({vsn, script}) when (is_list(vsn) or is_binary(vsn)) and is_list(script), do: true
  defp entry?(_element), do: false

  # **The term this hands back is the compiler's, and reading the AST is what
  # decides whether the file may be rewritten at all.** Evaluating happens only
  # once the AST has read as a literal, so nothing arbitrary is ever run - and
  # comparing the two answers means a disagreement between them is a refusal
  # rather than a rewrite of a file one of them misread.
  #
  # **The bytes evaluated are the bytes that were checked, not the path.**
  # Raised in review. `Code.eval_file/1` opens the file again, so a source
  # replaced between the read and this call would have the literal check applied
  # to the old bytes and arbitrary code run from the new ones - and the term
  # mismatch below would refuse *after* those side effects, which is not the
  # promise this module makes. `Code.eval_file/1` is defined as
  # `eval_string(File.read!(file), [], file: file, line: 1)`, so passing the
  # captured source with the path as metadata is the same evaluation with the
  # second read taken out; measured, including the file and line a raise reports.
  defp confirm(path, source, ast, term) do
    case Code.eval_string(source, [], file: path, line: 1) do
      {^term, []} ->
        {:literal, %{path: path, source: source, ast: ast, term: term}}

      {_other, _binding} ->
        {:malformed,
         "reads as a literal but does not evaluate to the term it denotes, so nothing here " <>
           "can be sure what it means"}
    end
  rescue
    error -> {:malformed, "could not be evaluated: #{Exception.message(error)}"}
  end

  ## Reading a literal

  # `:literal_encoder` wraps every literal in a `{:__block__, meta, [literal]}`
  # so that it carries position metadata, which is the only way to find the `[`
  # and `]` of a list in the source. `token_metadata` is what puts `:closing` in
  # that metadata, and `columns` is what makes it usable.
  #
  # `emit_warnings: false` because this is called more than once on one file - on
  # the way in, and again on what a write would produce - and a deprecation
  # warning about the file's own spelling of a charlist is worth exactly one
  # mention per run. `Code.eval_file/1` gives it that mention for a file read as
  # a literal, and a file that computes is never evaluated at all, so its warning
  # is left to the `:appup` compiler that reads it next.
  defp parse_opts do
    [
      literal_encoder: fn literal, meta -> {:ok, {:__block__, meta, [literal]}} end,
      token_metadata: true,
      columns: true,
      emit_warnings: false
    ]
  end

  @doc """
  The term an AST denotes, or `:error` if it denotes anything that has to be
  computed.

  This is both the reader and the predicate - see the moduledoc for why they are
  one function. Every accepted shape is written out and the default is `:error`.
  """
  @spec to_term(Macro.t()) :: {:ok, term()} | :error
  def to_term({:__block__, _meta, [child]}), do: to_term(child)

  # An alias is a literal: it denotes one atom, `Module.concat/1` of its
  # segments, and that is what evaluating it produces. `Macro.quoted_literal?/1`
  # agrees. A segment that is not an atom - `x.Foo`, an `unquote` - is not one,
  # and falls through.
  def to_term({:__aliases__, _meta, segments}) do
    if Enum.all?(segments, &is_atom/1), do: {:ok, Module.concat(segments)}, else: :error
  end

  # `~c` and `~C` over a string with no interpolation and no modifiers. The
  # `{:<<>>, _, [binary]}` shape is a string with nothing interpolated into it -
  # an interpolation puts a `::` node in that list, and a modifier puts a
  # non-empty charlist in the second argument. Both fall through.
  #
  # **The two differ in whether the text has been through escape processing, and
  # the parser does neither of them for you.** Measured on Elixir 1.19.5:
  # `~c"a\\nb"` and `~C"a\\nb"` both arrive as the raw four characters, because a
  # sigil's contents are handed to the sigil function unprocessed and it is the
  # function that decides. `Kernel.sigil_c/2` unescapes and `Kernel.sigil_C/2`
  # does not, so `~c"a\\nb"` evaluates to `[97, 10, 98]` and `~C"a\\nb"` to
  # `[97, 92, 110, 98]`. Reading both the same way made every `~c` carrying an
  # escape disagree with `Code.eval_file/1` and so be refused - which
  # `confirm/4` caught, but as a file this would not merge rather than as a file
  # it merged wrongly.
  #
  # `Macro.unescape_string/1` is the same processing the sigil applies. An escape
  # it cannot make sense of falls through to a refusal rather than to a guess.
  def to_term({:sigil_c, _meta, [{:<<>>, _bin_meta, [text]}, []]}) when is_binary(text) do
    {:ok, to_charlist(Macro.unescape_string(text))}
  rescue
    _unescapable -> :error
  end

  def to_term({:sigil_C, _meta, [{:<<>>, _bin_meta, [text]}, []]}) when is_binary(text) do
    {:ok, to_charlist(text)}
  end

  # A bitstring written in `<<…>>` syntax. `Extra` is an arbitrary term, so
  # `{:advanced, <<1, 2>>}` is a perfectly ordinary thing for an appup to carry -
  # and without this it read as computed and the file was refused, which is the
  # documented merge case failing on a literal. Raised in review.
  #
  # **Only whole bytes, and only literal ones.** A segment carrying a `::` - a
  # size, a type, or the `Kernel.to_string/1` call an interpolation expands to -
  # is not a literal and falls through, which is what keeps an interpolated
  # string refused: that parses to a `<<>>` too. An integer outside `0..255`
  # falls through as well: Elixir truncates it, with a warning, and reproducing a
  # truncation rule by hand is the kind of modelling this module refuses
  # elsewhere. Both are narrower than `Macro.quoted_literal?/1`, which is the
  # direction this is allowed to be wrong in.
  def to_term({:<<>>, _meta, segments}) do
    Enum.reduce_while(segments, {:ok, <<>>}, fn segment, {:ok, acc} ->
      case to_term(segment) do
        {:ok, byte} when is_integer(byte) and byte in 0..255 ->
          {:cont, {:ok, <<acc::binary, byte>>}}

        {:ok, binary} when is_binary(binary) ->
          {:cont, {:ok, <<acc::binary, binary::binary>>}}

        _computed_or_out_of_range ->
          {:halt, :error}
      end
    end)
  end

  def to_term({:{}, _meta, args}) do
    with {:ok, terms} <- all(args), do: {:ok, List.to_tuple(terms)}
  end

  def to_term({:%{}, _meta, pairs}) do
    with {:ok, terms} <- all(pairs), do: {:ok, Map.new(terms)}
  end

  def to_term({left, right}) do
    with {:ok, left} <- to_term(left), {:ok, right} <- to_term(right), do: {:ok, {left, right}}
  end

  def to_term(list) when is_list(list), do: all(list)

  def to_term(literal) when is_atom(literal) or is_number(literal) or is_binary(literal),
    do: {:ok, literal}

  def to_term(_computed), do: :error

  defp all(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case to_term(node) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  ## Writing

  @doc """
  A whole appup source file, for an application that has none.

  The header says what the file is and what the tag being a literal costs,
  because both are things a reader of a generated file needs and neither is
  visible from the term.
  """
  @spec render(binary(), Forecastle.Appup.Draft.entry(), Forecastle.Appup.Draft.entry()) ::
          {:ok, binary()} | {:error, binary()}
  def render(tag, up, dn) do
    text =
      [
        Enum.map_join(header(), "\n", &comment/1),
        "{#{charlist(tag)},",
        "[",
        entry_text(up),
        "],",
        "[",
        entry_text(dn),
        "]}"
      ]
      |> Enum.join("\n")
      |> Code.format_string!()
      |> IO.iodata_to_binary()

    verify(text <> "\n", {chars(tag), [term(up)], [term(dn)]})
  end

  defp header do
    [
      "Generated by `mix castle.appup.gen`, and source you review and commit: nothing",
      "generates an appup during assembly, and what is below is a draft of *which modules",
      "moved* rather than a decision about what happens to their state.",
      "",
      "The Extra term in every `{:advanced, Extra}` is `[]`. Nothing can derive it.",
      "",
      "The version tag below is a literal, so it names the version this was generated for.",
      "It does not follow the application's version: :systools warns bad_vsn when the two",
      "differ, and `mix castle.appup` reports that along with any transition that has no",
      "entry yet.",
      "",
      "`mix castle.appup --from <spec>` is what says whether this still covers everything",
      "that moved."
    ]
  end

  @doc """
  One from-version entry as source text, formatted and with its comments.

  This is what `merge/2` splices in and what the task prints when it refuses to
  write, so a refusal and a write produce the same entry rather than two
  renderings that could differ.
  """
  @spec entry_text(Forecastle.Appup.Draft.entry()) :: binary()
  def entry_text(entry) do
    instructions =
      Enum.map_join(entry.instructions, ",\n", fn {instruction, comments} ->
        Enum.map_join(comments, "\n", &comment/1) <>
          "\n" <> inspect(instruction, limit: :infinity)
      end)

    "{#{charlist(entry.from_vsn)},\n[\n#{preamble(entry)}#{instructions}\n]}"
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end

  # What is said about the entry as a whole, and a blank comment line under it
  # where an instruction follows, so that the two do not read as one paragraph.
  # An entry with nothing to say about it - one instruction, and not an `update` -
  # gets neither, rather than a lone `#`.
  defp preamble(%{preamble: []}), do: ""

  defp preamble(%{preamble: lines, instructions: []}) do
    Enum.map_join(lines, "\n", &comment/1) <> "\n"
  end

  defp preamble(%{preamble: lines}) do
    Enum.map_join(lines ++ [""], "\n", &comment/1) <> "\n"
  end

  @doc """
  Splices entries into the `up` and `dn` lists of a literal appup source.

  `additions` names a direction and the entry to add to it, and a direction may
  be left out - which is what happens when the appup already has an entry for
  this from-version in one list and not the other.

  The result is the source with nothing else changed. See the moduledoc for why
  this is a text splice rather than a re-render, and `verify/2` for what proves
  it landed where it meant to.
  """
  @spec merge(t(), [{:up | :down, Forecastle.Appup.Draft.entry()}]) ::
          {:ok, binary()} | {:error, binary()}
  def merge(literal, additions) do
    with {:ok, insertions} <- insertions(literal, additions),
         {:ok, spliced} <- splice(literal.source, insertions) do
      verify(spliced, merged(literal.term, additions))
    end
  end

  # **The entry goes in at the *front* of the list, immediately after the `[`,
  # and that is a fact about Elixir's grammar rather than a preference.** A
  # separator has to sit between the entry and whatever the list already held,
  # and appending means writing it *before* the new entry, on a line of its own -
  # which is a syntax error: a newline ends the expression before it, so
  # `[{a, b}\n, {c, d}]` is refused where `[{a, b},\n{c, d}]` is fine. Inserting
  # first puts the comma after the entry, where the line it ends does continue.
  #
  # **Which entry `:systools` selects is unaffected, and that is exact rather
  # than likely.** `systools_relup:appup_search_for_version/2` takes the first
  # entry that matches, and a from-version given as a charlist matches by term
  # equality - so an entry keyed by this from-version matches this from-version
  # and no other. Nothing already in the list matches it either, because the task
  # only adds an entry to a direction where that same function found none. So the
  # position cannot shadow anything, in either direction, and first is where the
  # most recent transition reads best.
  defp insertions(literal, additions) do
    Enum.reduce_while(additions, {:ok, []}, fn {direction, entry}, {:ok, acc} ->
      with {:ok, meta, list} <- list_node(literal.ast, direction),
           {:ok, line, column} <- opening(meta),
           {:ok, pad} <- indentation(literal.source, line) do
        {text, continuation} = fragment(entry, list, pad)

        {:cont, {:ok, [{line, column, text, continuation} | acc]}}
      else
        :error -> {:halt, {:error, unlocatable(direction)}}
      end
    end)
  end

  # Indented two past the line the `[` is on, which is where a formatted list
  # puts its elements. The second element is what whatever followed the `[` on
  # that line has to be lined up with, and it is applied only where something did
  # follow it - a `[` at the end of its line already has the newline the rest of
  # the list needs, and padding after it would leave a line of spaces behind.
  defp fragment(entry, list, pad) do
    separator = if list == [], do: "", else: ","
    continuation = if list == [], do: pad, else: pad + 2

    {"\n" <> indented(entry_text(entry), pad + 2) <> separator,
     String.duplicate(" ", continuation)}
  end

  defp indentation(source, line) do
    case Enum.at(String.split(source, "\n"), line - 1) do
      nil -> :error
      text -> {:ok, byte_size(text) - byte_size(String.trim_leading(text, " "))}
    end
  end

  defp unlocatable(direction) do
    "reads as a literal, but the #{word(direction)} list could not be located in the source - " <>
      "it is not written as a bracketed list, so there is no `[` to insert after"
  end

  defp word(:up), do: "up"
  defp word(:down), do: "dn"

  # The appup is `{Vsn, Up, Dn}`, which the parser gives as a `{:{}, meta, args}`
  # with three elements. Both lists arrive wrapped by the `:literal_encoder`,
  # which is what carries the metadata this needs.
  defp list_node({:{}, _meta, [_tag, up, dn]}, direction) do
    case if direction == :up, do: up, else: dn do
      {:__block__, meta, [list]} when is_list(list) -> {:ok, meta, list}
      _other -> :error
    end
  end

  defp list_node(_ast, _direction), do: :error

  # The `[` of a list is where the `:literal_encoder`'s wrapper says the node
  # starts, and `columns: true` is what puts a column on it.
  defp opening(meta) do
    case {Keyword.get(meta, :line), Keyword.get(meta, :column)} do
      {line, column} when is_integer(line) and is_integer(column) -> {:ok, line, column}
      _absent -> :error
    end
  end

  # Applied from the end of the file backwards, so an earlier insertion cannot
  # move a later one's position - which matters even within one line, since an
  # appup written on one line has both of its lists on it.
  #
  # The character at the position really being a `[` is checked rather than
  # assumed: the column is the tokenizer's count and the split is this function's,
  # and the two agreeing is what everything below depends on. A disagreement
  # refuses instead of writing into the middle of something.
  #
  # **`String.split_at/2` counts graphemes, and that is what the tokenizer counts
  # too - measured rather than assumed, because the obvious "fix" is wrong.** On
  # Elixir 1.19.5, a source line carrying `👩‍💻` (three codepoints, one grapheme)
  # or a decomposed `á` (two codepoints, one grapheme) before the bracket gives a
  # column that lines up with a grapheme split and not with a codepoint one. So
  # do not "correct" this to `String.to_charlist/1` and `Enum.split/2`; that is
  # the shape that breaks. `appup_source_test.exs` pins it with both.
  defp splice(source, insertions) do
    lines = String.split(source, "\n")

    insertions
    |> Enum.sort(:desc)
    |> Enum.reduce_while({:ok, lines}, fn insertion, {:ok, acc} -> insert(acc, insertion) end)
    |> case do
      {:ok, lines} -> {:ok, Enum.join(lines, "\n")}
      {:error, phrase} -> {:error, phrase}
    end
  end

  defp insert(lines, {line, column, text, continuation}) do
    with text_of_line when is_binary(text_of_line) <- Enum.at(lines, line - 1),
         {before, rest} <- String.split_at(text_of_line, column),
         true <- String.ends_with?(before, "[") do
      tail = if rest == "", do: "", else: "\n" <> continuation <> rest

      {:cont, {:ok, List.replace_at(lines, line - 1, before <> text <> tail)}}
    else
      _misplaced -> {:halt, {:error, misplaced()}}
    end
  end

  defp misplaced do
    "reads as a literal, but the position the parser gave for an opening bracket is not one - " <>
      "so nothing was written rather than something being inserted in the wrong place"
  end

  defp merged({tag, up, dn}, additions) do
    {tag, added(additions, :up) ++ up, added(additions, :down) ++ dn}
  end

  defp added(additions, direction) do
    for {^direction, entry} <- additions, do: term(entry)
  end

  defp term(entry) do
    {chars(entry.from_vsn), Enum.map(entry.instructions, &elem(&1, 0))}
  end

  # **What makes writing a generated file safe is that the file is read back
  # before it is written, not that the generator is careful.** The source is
  # parsed again, read as a literal again, and compared against the term it was
  # supposed to denote - so a rendering bug, a splice that landed in the wrong
  # place, or an instruction that does not survive `inspect/2` is a refusal with
  # nothing written, rather than an appup that claims coverage it has not got.
  #
  # It is also what says the output can be merged into next time: the check that
  # it reads as a literal is the same one `read/1` applies.
  defp verify(text, expected) do
    with {:ok, ast} <- Code.string_to_quoted(text, parse_opts()),
         {:ok, ^expected} <- to_term(ast) do
      {:ok, text}
    else
      _unverified ->
        {:error,
         "the appup this would have written does not read back as the entry it drafted, so " <>
           "nothing was written. This is a defect in mix castle.appup.gen"}
    end
  end

  ## Publishing

  @doc """
  Creates an appup source that was not there, and refuses to replace one that is.

  **Exclusive creation rather than a plain write, because the two answers are
  different and only one of them is safe.** `Source.read/1` said the file was
  absent, and everything since - the diff, the classification, the whole entry -
  was drafted on that. A file that has appeared in between is somebody else's,
  and `:file.open/2` with `:exclusive` is what refuses it in the same operation
  that would have created it, rather than in a check before one.

  **Exclusivity is not atomicity, and the file is taken away again when the write
  after it fails.** Raised in review. `File.write/3` opens, writes and closes, and
  an error in either of the last two - a full disk, a close that reports a
  deferred write error - leaves the inode it created with partial contents in it,
  which is a `.exs` the next `mix compile` will fail to evaluate. So the open is
  done here rather than through `File.write/3`, because only the caller of
  `:file.open/2` knows it created the file and may therefore remove it. If the
  removal fails too, the refusal says the path may hold partial output rather
  than saying nothing was written - a message that is wrong about the filesystem
  is worse than one that admits it does not know.
  """
  @spec create(binary(), binary()) :: :ok | {:error, binary()}
  def create(path, text) do
    case :file.open(path, [:binary, :write, :exclusive]) do
      {:ok, fd} -> fill(path, fd, text)
      {:error, :eexist} -> {:error, appeared()}
      {:error, reason} -> {:error, "could not be created: #{:file.format_error(reason)}"}
    end
  end

  defp appeared do
    "appeared while this was running, so what was drafted was drafted against a file that " <>
      "is no longer there. Nothing was written"
  end

  # Past the open this owns the inode, so every path out of here either leaves it
  # whole or takes it away - and where it can do neither, says so.
  defp fill(path, fd, text) do
    written = :file.write(fd, text)
    closed = :file.close(fd)

    case {written, closed} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _closed} -> discard(path, reason)
      {:ok, {:error, reason}} -> discard(path, reason)
    end
  end

  defp discard(path, reason) do
    case File.rm(path) do
      :ok ->
        {:error, "could not be written: #{:file.format_error(reason)}. Nothing was left behind"}

      {:error, removal} ->
        {:error,
         "could not be written: #{:file.format_error(reason)}, and the partial file could " <>
           "not be removed either: #{:file.format_error(removal)}. The path may hold part of " <>
           "an appup"}
    end
  end

  @doc """
  Replaces an appup source with the merged text, atomically, and refuses if it
  has changed since it was read.

  **Two separate hazards, and neither is the other's fix.**

  `File.write/2` opens for writing, which truncates: a failure part way through
  leaves the source neither what it was nor what it was going to be, and an
  in-memory check that the merged text is correct says nothing about that. So the
  text goes to a staging file *in the same directory* and is renamed onto the
  target, which is one operation - the same mechanism `Forecastle.Baseline` uses
  to publish a cache entry and `Forecastle.Relup` to publish a relup, and for the
  same reason. Same directory because a rename across filesystems is a copy.

  The second is that the file could have been edited between being read and being
  written, and the rename would then discard that edit without a word. Comparing
  the bytes first turns that into a refusal. **It narrows the window rather than
  closing it**, and there is no way to close it - POSIX has no compare-and-swap
  on a file, and a lock protocol over somebody's working tree is not this task's
  to invent. What makes narrowing worth doing here rather than in
  `Forecastle.Build`, which declines the equivalent finding about reading a build
  being raced by a rebuild, is that this one *writes*: the failure it prevents is
  destroying an edit somebody made, and the check costs one read of a file this
  already holds the expected contents of.
  """
  @spec replace(t(), binary()) :: :ok | {:error, binary()}
  def replace(literal, text) do
    case File.read(literal.path) do
      {:ok, unchanged} when unchanged == literal.source -> publish(literal.path, text)
      {:ok, _changed} -> {:error, changed()}
      {:error, reason} -> {:error, "could not be re-read: #{:file.format_error(reason)}"}
    end
  end

  defp changed do
    "changed after it was read and before it could be written, so writing the merge would " <>
      "have discarded whatever changed it. Nothing was written; run this again"
  end

  # Named with random bytes and created with `:exclusive`, which is `Baseline`'s
  # rule for a staging path: a name this run believes is unique is not something
  # it may act on destructively, and `:file.open/2` is what makes the claim and
  # the creation one operation.
  #
  # The mode is carried across because the rename replaces the inode, so a source
  # file somebody had made executable, or group-writable for a shared checkout,
  # would silently come back with this run's umask instead.
  defp publish(path, text) do
    staging = path <> ".castle-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    with :ok <- File.write(staging, text, [:exclusive]),
         :ok <- copy_mode(path, staging),
         :ok <- File.rename(staging, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(staging)

        {:error, "could not be written through #{Path.basename(staging)}: " <> format(reason)}
    end
  end

  defp copy_mode(path, staging) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> File.chmod(staging, mode)
      {:error, reason} -> {:error, reason}
    end
  end

  defp format(reason) when is_atom(reason), do: :file.format_error(reason)
  defp format(reason), do: inspect(reason)

  ## Reporting

  @doc """
  A unified-ish diff of two versions of a file, as lines ready to print.

  `List.myers_difference/2` rather than a shell `diff`, which is one more thing
  to be missing on the machine a release pipeline runs on.
  """
  @spec diff(binary(), binary()) :: [binary()]
  def diff(old, new) do
    chunks =
      old
      |> String.split("\n")
      |> List.myers_difference(String.split(new, "\n"))

    last = length(chunks) - 1

    chunks
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:eq, lines}, index} -> context(lines, index, last)
      {{:ins, lines}, _index} -> Enum.map(lines, &("+ " <> &1))
      {{:del, lines}, _index} -> Enum.map(lines, &("- " <> &1))
    end)
  end

  @context 3

  # Unchanged lines are shown only where they place a change: the last few before
  # one, the first few after it, and both around a run between two changes.
  #
  # **Every elision is marked.** A diff that silently dropped the head of the
  # file would read as though the change were at the top of it, which is the one
  # thing a diff must not do - the whole point of printing it is that the reader
  # can see where the entry landed.
  defp context(lines, 0, last) when last > 0 do
    {dropped, kept} = Enum.split(lines, max(length(lines) - @context, 0))

    elision(dropped) ++ keep(kept)
  end

  defp context(lines, index, index) do
    {kept, dropped} = Enum.split(lines, @context)

    keep(kept) ++ elision(dropped)
  end

  defp context(lines, _index, _last) when length(lines) <= 2 * @context + 1, do: keep(lines)

  defp context(lines, _index, _last) do
    keep(Enum.take(lines, @context)) ++ ["  ..."] ++ keep(Enum.take(lines, -@context))
  end

  defp elision([]), do: []
  defp elision(_dropped), do: ["  ..."]

  defp keep(lines), do: Enum.map(lines, &("  " <> &1))

  ## Text

  defp comment(""), do: "#"
  defp comment(line), do: "# " <> line

  defp indented(text, spaces) do
    pad = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end

  # A version is written as a `~c` sigil, which is what Elixir 1.15 onwards
  # spells a charlist as and what `to_term/1` reads back.
  #
  # A version that is not valid UTF-8 cannot be written that way and falls back
  # to the list of integers it is - which is still a literal, so the file stays
  # mergeable. That is unreachable through an application resource any tool
  # writes, since `~tp` produces codepoints and `to_string/1` of those is valid;
  # it takes a hand-written `.app` with a binary `vsn` to get there. It is here
  # rather than left to raise because `chars/1` is what the merged term is built
  # from, and a version this cannot write is one it must not claim to have
  # written either.
  defp charlist(vsn) do
    if String.valid?(vsn) do
      "~c" <> inspect(vsn)
    else
      inspect(chars(vsn), charlists: :as_lists, limit: :infinity)
    end
  end

  # The one conversion, so that what is rendered and what `verify/2` compares it
  # against cannot be two different charlists.
  defp chars(vsn) do
    if String.valid?(vsn), do: to_charlist(vsn), else: :binary.bin_to_list(vsn)
  end
end
