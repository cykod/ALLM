defmodule ALLM.Providers.Support.SSE do
  @moduledoc """
  Stateless line-buffered Server-Sent Events (SSE) decoder.

  Reused by all SSE-streaming providers (currently `ALLM.Providers.OpenAI`;
  Phase 11's `ALLM.Providers.Anthropic` consumes it unchanged). Provider-specific
  interpretation of `data:` payloads happens in each adapter's chunk-to-event
  mapper; this module only parses the SSE wire format per the
  [WHATWG Server-Sent Events spec](https://html.spec.whatwg.org/multipage/server-sent-events.html).

  ## Carve-out: the `:done` sentinel is OpenAI-specific

  OpenAI's Chat Completions streaming terminates with a `data: [DONE]\\n\\n`
  marker that has no native SSE meaning. To keep adapter chunk-mappers simple,
  this decoder returns `:done` as an in-band sentinel inside the message list
  whenever it parses a `data: [DONE]` event. Anthropic (Phase 11) signals
  termination with a regular `event: message_stop` SSE event — Anthropic-side
  reviewers must NOT blanket-pattern-match on `:done` and should instead
  consume it as one possible element of the message list.

  ## Accumulator round-trip

  The accumulator is a plain map (no PIDs / refs / funs) and round-trips
  cleanly through `:erlang.term_to_binary/1`. This matters for
  `Stream.resource/3` callers that thread the accumulator through
  `start_fun → next_fun` state — see spec §7.2 and Invariant 8 in the
  Phase 10 design doc's SSE Behaviour & Type Contracts.

  ## Spec sections

  Spec §7.2 (HTTP/1 streaming guidance).
  """

  @typedoc "Parsed SSE message per https://html.spec.whatwg.org/multipage/server-sent-events.html."
  @type message :: %{
          event: String.t() | nil,
          data: String.t(),
          id: String.t() | nil,
          retry: pos_integer() | nil
        }

  @typedoc "Parser accumulator: pending byte buffer + in-progress message fields."
  @type accumulator :: %{
          buffer: binary(),
          partial: %{
            event: String.t() | nil,
            data: [String.t()],
            id: String.t() | nil,
            retry: pos_integer() | nil
          }
        }

  @typedoc "Sentinel emitted in-band for OpenAI's `[DONE]` terminator (provider-specific carve-out)."
  @type done_marker :: :done

  @empty_partial %{event: nil, data: [], id: nil, retry: nil}

  @doc """
  Returns an empty accumulator. Pure; no IO.

  ## Examples

      iex> ALLM.Providers.Support.SSE.new()
      %{buffer: "", partial: %{event: nil, data: [], id: nil, retry: nil}}
  """
  @spec new() :: accumulator()
  def new, do: %{buffer: "", partial: @empty_partial}

  @doc """
  Decodes one chunk of SSE bytes against the running accumulator.

  Total over `binary() × accumulator()` — never raises on malformed input.
  Malformed lines (no `:` separator) are silently dropped per the SSE spec's
  "ignore unrecognized fields" rule. Comment lines (starting with `:`) are
  also dropped.

  Returns `{messages, new_accumulator}` where `messages` is a list of parsed
  `t:message/0` values plus an in-band `:done` sentinel for OpenAI's
  `data: [DONE]` terminator (see module doc).

  Honors all three line terminators from the SSE spec: LF, CR, CRLF.

  ## Examples

      iex> {messages, _acc} =
      ...>   ALLM.Providers.Support.SSE.new()
      ...>   |> ALLM.Providers.Support.SSE.decode_chunk("data: hello\\n\\n")
      iex> messages
      [%{event: nil, data: "hello", id: nil, retry: nil}]
  """
  @spec decode_chunk(accumulator(), binary()) :: {[message() | done_marker()], accumulator()}
  def decode_chunk(%{buffer: buffer, partial: partial} = _acc, chunk) when is_binary(chunk) do
    {lines, leftover} = split_lines(buffer <> chunk)
    {messages, final_partial} = process_lines(lines, partial, [])
    {messages, %{buffer: leftover, partial: final_partial}}
  end

  # --- Line splitting ----------------------------------------------------

  # Splits the accumulated bytes into completed lines and a trailing remnant.
  # A "completed" line is one terminated by LF, CR, or CRLF.
  @spec split_lines(binary()) :: {[binary()], binary()}
  defp split_lines(binary), do: do_split_lines(binary, "", [])

  defp do_split_lines(<<"\r\n", rest::binary>>, current, acc),
    do: do_split_lines(rest, "", [current | acc])

  defp do_split_lines(<<"\n", rest::binary>>, current, acc),
    do: do_split_lines(rest, "", [current | acc])

  defp do_split_lines(<<"\r", rest::binary>>, current, acc),
    do: do_split_lines(rest, "", [current | acc])

  defp do_split_lines(<<byte, rest::binary>>, current, acc),
    do: do_split_lines(rest, current <> <<byte>>, acc)

  defp do_split_lines(<<>>, current, acc), do: {Enum.reverse(acc), current}

  # --- Line processing ---------------------------------------------------

  # Walks the completed lines and folds them into messages and a residual
  # partial. An empty line dispatches the partial as a message; a comment
  # line is dropped; a parseable `field: value` line accumulates onto the
  # partial.
  @spec process_lines([binary()], map(), [message() | done_marker()]) ::
          {[message() | done_marker()], map()}
  defp process_lines([], partial, messages), do: {Enum.reverse(messages), partial}

  defp process_lines(["" | rest], partial, messages) do
    case dispatch(partial) do
      :no_message -> process_lines(rest, @empty_partial, messages)
      message -> process_lines(rest, @empty_partial, [message | messages])
    end
  end

  defp process_lines([<<":", _rest_of_line::binary>> | rest], partial, messages) do
    # Comment line — drop.
    process_lines(rest, partial, messages)
  end

  defp process_lines([line | rest], partial, messages) do
    case parse_field(line) do
      {:ok, field, value} -> process_lines(rest, apply_field(partial, field, value), messages)
      :ignore -> process_lines(rest, partial, messages)
    end
  end

  # --- Field parsing -----------------------------------------------------

  # Splits a line on its first `:`; per the SSE spec, a single space after
  # the colon is stripped from the value.
  @spec parse_field(binary()) :: {:ok, String.t(), String.t()} | :ignore
  defp parse_field(line) do
    case :binary.split(line, ":") do
      [field, value] -> {:ok, field, strip_leading_space(value)}
      _no_colon -> :ignore
    end
  end

  defp strip_leading_space(<<" ", rest::binary>>), do: rest
  defp strip_leading_space(value), do: value

  # Applies a parsed field to the partial. Unknown fields are dropped per
  # the SSE spec.
  @spec apply_field(map(), String.t(), String.t()) :: map()
  defp apply_field(partial, "data", value) do
    %{partial | data: [value | partial.data]}
  end

  defp apply_field(partial, "event", value), do: %{partial | event: value}
  defp apply_field(partial, "id", value), do: %{partial | id: value}

  defp apply_field(partial, "retry", value) do
    case Integer.parse(value) do
      {ms, ""} when ms > 0 -> %{partial | retry: ms}
      _ -> partial
    end
  end

  defp apply_field(partial, _field, _value), do: partial

  # --- Dispatch ----------------------------------------------------------

  # An empty-line dispatch: build a `t:message/0` (or `:done` sentinel)
  # from the partial. If no `data:` accumulated, emit nothing.
  @spec dispatch(map()) :: message() | done_marker() | :no_message
  defp dispatch(%{data: []}), do: :no_message

  defp dispatch(%{data: data_lines, event: event, id: id, retry: retry}) do
    data = data_lines |> Enum.reverse() |> Enum.join("\n")

    if data == "[DONE]" do
      :done
    else
      %{event: event, data: data, id: id, retry: retry}
    end
  end
end
