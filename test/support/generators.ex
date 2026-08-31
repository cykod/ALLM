defmodule ALLM.Test.Generators do
  @moduledoc """
  Shared `StreamData` generators for Layer A structs.

  This module is test-only infrastructure (compiled only under
  `Mix.env() == :test` via `elixirc_paths/1` in `mix.exs`). Per
  `agent-spec/IMPLEMENTATION.md` "Property tests" subsection, Layer A struct
  generators live here so they can be reused across property test files
  (e.g. `ALLM.ValidateTest`, `ALLM.SerializerTest` round-trip property).

  Prefer generator-level invariants (e.g. `StreamData.bind/2` +
  `StreamData.filter/2` chains for unique-by-field constraints) over
  post-filtering inside `check all`. Post-filter works but shrinks
  incorrectly — a shrunk counterexample that violates the post-filter will
  silently pass, hiding coverage of the constrained case.

  ## Conventions

    * Every generator produces a **valid** Layer A value — one that passes
      its corresponding `ALLM.Validate` check. Tests that need invalid
      shapes should construct them inline via raw struct literals.
    * Generators return plain structs (no PIDs, refs, funs) so values are
      safe for `:erlang.term_to_binary/1` round-trip properties.
    * Keep names short and descriptive: `role_gen/0`, `message_gen/0`,
      `tool_gen/0`, `request_gen/0`.
  """

  alias ALLM.{Message, Request, Tool}

  @doc """
  Generates a legal non-tool `role` atom: `:system`, `:user`, or `:assistant`.

  `:tool` is excluded because it requires a `tool_call_id` companion field
  which generic message generators cannot populate without extra context.
  """
  @spec role_gen() :: StreamData.t(:system | :user | :assistant)
  def role_gen, do: StreamData.member_of([:system, :user, :assistant])

  @doc """
  Generates a non-empty printable string suitable for `:content` or
  `:description` fields (1..40 characters).
  """
  @spec text_gen() :: StreamData.t(String.t())
  def text_gen, do: StreamData.string(:printable, min_length: 1, max_length: 40)

  @doc """
  Generates a valid tool name (1..32 chars, ASCII alphanum plus `_` and `-`).

  Matches the `^[A-Za-z0-9_-]{1,64}$` format enforced by
  `ALLM.Validate.tool/1`. We cap at 32 to keep shrunk counterexamples short.
  """
  @spec tool_name_gen() :: StreamData.t(String.t())
  def tool_name_gen do
    StreamData.string(Enum.concat([?a..?z, ?A..?Z, ?0..?9, [?_, ?-]]),
      min_length: 1,
      max_length: 32
    )
  end

  @doc """
  Generates a valid `%ALLM.Message{}` with a non-`:tool` role and string
  content.
  """
  @spec message_gen() :: StreamData.t(Message.t())
  def message_gen do
    StreamData.bind(role_gen(), fn role ->
      StreamData.bind(text_gen(), fn content ->
        StreamData.constant(%Message{role: role, content: content})
      end)
    end)
  end

  @doc """
  Generates a valid `%ALLM.Tool{}` with a well-formed name, a non-empty
  description, and an empty schema map. Handler is `nil`.
  """
  @spec tool_gen() :: StreamData.t(Tool.t())
  def tool_gen do
    StreamData.bind(tool_name_gen(), fn name ->
      StreamData.bind(text_gen(), fn desc ->
        StreamData.constant(%Tool{name: name, description: desc, schema: %{}})
      end)
    end)
  end

  @doc """
  Generates a valid `%ALLM.Request{}` with:

    * 1..5 messages from `message_gen/0`
    * `:temperature` either `nil` or a float in `0.0..2.0`
    * `:max_tokens` either `nil` or an integer in `1..4096`
    * 0..3 tools from `tool_gen/0`, deduplicated by `:name` post-generation

  Callers needing stricter tool-uniqueness guarantees (e.g. "exactly N
  distinct names") should compose a custom generator via
  `StreamData.bind/2`; the post-`Enum.uniq_by/2` here is adequate for the
  common "tools should be valid and unique" case in the validate property
  test but shrinks imperfectly past that.
  """
  @spec request_gen() :: StreamData.t(Request.t())
  def request_gen do
    StreamData.bind(request_fields_gen(), fn {msgs, temp, max_t, tools} ->
      StreamData.constant(
        Request.new(msgs,
          temperature: temp,
          max_tokens: max_t,
          tools: Enum.uniq_by(tools, & &1.name)
        )
      )
    end)
  end

  # Tuple generator for request fields — keeps `request_gen/0` flat by
  # combining the four sources via `fixed_list/1` rather than nested `bind`.
  @spec request_fields_gen() ::
          StreamData.t({[Message.t()], float() | nil, pos_integer() | nil, [Tool.t()]})
  defp request_fields_gen do
    StreamData.bind(
      StreamData.fixed_list([
        StreamData.list_of(message_gen(), min_length: 1, max_length: 5),
        temperature_gen(),
        max_tokens_gen(),
        StreamData.list_of(tool_gen(), max_length: 3)
      ]),
      fn [msgs, temp, max_t, tools] ->
        StreamData.constant({msgs, temp, max_t, tools})
      end
    )
  end

  @spec temperature_gen() :: StreamData.t(float() | nil)
  defp temperature_gen do
    StreamData.one_of([StreamData.constant(nil), StreamData.float(min: 0.0, max: 2.0)])
  end

  @spec max_tokens_gen() :: StreamData.t(pos_integer() | nil)
  defp max_tokens_gen do
    StreamData.one_of([StreamData.constant(nil), StreamData.integer(1..4096)])
  end
end
