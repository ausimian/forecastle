defmodule Forecastle.Appup.Source do
  @moduledoc """
  Reads and rewrites the appup source named by the `:appup` project key.

  Appup source is arbitrary Elixir evaluated for its value. This module rewrites
  only a pure literal whose value is determined by its AST. Computed source,
  structs, and bitstrings that require runtime truncation are refused. Literal
  aliases, lists, maps, tuples, binaries and uninterpolated `~c`/`~C` sigils are
  accepted.

  New entries are inserted as text so comments, formatting and existing entries
  remain unchanged. The result is parsed again and must equal the intended
  merged term before it can be written.
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
  Reads an appup source file.

  Returns `:absent`, a literal source that can be merged, or a computed or
  malformed source with a reason for refusing it.
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
  Converts a literal AST to its term.

  Returns `:error` when evaluating the AST requires computation.
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

  # A list, and the cons cell an improper one ends in. `[1 | 2]` parses to a
  # one-element list holding a `{:|, meta, [head, tail]}`, and `|` can only be
  # the last element - so the tail is read on its own and consed on rather than
  # appended. Raised in review, where the file read as computed for it.
  def to_term(list) when is_list(list) do
    case List.pop_at(list, -1) do
      {{:|, _meta, [head, tail]}, front} ->
        with {:ok, front} <- all(front),
             {:ok, head} <- to_term(head),
             {:ok, tail} <- to_term(tail) do
          {:ok, front ++ [head | tail]}
        end

      _proper ->
        all(list)
    end
  end

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

  @typedoc """
  Which kind of appup source is being written, which is the whole of what the
  header differs by.

  `:project` is the file the `:appup` key names, compiled by the `:appup`
  compiler. `{:dependency, app, vsn}` is a `rel/appups/<app>-<from>-<to>.exs`,
  which nothing compiles and `Forecastle.Appup.Dep` places into an assembled
  release.
  """
  @type kind :: :project | {:dependency, atom(), binary()}

  @doc """
  Renders a complete appup source for an application with no source file.

  The header identifies project or dependency ownership and records the limits
  of the generated draft.
  """
  @spec render(binary(), Forecastle.Appup.Draft.entry(), Forecastle.Appup.Draft.entry(), kind()) ::
          {:ok, binary()} | {:error, binary()}
  def render(tag, up, dn, kind) do
    text =
      [
        Enum.map_join(header(kind), "\n", &comment/1),
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

  defp header(:project) do
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

  defp header({:dependency, app, vsn}) do
    [
      "Generated by `mix castle.appup.gen`, and source you review and commit: an appup for",
      "#{app}, an application this project does not own. What is below is a draft of *which",
      "modules moved* rather than a decision about what happens to their state.",
      "",
      "The Extra term in every `{:advanced, Extra}` is `[]`. Nothing can derive it.",
      "",
      "Nothing compiles this file, and nothing writes it into deps/ - that would leak these",
      "instructions into every build sharing that checkout. Forecastle places it at",
      "lib/#{app}-#{vsn}/ebin/#{app}.appup while assembling a release, beside any appup",
      "#{app} ships for itself - whose entries are kept behind these - and refuses it once",
      "#{app} is no longer #{vsn} there. The file name is what says which transition it is",
      "for, so rename it rather than editing the tag below.",
      "",
      "`mix castle.appup --from <spec> --app #{app}` is what says whether this still covers",
      "everything that moved. Point --to at an assembled release: a dependency's appup is",
      "only in one once this file has been placed into it."
    ]
  end

  @doc """
  Renders one from-version entry with its generated comments.

  The generator uses the same text for source updates and manual-merge output.
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
  Inserts entries into the upgrade and downgrade lists of a literal source.

  A direction may be omitted when it already has a matching entry. The function
  preserves all other source text and verifies the merged term.
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
  Creates an appup source exclusively.

  Returns an error if the path already exists or cannot be written, preventing a
  concurrent edit from being replaced.
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
  Atomically replaces a literal source with merged text.

  The function refuses a file that changed after it was read. It writes a
  staging file beside the resolved target, preserves the file mode, and renames
  the completed file into place. Symlink chains are followed to the source file.
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
  # **Only a staging file this run created is ever removed, and a name already
  # taken is retried rather than cleared.** Raised in review, and it was the very
  # rule the paragraph above cites `Baseline` for: a name this run *believes* is
  # unique is not something it may act on destructively. Sharing one error branch
  # between the exclusive create and everything after it meant an `:eexist` -
  # another run holding that name - deleted that run's live staging file. The
  # claim and the cleanup are now on opposite sides of the `case`, so nothing
  # this did not create is touched.
  @staging_attempts 5

  defp publish(path, text, attempts \\ @staging_attempts)

  defp publish(path, _text, 0) do
    {:error,
     "could not be written: #{@staging_attempts} staging names beside " <>
       "#{Path.basename(path)} were all taken, so something else is writing there"}
  end

  defp publish(path, text, attempts) do
    with {:ok, path} <- target(path) do
      staging = path <> ".castle-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

      case File.write(staging, text, [:exclusive]) do
        :ok -> rename(path, staging)
        {:error, :eexist} -> publish(path, text, attempts - 1)
        {:error, reason} -> {:error, "could not be written: " <> format(reason)}
      end
    end
  end

  # Past the exclusive create this run owns the staging file, so every path out
  # of here either publishes it or takes it away.
  defp rename(path, staging) do
    with :ok <- copy_mode(path, staging),
         :ok <- File.rename(staging, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(staging)

        {:error, "could not be written through #{Path.basename(staging)}: " <> format(reason)}
    end
  end

  # **A rename replaces a directory entry, so renaming onto a symlink replaces
  # the *link* and not what it points at.** Raised in review. `File.read/1`
  # follows the link, so the merge would have been computed from the shared
  # target and then written over the link - the target unchanged, the project
  # silently no longer following it, and the run reporting a successful merge.
  # That is the failure this whole task is built not to have, arriving through
  # the filesystem instead of through the appup.
  #
  # So the link is followed to what it names, and the staging file is created
  # beside *that* - which is also what keeps the rename on one filesystem.
  # Bounded, because a symlink loop is a filesystem somebody has broken and not
  # something to spin on.
  #
  # **At the bound this refuses rather than returning the path it stopped on.**
  # Raised in review. That path is one `read_link/1` has just answered for, so
  # it is known to *be* a link, and handing it to the rename is the finding at
  # the top of this comment arrived at from the other side: the chain broken,
  # the shared file at its end untouched, and `:ok` reported. Nothing downstream
  # catches it, because there is nothing to catch - the exclusive create, the
  # stat, the chmod and the rename all succeed. A rename onto a link is an
  # ordinary operation, and only declining to hand it one stops this.
  #
  # The bound is spent on links followed, not on calls made, so a chain of
  # exactly @link_depth still resolves; @link_depth + 1 is what refuses.
  #
  # `:einval` is what `read_link/1` answers for a path that is not a link, which
  # is the ordinary case and the reason this is a `case` rather than a check.
  @link_depth 8

  defp target(path, depth \\ @link_depth)

  defp target(path, depth) do
    case File.read_link(path) do
      {:ok, _link} when depth == 0 -> {:error, too_many_links()}
      {:ok, link} -> target(Path.expand(link, Path.dirname(path)), depth - 1)
      {:error, _not_a_link} -> {:ok, path}
    end
  end

  defp too_many_links do
    "is reached through more than #{@link_depth} symlinks, so where the merge would land " <>
      "could not be established. Nothing was written; point the :appup key at the file " <>
      "itself, or shorten the chain"
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
  Returns a compact line diff suitable for terminal output.

  Changed lines use `+ ` and `- ` prefixes. Unchanged context uses two spaces,
  with omitted regions marked by `...`.
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
  # **There is no fallback for a version that is not valid UTF-8, because there
  # is no such version by the time it gets here.** `Forecastle.Build.fetch_vsn!/2`
  # refuses one at the point a version enters, once, so everything downstream can
  # take a version as printable and writable. This used to carry an
  # integer-list fallback of its own, and `chars/1` beside it to keep the
  # rendering and the verification agreeing - both unreachable, and both a
  # standing invitation to believe the refusal was not needed.
  defp charlist(vsn), do: "~c" <> inspect(vsn)

  defp chars(vsn), do: to_charlist(vsn)
end
