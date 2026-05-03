defmodule ALLM.Providers.Gemini.Decode do
  @moduledoc false

  # Shared response-decoder helpers for `ALLM.Providers.Gemini` and
  # `ALLM.Providers.Gemini.Images`. Per Phase 16.5 cross-function
  # invariant (steering/GEMINI_DESIGN.md lines 217-219): a single helper
  # walks `candidates[0].content.parts` once and returns
  # `{text, tool_calls, image_parts, raw_finish_reason}`. Two callers
  # consume different subsets of the tuple (chat ignores `image_parts`;
  # Images filters for `inlineData` parts); the parsing is single-source.
  #
  # Mirrors PHASE_14 Decision #14's "cite both translators" precedent
  # applied to the response half — see CLAUDE.md "OpenAI has TWO endpoint
  # translators" worked example.

  alias ALLM.Image
  alias ALLM.ImagePart
  alias ALLM.ToolCall

  @typedoc """
  Result tuple for `candidate_parts/1`.

    * `text` — joined text-part contents, or `nil` when no text parts
    * `tool_calls` — list of `%ToolCall{}` decoded from `functionCall` parts
    * `image_parts` — list of `%ImagePart{}` wrapping decoded `inlineData`
    * `raw_finish_reason` — the candidate's `finishReason` string, or `nil`
  """
  @type t ::
          {String.t() | nil, [ToolCall.t()], [ImagePart.t()], String.t() | nil}

  @doc """
  Walk `candidates[0]`'s `content.parts` once and return
  `{text, tool_calls, image_parts, raw_finish_reason}`.

  Accepts the candidate map directly (not the full body); callers slice
  `candidates[i]` themselves so the helper is reusable for multi-candidate
  decoding (`n > 1` image responses).
  """
  @spec candidate_parts(map()) :: t()
  def candidate_parts(%{} = candidate) do
    raw_finish = Map.get(candidate, "finishReason")
    parts = get_in(candidate, ["content", "parts"]) || []

    {text_io, tool_calls_rev, image_parts_rev} =
      Enum.reduce(parts, {[], [], []}, &accumulate_part/2)

    text =
      case text_io do
        [] -> nil
        list -> list |> Enum.reverse() |> Enum.join("")
      end

    {text, Enum.reverse(tool_calls_rev), Enum.reverse(image_parts_rev), raw_finish}
  end

  # Per-part dispatcher. Mirrors the streaming chunk-mapper "one defp per
  # event class" rule (CLAUDE.md "SSE chunk mappers" lift) for the
  # response decoder side — keeps cyclomatic complexity below Credo's
  # default-9 threshold and nesting at depth-2.
  defp accumulate_part(%{"text" => t}, {texts, calls, imgs}) when is_binary(t) do
    {[t | texts], calls, imgs}
  end

  defp accumulate_part(%{"functionCall" => %{} = fc} = part, {texts, calls, imgs}) do
    {texts, [decode_function_call(fc, part) | calls], imgs}
  end

  defp accumulate_part(%{"inlineData" => %{} = inline}, {texts, calls, imgs}) do
    case decode_inline_data(inline) do
      nil -> {texts, calls, imgs}
      %ImagePart{} = ip -> {texts, calls, [ip | imgs]}
    end
  end

  defp accumulate_part(_other, acc), do: acc

  # ---------------------------------------------------------------------------
  # functionCall decoding (Phase 16.3 — moved from Gemini for sharing)
  # ---------------------------------------------------------------------------

  @doc false
  @spec decode_function_call(map(), map()) :: ToolCall.t()
  def decode_function_call(%{} = fc, part \\ %{}) do
    name = Map.get(fc, "name", "")
    args = normalize_function_call_args(Map.get(fc, "args"))
    id = synthesize_tool_call_id(fc)

    # Gemini 3 emits a `thoughtSignature` sibling field on the same part as
    # `functionCall`. The caller MUST echo it back in the next request's
    # functionCall part or Gemini rejects with INVALID_ARGUMENT. Preserve
    # on `ToolCall.metadata` for round-trip via `tool_call_to_function_call_part/1`.
    metadata =
      case Map.get(part, "thoughtSignature") do
        sig when is_binary(sig) and sig != "" -> %{"thoughtSignature" => sig}
        _ -> %{}
      end

    ToolCall.new(
      id: id,
      name: name,
      arguments: args,
      raw_arguments: Jason.encode!(args),
      metadata: metadata
    )
  end

  defp normalize_function_call_args(args) when is_map(args), do: args
  defp normalize_function_call_args(_), do: %{}

  defp synthesize_tool_call_id(%{"id" => id}) when is_binary(id) and id != "", do: id

  defp synthesize_tool_call_id(%{"name" => name} = fc) when is_binary(name) do
    args = Map.get(fc, "args") || %{}
    "fc_" <> Integer.to_string(:erlang.phash2({name, args}), 16)
  end

  defp synthesize_tool_call_id(_), do: ""

  # ---------------------------------------------------------------------------
  # inlineData decoding (Phase 16.5 — image-out)
  # ---------------------------------------------------------------------------

  # Gemini's `inlineData` part shape:
  #
  #     %{"mimeType" => "image/png", "data" => "<base64 bytes>"}
  #
  # The wire `data` field is documented as standard base64. We materialize
  # an `%Image{source: {:binary, raw}, mime_type: mt}` so callers don't
  # need to decode themselves; the `:binary` source mirrors the OpenAI
  # `:binary` response_format default at `lib/allm/providers/openai/images.ex:1273-1290`.
  #
  # Malformed entries (missing fields, undecodable base64) are dropped
  # rather than raised — the response decoder calls into us inside a
  # decode flow that should not throw on a single bad part. The image
  # adapter's `decode_image_response/4` enforces presence with a typed
  # `:malformed_response` error when the candidate yields zero images.
  defp decode_inline_data(%{"mimeType" => mime, "data" => data})
       when is_binary(mime) and is_binary(data) do
    case Base.decode64(data) do
      {:ok, bytes} ->
        %ImagePart{
          image: %Image{source: {:binary, bytes}, mime_type: mime},
          detail: :auto
        }

      :error ->
        nil
    end
  end

  defp decode_inline_data(_), do: nil
end
