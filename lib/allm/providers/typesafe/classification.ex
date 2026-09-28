defmodule ALLM.Providers.TypeSafe.Classification do
  @moduledoc """
  TypeSafe typed-classification adapter (Jev). Implements
  `ALLM.ClassificationAdapter`.

  Layer B — runtime. Jev is a classification model, not a chat model: it
  answers closed-form questions about a piece of state with calibrated
  probabilities and generates no text. This adapter is therefore a
  classification adapter only; TypeSafe has no chat, image, embeddings,
  moderation or audio adapter in ALLM.

      engine =
        ALLM.Engine.new(
          classification_adapter: ALLM.Providers.TypeSafe.Classification,
          classification_model: "jev-1.13.0"
        )

      {:ok, resp} = ALLM.classify(engine, ticket_text, questions: questions)

  Keys resolve through `ALLM.Keys.fetch!(:typesafe, opts)` at request-build
  time, from `opts[:api_key]` or the `TYPESAFE_API_KEY` environment variable.
  No key ever lives on the engine.

  ## `:yes_no` is TypeSafe's `noul`

  TypeSafe calls its yes/no question type `noul`. ALLM's provider-neutral
  name for it is `:yes_no`: this adapter sends `"type": "noul"` for a
  `:yes_no` question and decodes a `noul` answer into
  `%ALLM.ClassificationAnswer{type: :yes_no, yes_probability: p}`. The
  alias appears nowhere else in ALLM. A `noul` answer carries no
  confidence, so `:confidence` is `nil` on every `:yes_no` answer.

  ## Wire-field map

  | Concern | TypeSafe |
  |---------|----------|
  | Endpoint | `POST https://api.typesafe.ai/v1/systemone` (not overridable) |
  | Auth | `authorization: Bearer <key>` |
  | Request | `{"state", "model", "questions": {"<id>": {"type", "instructions", "criteria"}}}` |
  | Question type | `:choice` → `"choice"`, `:score` → `"score"`, `:yes_no` → `"noul"` |
  | Choice criteria | `{"<option>": description \\| null}` |
  | Score criteria | an ordered array of levels, low to high |
  | Yes/no criteria | optional `{"true": …, "false": …}`; omitted when `nil` |
  | Choice answer | `choice`, `probabilities` (by option), `confidence` |
  | Score answer | `score`, `probabilities` and `legend` keyed `"0".."n-1"` (decoded to lists, index = level), `confidence` |
  | Noul answer | `noul` (the probability of yes) |
  | Response model | `model` — the versioned id that answered (`"jev-1.13.0"`), not the alias sent |
  | Usage | `usage.input_tokens`, `usage.output_tokens` |
  | Provider request id | `x-typesafe-request-id` response header → `ClassificationResponse.id` |
  | Errors | `{"detail": …}`, where `detail` is a string, an object with `message` and `error_type`, or (on 422) a list of `{"loc", "msg"}` entries |

  A score question whose levels are objects gets those objects back as its
  `:legend` entries; a string level comes back as a string.

  TypeSafe ignores unknown fields in a request, both on a question and at
  the top level, so a misspelled field is silently dropped rather than
  rejected.

  ## Adapter-injected defaults

  The wire requires `model`, and `ALLM.ClassificationRequest` allows
  `model: nil`. When the request carries no model this adapter sends
  `"jev-latest"`. `jev-latest` is an alias that moves when TypeSafe ships a
  new version; pin a versioned id such as `"jev-1.13.0"` (on the engine's
  `:classification_model`, or on the request) when you tune thresholds
  against its probabilities. `ALLM.classify/3` stamps
  `engine.classification_model` onto a request with no model before the
  adapter sees it, so the default applies only when neither is set.

  `request.options` is ignored: nothing in it reaches the wire.
  `request.metadata` is returned unchanged on the response.

  ## Limits and pre-flight gates

  Before any HTTP I/O, and before `ALLM.Keys.fetch!/2` (so a request that is
  going to be rejected never needs a key), in this order:

    1. **Empty questions.** `questions: %{}` → `:invalid_request` with
       `metadata: %{field: :questions}`.
    2. **Provider limits.** A choice question with more than 255 options, or
       a score question with more than 10 levels → `:invalid_request` with
       `metadata: %{question: id, limit: n}`. Both limits are TypeSafe's
       own; the provider answers 400 above them.
    3. **List state.** A list `state` must hold only strings (TypeSafe
       documents list state as "an array of text values") →
       `:invalid_request` with `metadata: %{field: :state}`.
    4. **Encodability.** A body that cannot be JSON-encoded (a tuple, a pid,
       an improper list anywhere in the state or a question) →
       `:invalid_request` with `metadata: %{cause: :unencodable_body}`.
       `ALLM.classify/3` validates the same thing earlier; this gate is what
       a direct `classify/2` call meets.

  TypeSafe documents no maximum question count: a request with 512
  questions was accepted when this adapter was recorded. Each question
  re-reads the state, so the per-request token budget (64k tokens in all;
  32k for the state plus the longest question) is the practical limit. A
  request over it is `:context_length_exceeded`.

  ## Errors

  | Status | Reason |
  |--------|--------|
  | 400 with `detail.error_type == "max_tokens_exceeded"` | `:context_length_exceeded` |
  | 400, 404, 422 | `:invalid_request` (TypeSafe answers 400 for an unknown question type, an unknown model and a limit breach, and 422 for a body that fails schema validation) |
  | 401, 403 | `:authentication_failed` |
  | 429 | `:rate_limited`, with `retry_after_ms` from `Retry-After` when present |
  | 500, 502, 503, 504, 529 | `:provider_unavailable` (529 is TypeSafe's "Overloaded") |
  | any other | `:unknown` |

  A transport timeout is `:timeout`; any other transport failure is
  `:network_error`. A 200 whose body does not match the questions asked
  (an answer missing, an extra answer, a type that differs from the
  question's, a choice outside the options, a score with the wrong number
  of levels or outside its levels, a probability or confidence outside
  0..1) is `:malformed_response`.

  Error `:metadata` carries `status`, `typesafe_error_type` (the body's
  `detail.error_type`, when present) and `typesafe_request_id` (the
  `x-typesafe-request-id` header, which TypeSafe support asks for).

  ## Error-struct hygiene

  `%ALLM.Error.ClassificationAdapterError{}` is JSON-encodable and is
  commonly logged and persisted. This adapter never stores an exception,
  a response body or a request header in `:cause` or `:metadata`: every
  error it returns has `cause: nil` and encodes with `Jason.encode!/1`. A
  transport failure's reason atom goes in `metadata.transport_reason`.
  Every provider-authored string (the message, the error type, the request
  id) passes a redactor that removes the resolved API key literally and any
  `apikey_…`-shaped token by pattern. TypeSafe's 401 text does not echo the
  key; the redactor is defence in depth.

  ## Retry integration

  One HTTP attempt per call, with no retry loop here: `ALLM.classify/3`
  retries `:rate_limited`, `:provider_unavailable`, `:timeout` and
  `:network_error` according to `engine.retry`. A direct `classify/2` call
  makes exactly one attempt; a caller retrying it themselves can read
  `retry_after_ms`.

  ## Test-injection escape hatch

  `classify/2` honours `opts[:adapter_opts][:classification_script]`: when
  that key holds any non-nil value (including `[]`), the call delegates to
  `ALLM.Providers.FakeClassification.classify/2` before any gate runs. This
  is what lets the `ALLM.ClassificationAdapter` conformance suite drive
  this adapter without an HTTP stub. The switch is keyed on that per-call
  option only. `prepare_request/2` does not delegate; under a script it
  returns an error, since a scripted answer has no `Req.Request` analogue.
  """

  @behaviour ALLM.ClassificationAdapter

  alias ALLM.{ClassificationAnswer, ClassificationQuestion, ClassificationRequest}
  alias ALLM.{ClassificationResponse, Keys, Usage}
  alias ALLM.Error.ClassificationAdapterError
  alias ALLM.Providers.FakeClassification
  alias ALLM.Providers.Support.HTTPResponse
  alias ALLM.Providers.Support.Redact

  @base_url "https://api.typesafe.ai/v1"
  @endpoint "/systemone"
  @default_model "jev-latest"

  @max_choice_options 255
  @max_score_levels 10

  @wire_types %{choice: "choice", score: "score", yes_no: "noul"}
  @answer_types %{"choice" => :choice, "score" => :score, "noul" => :yes_no}

  # The one context-length signal TypeSafe sends: a 400 whose
  # `detail.error_type` is this string, with no message.
  @context_length_error_type "max_tokens_exceeded"

  # The literal-key redaction pass runs only for a key at least this long,
  # so a short test key cannot rewrite ordinary words in a message.
  @min_literal_key_bytes 8

  # ---------------------------------------------------------------------------
  # ALLM.ClassificationAdapter callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Classify `request.state` against every question in one call to TypeSafe.

  Returns `{:ok, %ALLM.ClassificationResponse{}}` with one answer per
  question id, or `{:error, %ALLM.Error.ClassificationAdapterError{}}`.
  Every HTTP-shaped failure converts, including transport errors. The one
  exception is `ALLM.Keys.fetch!/2`, which raises
  `%ALLM.Error.EngineError{reason: :missing_key}` when no key is found; all
  pre-flight gates run before it.

  When `request.model` is `nil` the adapter sends `"jev-latest"`. Pin a
  versioned id to keep probabilities stable across TypeSafe releases.

  A body that cannot be JSON-encoded returns `:invalid_request` with
  `metadata: %{cause: :unencodable_body}` and makes no call.

  See the module documentation for the gate order, the wire-field map, the
  `noul` alias and the error mapping.

  ## Examples

      iex> q = ALLM.ClassificationQuestion.yes_no("Is a refund requested?")
      iex> req = ALLM.ClassificationRequest.new(state: "Refund me.", questions: %{"refund" => q})
      iex> opts = [adapter_opts: [classification_script: [{:answers, %{"refund" => 0.9}}]]]
      iex> {:ok, resp} = ALLM.Providers.TypeSafe.Classification.classify(req, opts)
      iex> ALLM.ClassificationResponse.answer(resp, "refund").yes_probability
      0.9

      iex> req = ALLM.ClassificationRequest.new(state: "hi", questions: %{})
      iex> {:error, err} = ALLM.Providers.TypeSafe.Classification.classify(req, [])
      iex> err.reason
      :invalid_request
  """
  @impl ALLM.ClassificationAdapter
  @spec classify(ClassificationRequest.t(), keyword()) ::
          {:ok, ClassificationResponse.t()} | {:error, ClassificationAdapterError.t()}
  def classify(%ClassificationRequest{} = request, opts) when is_list(opts) do
    case fetch_classification_script(opts) do
      nil ->
        with {:ok, http_req} <- prepare_request(request, opts) do
          run_one_attempt(http_req, request, opts)
        end

      _script ->
        FakeClassification.classify(request, opts)
    end
  end

  @doc """
  Return an unfired `Req.Request` configured exactly as `classify/2` would
  fire it, for callers who need to add headers or middleware before
  dispatch.

  The pre-flight gates run first, so this returns an error for a request
  `classify/2` would reject before I/O. Under
  `opts[:adapter_opts][:classification_script]` it returns an `:unknown`
  error with `metadata: %{cause: :scripted_adapter}`.

  ## Examples

      iex> q = ALLM.ClassificationQuestion.yes_no("Is a refund requested?")
      iex> req = ALLM.ClassificationRequest.new(state: "Refund me.", questions: %{"refund" => q})
      iex> {:ok, http} = ALLM.Providers.TypeSafe.Classification.prepare_request(req, api_key: "apikey_x")
      iex> URI.to_string(http.url)
      "https://api.typesafe.ai/v1/systemone"
  """
  @impl ALLM.ClassificationAdapter
  @spec prepare_request(ClassificationRequest.t(), keyword()) ::
          {:ok, Req.Request.t()} | {:error, ClassificationAdapterError.t()}
  def prepare_request(%ClassificationRequest{} = request, opts) when is_list(opts) do
    case fetch_classification_script(opts) do
      nil ->
        with :ok <- gate_empty_questions(request, opts),
             :ok <- gate_limits(request, opts),
             :ok <- gate_state(request),
             {:ok, encoded} <- encode_body(request, opts) do
          build_request(encoded, Keys.fetch!(:typesafe, opts), opts)
        end

      _script ->
        {:error, stub_error(opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Public testing seams (`@doc false` + `@spec`).
  #
  # Names follow the capability families: `to_json_body/2` and
  # `decode_response/4` (with its `(body, headers, request, opts)` order) as
  # in every Req-based adapter; `to_classification_adapter_error/5` and
  # `classify_classification_reason/3` renamed per capability, as moderation's
  # `to_moderation_adapter_error/4` / `classify_moderation_reason/4` and
  # Voyage's `classify_embedding_reason/3`; `fetch_classification_script/1`
  # and `stub_error/1` as in the moderation and embeddings adapters.
  #
  # DIVERGENT, with the forcing reason:
  #   * `to_classification_adapter_error/5` takes the RESOLVED key as a fifth
  #     argument: `redact_key_material/2` removes that literal string, and
  #     `opts[:api_key]` is nil whenever the key came from the environment.
  #   * `redact_key_material/2` is two-pass (literal key, then
  #     `Support.Redact.typesafe/1`); the siblings' `/1` forms are
  #     pattern-only, because their key formats are documented.
  #   * `gate_limits/2` and `gate_state/1` are the moderation adapter's
  #     `gate_*` shape; the limits are TypeSafe's and live nowhere else.
  #   * `extract_error_message/1` is private and TypeSafe's own: its
  #     `detail` takes three shapes (a string as Voyage's does, an object
  #     with `message`, a FastAPI list as ElevenLabs' 422 does), and neither
  #     sibling extractor handles all three. Both are private to their
  #     adapters, so reusing either would mean editing released code.
  #   * No inner retry loop and no `build_retry_telemetry_meta/1`: one HTTP
  #     attempt per call, as in the audio transcription adapters.
  # ---------------------------------------------------------------------------

  @doc false
  # The JSON body `classify/2` sends. `"jev-latest"` is injected when
  # `request.model` is nil (the wire requires `model`). `:yes_no` is sent as
  # `"noul"`, and a yes/no question with nil criteria omits `criteria`.
  # `request.options` is never read.
  @spec to_json_body(ClassificationRequest.t(), keyword()) :: map()
  def to_json_body(%ClassificationRequest{} = request, _opts) do
    %{
      "state" => request.state,
      "model" => request.model || @default_model,
      "questions" => Map.new(request.questions, fn {id, q} -> {id, question_to_wire(q)} end)
    }
  end

  @doc false
  # Provider limits: at most 255 choice options and 10 score levels.
  @spec gate_limits(ClassificationRequest.t(), keyword()) ::
          :ok | {:error, ClassificationAdapterError.t()}
  def gate_limits(%ClassificationRequest{questions: questions}, opts) when is_map(questions) do
    questions
    |> Enum.sort_by(fn {id, _q} -> id end)
    |> Enum.find_value(:ok, fn {id, q} -> limit_error(id, q, opts) end)
  end

  def gate_limits(%ClassificationRequest{}, _opts), do: :ok

  @doc false
  # A list `state` must hold only strings ("an array of text values").
  @spec gate_state(ClassificationRequest.t()) :: :ok | {:error, ClassificationAdapterError.t()}
  def gate_state(%ClassificationRequest{state: state}) when is_list(state) do
    if Enum.all?(state, &is_binary/1) do
      :ok
    else
      {:error,
       ClassificationAdapterError.new(:invalid_request,
         provider: :typesafe,
         message: "a list state must hold only strings",
         metadata: %{field: :state}
       )}
    end
  end

  def gate_state(%ClassificationRequest{}), do: :ok

  @doc false
  # Decodes a 2xx body. Any mismatch with the questions asked is
  # `:malformed_response` (adapter invariants 2–5).
  @spec decode_response(term(), term(), ClassificationRequest.t(), keyword()) ::
          {:ok, ClassificationResponse.t()} | {:error, ClassificationAdapterError.t()}
  def decode_response(body, headers, request, opts)

  def decode_response(
        %{"answers" => answers} = body,
        headers,
        %ClassificationRequest{} = request,
        opts
      )
      when is_map(answers) do
    with :ok <- check_answer_ids(answers, request.questions, opts),
         {:ok, decoded} <- decode_answers(answers, request.questions, opts) do
      {:ok,
       %ClassificationResponse{
         id: HTTPResponse.header_value(headers, "x-typesafe-request-id"),
         request_id: Keyword.get(opts, :request_id),
         model: model_of(body, request),
         provider: :typesafe,
         answers: decoded,
         usage: build_usage(body),
         raw: body,
         metadata: request.metadata
       }}
    end
  end

  def decode_response(body, _headers, _request, opts) when is_map(body) do
    {:error,
     malformed_error(
       ~s(missing or non-object "answers" field),
       %{body_keys: body |> Map.keys() |> Enum.sort()},
       opts
     )}
  end

  def decode_response(_body, _headers, _request, opts) do
    {:error, malformed_error("non-JSON body", %{}, opts)}
  end

  @doc false
  # Builds the error for a non-2xx response. `key` is the resolved API key,
  # removed literally from every provider-authored string.
  @spec to_classification_adapter_error(integer(), term(), term(), String.t() | nil, keyword()) ::
          ClassificationAdapterError.t()
  def to_classification_adapter_error(status, body, headers, key, opts)
      when is_integer(status) do
    decoded = HTTPResponse.decode_json_error_body(body)
    error_type = error_type(decoded)
    redact = &redact_key_material(&1, key)

    {reason, retry_after} =
      classify_classification_reason(status, error_type, HTTPResponse.retry_after_ms(headers))

    message =
      case extract_error_message(decoded) do
        nil -> "TypeSafe HTTP #{status}"
        text -> redact.(text)
      end

    ClassificationAdapterError.new(reason,
      provider: :typesafe,
      status: status,
      retry_after_ms: retry_after,
      message: message,
      metadata:
        HTTPResponse.build_metadata(
          %{
            status: status,
            typesafe_error_type: HTTPResponse.redact_optional(error_type, redact),
            typesafe_request_id:
              HTTPResponse.redact_optional(
                HTTPResponse.header_value(headers, "x-typesafe-request-id"),
                redact
              )
          },
          opts
        )
    )
  end

  @doc false
  # `(status, detail.error_type, retry_after_ms) -> {reason, retry_after_ms}`.
  @spec classify_classification_reason(integer(), term(), non_neg_integer() | nil) ::
          {ClassificationAdapterError.reason(), non_neg_integer() | nil}
  def classify_classification_reason(status, error_type, retry_after_ms)

  def classify_classification_reason(401, _type, _ra), do: {:authentication_failed, nil}
  def classify_classification_reason(403, _type, _ra), do: {:authentication_failed, nil}
  def classify_classification_reason(429, _type, ra), do: {:rate_limited, ra}

  def classify_classification_reason(status, @context_length_error_type, _ra)
      when status in [400, 422],
      do: {:context_length_exceeded, nil}

  def classify_classification_reason(status, _type, _ra) when status in [400, 404, 422],
    do: {:invalid_request, nil}

  def classify_classification_reason(status, _type, ra)
      when status in [500, 502, 503, 504, 529],
      do: {:provider_unavailable, ra}

  def classify_classification_reason(_status, _type, _ra), do: {:unknown, nil}

  @doc false
  # Removes the literal resolved key (only when it is at least 8 bytes),
  # then any `apikey_…`-shaped token.
  @spec redact_key_material(String.t(), String.t() | nil) :: String.t()
  def redact_key_material(message, key) when is_binary(message) do
    message
    |> redact_literal(key)
    |> Redact.typesafe()
  end

  # ---------------------------------------------------------------------------
  # Internals — gates and request build
  # ---------------------------------------------------------------------------

  defp fetch_classification_script(opts) do
    opts
    |> Keyword.get(:adapter_opts, [])
    |> Keyword.get(:classification_script)
  end

  defp gate_empty_questions(%ClassificationRequest{questions: questions}, _opts)
       when is_map(questions) and map_size(questions) > 0,
       do: :ok

  defp gate_empty_questions(%ClassificationRequest{}, opts) do
    {:error, invalid_request("questions must be a non-empty map", %{field: :questions}, opts)}
  end

  defp limit_error(id, %ClassificationQuestion{type: :choice, criteria: c}, opts)
       when is_map(c) and map_size(c) > @max_choice_options,
       do: over_limit(id, "options", map_size(c), @max_choice_options, opts)

  defp limit_error(id, %ClassificationQuestion{type: :score, criteria: c}, opts)
       when is_list(c) and length(c) > @max_score_levels,
       do: over_limit(id, "levels", length(c), @max_score_levels, opts)

  defp limit_error(_id, _question, _opts), do: nil

  defp over_limit(id, noun, count, limit, opts) do
    {:error,
     invalid_request(
       "question #{inspect(id)} has #{count} #{noun}; TypeSafe accepts at most #{limit}",
       %{question: id, limit: limit},
       opts
     )}
  end

  # A tuple map KEY raises `Protocol.UndefinedError` and an improper list
  # raises `FunctionClauseError` from inside `Jason.encode/1`, so both are
  # rescued. The exception is never kept: it can carry the caller's data.
  defp encode_body(request, opts) do
    result =
      try do
        request |> to_json_body(opts) |> Jason.encode()
      rescue
        _ -> :error
      end

    case result do
      {:ok, encoded} ->
        {:ok, encoded}

      _ ->
        {:error,
         invalid_request(
           "the request body cannot be JSON-encoded",
           %{cause: :unencodable_body},
           opts
         )}
    end
  end

  defp build_request(encoded, api_key, opts) do
    req =
      Req.new(
        method: :post,
        url: @base_url <> @endpoint,
        headers: [
          {"authorization", "Bearer " <> api_key},
          {"content-type", "application/json"}
        ],
        body: encoded,
        retry: false
      )
      |> HTTPResponse.maybe_apply_req_test_stub(opts)
      |> HTTPResponse.maybe_apply_request_timeout(opts)

    {:ok, req}
  end

  defp question_to_wire(%ClassificationQuestion{type: type} = q) do
    %{"type" => Map.get(@wire_types, type, type), "instructions" => q.instructions}
    |> put_criteria(type, q.criteria)
  end

  defp question_to_wire(other), do: other

  defp put_criteria(wire, :yes_no, nil), do: wire
  defp put_criteria(wire, _type, criteria), do: Map.put(wire, "criteria", criteria)

  defp invalid_request(message, metadata, opts) do
    ClassificationAdapterError.new(:invalid_request,
      provider: :typesafe,
      message: message,
      metadata: HTTPResponse.build_metadata(metadata, opts)
    )
  end

  defp stub_error(opts) do
    ClassificationAdapterError.new(:unknown,
      provider: :typesafe,
      message: "prepare_request/2 has no analogue under the classification_script short-circuit",
      metadata: HTTPResponse.build_metadata(%{cause: :scripted_adapter}, opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — the one HTTP attempt
  # ---------------------------------------------------------------------------

  defp run_one_attempt(http_req, request, opts) do
    case Req.request(http_req) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        decode_response(body, headers, request, opts)

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:error,
         to_classification_adapter_error(status, body, headers, request_key(http_req), opts)}

      {:error, %{__struct__: Req.TransportError, reason: :timeout}} ->
        {:error, transport_error(:timeout, "request timed out", :timeout, opts)}

      {:error, %{__struct__: Jason.DecodeError}} ->
        {:error, malformed_error("response body is not valid JSON", %{}, opts)}

      {:error, %{__struct__: Req.TransportError, reason: reason}} ->
        {:error,
         transport_error(:network_error, "transport failure: #{inspect(reason)}", reason, opts)}

      {:error, _other} ->
        {:error, transport_error(:network_error, "transport failure", nil, opts)}
    end
  end

  # The key is read back off the prepared request rather than threaded
  # through, so `classify/2` resolves it exactly once.
  defp request_key(%Req.Request{headers: headers}) do
    case HTTPResponse.header_value(headers, "authorization") do
      "Bearer " <> key -> key
      _ -> nil
    end
  end

  defp transport_error(reason, message, transport_reason, opts) do
    metadata =
      if is_atom(transport_reason) and not is_nil(transport_reason),
        do: %{transport_reason: transport_reason},
        else: %{}

    ClassificationAdapterError.new(reason,
      provider: :typesafe,
      message: message,
      metadata: HTTPResponse.build_metadata(metadata, opts)
    )
  end

  # ---------------------------------------------------------------------------
  # Internals — error bodies
  # ---------------------------------------------------------------------------

  defp error_type(%{"detail" => %{"error_type" => type}}) when is_binary(type), do: type
  defp error_type(_body), do: nil

  # The three `detail` shapes TypeSafe was observed sending. The FastAPI
  # list's `input` echo is never read: it is the caller's own data.
  defp extract_error_message(%{"detail" => detail}) when is_binary(detail) and detail != "",
    do: detail

  defp extract_error_message(%{"detail" => %{"message" => message}})
       when is_binary(message) and message != "",
       do: message

  defp extract_error_message(%{"detail" => [_ | _] = entries}) do
    case Enum.flat_map(entries, &validation_message/1) do
      [] -> nil
      messages -> Enum.join(messages, "; ")
    end
  end

  defp extract_error_message(_body), do: nil

  # FastAPI's `loc` is a list of strings and integers. Any other segment
  # (an object, a nested list) drops the `loc` prefix rather than reaching
  # `to_string/1`, which raises on it (adapter invariant 1).
  defp validation_message(%{"msg" => msg} = entry) when is_binary(msg) do
    case Map.get(entry, "loc") do
      [_ | _] = loc ->
        if Enum.all?(loc, &(is_binary(&1) or is_integer(&1))),
          do: [Enum.map_join(loc, ".", &to_string/1) <> ": " <> msg],
          else: [msg]

      _ ->
        [msg]
    end
  end

  defp validation_message(_entry), do: []

  defp redact_literal(message, key)
       when is_binary(key) and byte_size(key) >= @min_literal_key_bytes,
       do: String.replace(message, key, "[REDACTED]")

  defp redact_literal(message, _key), do: message

  # ---------------------------------------------------------------------------
  # Internals — response decoding
  # ---------------------------------------------------------------------------

  defp check_answer_ids(answers, questions, opts) when is_map(questions) do
    asked = questions |> Map.keys() |> MapSet.new()
    got = answers |> Map.keys() |> MapSet.new()

    cond do
      MapSet.equal?(asked, got) ->
        :ok

      not MapSet.subset?(asked, got) ->
        missing = asked |> MapSet.difference(got) |> Enum.sort()
        {:error, malformed_error("no answer for question(s) #{inspect(missing)}", %{}, opts)}

      true ->
        extra = got |> MapSet.difference(asked) |> Enum.sort()
        {:error, malformed_error("answer(s) for unasked id(s) #{inspect(extra)}", %{}, opts)}
    end
  end

  defp check_answer_ids(_answers, _questions, opts),
    do: {:error, malformed_error("the request carried no questions map", %{}, opts)}

  defp decode_answers(answers, questions, opts) do
    answers
    |> Enum.sort_by(fn {id, _a} -> id end)
    |> Enum.reduce_while({:ok, %{}}, fn {id, answer}, {:ok, acc} ->
      case decode_answer(answer, Map.fetch!(questions, id)) do
        {:ok, decoded} ->
          {:cont, {:ok, Map.put(acc, id, decoded)}}

        {:error, why} ->
          {:halt, {:error, malformed_error("answer #{inspect(id)}: #{why}", %{question: id}, opts)}}
      end
    end)
  end

  defp decode_answer(%{"type" => wire_type} = answer, %ClassificationQuestion{} = question) do
    case Map.get(@answer_types, wire_type) do
      nil ->
        {:error, "unknown answer type #{inspect(wire_type)}"}

      type when type == question.type ->
        decode_typed(type, answer, question.criteria)

      type ->
        {:error,
         "answer type #{inspect(type)} differs from question type #{inspect(question.type)}"}
    end
  end

  defp decode_answer(_answer, %ClassificationQuestion{}),
    do: {:error, "answer is not an object with a \"type\""}

  defp decode_answer(_answer, _question),
    do: {:error, "the question is not a ClassificationQuestion"}

  defp decode_typed(:choice, answer, criteria) do
    options = if is_map(criteria), do: criteria |> Map.keys() |> Enum.sort(), else: nil

    with {:ok, choice} <- fetch_binary(answer, "choice"),
         {:ok, probs} <- fetch_float_map(answer, "probabilities"),
         {:ok, confidence} <- fetch_unit(answer, "confidence"),
         :ok <- check_options(choice, probs, options) do
      {:ok,
       ClassificationAnswer.new(
         type: :choice,
         choice: choice,
         probabilities: probs,
         confidence: confidence
       )}
    end
  end

  defp decode_typed(:score, answer, criteria) do
    levels = if is_list(criteria), do: length(criteria), else: nil

    with {:ok, score} <- fetch_float(answer, "score"),
         {:ok, confidence} <- fetch_unit(answer, "confidence"),
         {:ok, level_probs} <- fetch_level_list(answer, "probabilities", levels),
         {:ok, probs} <- float_list(level_probs, "probabilities"),
         {:ok, legend} <- fetch_level_list(answer, "legend", length(probs)),
         :ok <- check_score_range(score, length(probs)) do
      {:ok,
       ClassificationAnswer.new(
         type: :score,
         score: score,
         probabilities: probs,
         legend: legend,
         confidence: confidence
       )}
    end
  end

  defp decode_typed(:yes_no, answer, _criteria) do
    with {:ok, p} <- fetch_unit(answer, "noul") do
      {:ok, ClassificationAnswer.new(type: :yes_no, yes_probability: p)}
    end
  end

  # Every probability and confidence the decoder returns is range-checked:
  # a value outside 0..1 is `:malformed_response`, like a non-number.
  defp fetch_unit(answer, key) do
    with {:ok, p} <- fetch_float(answer, key),
         :ok <- check_unit(p, key),
         do: {:ok, p}
  end

  defp fetch_binary(answer, key) do
    case Map.get(answer, key) do
      v when is_binary(v) -> {:ok, v}
      _ -> {:error, "#{inspect(key)} is not a string"}
    end
  end

  defp fetch_float(answer, key) do
    case Map.get(answer, key) do
      v when is_number(v) -> {:ok, v * 1.0}
      _ -> {:error, "#{inspect(key)} is not a number"}
    end
  end

  defp fetch_float_map(answer, key) do
    case Map.get(answer, key) do
      m when is_map(m) -> float_map(m, key)
      _ -> {:error, "#{inspect(key)} is not an object"}
    end
  end

  defp float_map(m, key) do
    if Enum.all?(m, fn {_k, v} -> unit?(v) end),
      do: {:ok, Map.new(m, fn {k, v} -> {k, v * 1.0} end)},
      else: {:error, "#{inspect(key)} holds a value that is not a number in 0..1"}
  end

  # The score-path sibling of `float_map/2`: a level value that is not a
  # number in 0..1 is `:malformed_response`, never a raise (adapter invariant 1).
  defp float_list(list, key) do
    if Enum.all?(list, &unit?/1),
      do: {:ok, Enum.map(list, &(&1 * 1.0))},
      else: {:error, "#{inspect(key)} holds a value that is not a number in 0..1"}
  end

  defp unit?(v), do: is_number(v) and v >= 0 and v <= 1

  # A score's `probabilities` / `legend`, keyed "0".."n-1", as a list where
  # index = level. `n` is the question's level count when known; a key gap,
  # an extra key or a wrong count is an error.
  defp fetch_level_list(answer, key, n) do
    with m when is_map(m) <- Map.get(answer, key),
         count = if(is_integer(n), do: n, else: map_size(m)),
         true <- map_size(m) == count,
         {:ok, list} <- ordered_levels(m, count) do
      {:ok, list}
    else
      _ -> {:error, level_list_error(key, n)}
    end
  end

  defp level_list_error(key, n) when is_integer(n) and n > 0,
    do: "#{inspect(key)} is not keyed by level \"0\"..\"#{n - 1}\""

  defp level_list_error(key, _n),
    do: "#{inspect(key)} is not an object keyed by level \"0\", \"1\", …"

  defp ordered_levels(_m, 0), do: :error

  defp ordered_levels(m, count) do
    values = Enum.map(0..(count - 1), &Map.fetch(m, Integer.to_string(&1)))

    if Enum.all?(values, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(values, fn {:ok, v} -> v end)},
      else: :error
  end

  defp check_options(_choice, _probs, nil), do: :ok

  defp check_options(choice, probs, options) do
    cond do
      choice not in options ->
        {:error, "choice #{inspect(choice)} is not an option"}

      Enum.sort(Map.keys(probs)) != options ->
        {:error, "probabilities keys differ from the options"}

      true ->
        :ok
    end
  end

  defp check_score_range(score, n) when score >= 0.0 and score <= n - 1, do: :ok
  defp check_score_range(score, n), do: {:error, "score #{score} is outside 0..#{n - 1}"}

  defp check_unit(p, _key) when p >= 0.0 and p <= 1.0, do: :ok
  defp check_unit(p, key), do: {:error, "#{inspect(key)} #{p} is outside 0..1"}

  defp model_of(body, request) do
    case Map.get(body, "model") do
      m when is_binary(m) -> m
      _ -> request.model || @default_model
    end
  end

  defp build_usage(body) do
    usage = if is_map(body["usage"]), do: body["usage"], else: %{}
    input = non_neg_int(usage["input_tokens"])
    output = non_neg_int(usage["output_tokens"])

    %Usage{
      input_tokens: input,
      output_tokens: output,
      total_tokens: if(is_integer(input) and is_integer(output), do: input + output)
    }
  end

  defp non_neg_int(n) when is_integer(n) and n >= 0, do: n
  defp non_neg_int(_n), do: nil

  defp malformed_error(detail, metadata, opts) do
    ClassificationAdapterError.new(:malformed_response,
      provider: :typesafe,
      message: "could not parse TypeSafe classification response: " <> detail,
      metadata: HTTPResponse.build_metadata(metadata, opts)
    )
  end
end
