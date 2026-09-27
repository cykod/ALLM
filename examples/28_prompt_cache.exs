# examples/28_prompt_cache.exs
#
# Demonstrates: provider prompt caching on a long-lived `ALLM.Session`
#               ("cook mode"). The engine carries
#               `params: %{prompt_cache: %{retention: :long}}`; the session
#               has an id, which becomes the cache key where the provider
#               takes one (OpenAI). A ~5k-token system prompt (a braise
#               recipe) is the stable prefix; three short turns follow.
#               Each turn prints `input_tokens`, `cached_input_tokens` and
#               `cache_write_input_tokens` from `result.final_response.usage`.
# Spec section: §5.4 (`Request.prompt_cache`), §5.9a (`Usage` cache fields).
# Steering strategy: tight on shape, loose on hits. Asserted: every turn
#                    completes; on OpenAI and Anthropic turn 2 reports
#                    `cached_input_tokens` as an integer (not `nil`); on
#                    every turn where both are integers,
#                    `cached + (write || 0) <= input_tokens`. NOT asserted:
#                    that a turn actually hit. Provider caching is
#                    best-effort, so the hit ratio is printed, not required.
#                    On Gemini (implicit caching) `nil` means no hit and is
#                    allowed.
# Cost: three turns over a ~5k-token prefix; most of turns 2 and 3 are
#       cached reads where the provider hits. Under $0.02 on the default
#       models.
# Run with:    OPENAI_API_KEY=sk-... mix run examples/28_prompt_cache.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/28_prompt_cache.exs
#         OR:  GEMINI_API_KEY=...           ALLM_PROVIDER=gemini    mix run examples/28_prompt_cache.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)

provider = System.get_env("ALLM_PROVIDER", "openai")
engine = ExamplesHelpers.engine(params: %{prompt_cache: %{retention: :long}})

# A stable prefix well above every provider's minimum cacheable length.
steps =
  for i <- 1..90 do
    "Step #{i}. Sear the short ribs in batches over medium-high heat until deeply " <>
      "browned, soften the shallots and garlic in the rendered fat, deglaze with red " <>
      "wine, scrape up the fond, return the meat, cover and braise at 150 C for " <>
      "#{60 + rem(i * 13, 120)} minutes, keeping the liquid at a bare simmer."
  end

system =
  "You are a sous-chef in cook mode. Answer the cook in one short sentence. " <>
    "The recipe being cooked:\n\n" <> Enum.join(steps, "\n")

# The id is the session's identity and, with caching on, the OpenAI cache key.
session =
  ALLM.Session.new(id: "cook-mode-#{System.os_time(:second)}")
  |> ALLM.Session.append(ALLM.system(system))
  |> ALLM.Session.append(ALLM.user("What temperature is the braise?"))

report = fn turn, result ->
  u = result.final_response.usage

  ratio =
    if is_integer(u.cached_input_tokens) and is_integer(u.input_tokens) and u.input_tokens > 0,
      do: "#{round(100 * u.cached_input_tokens / u.input_tokens)}%",
      else: "n/a"

  IO.puts(
    "  turn #{turn}: input_tokens=#{inspect(u.input_tokens)} " <>
      "cached_input_tokens=#{inspect(u.cached_input_tokens)} " <>
      "cache_write_input_tokens=#{inspect(u.cache_write_input_tokens)} (cached #{ratio})"
  )

  if is_integer(u.input_tokens) and is_integer(u.cached_input_tokens) and
       u.cached_input_tokens + (u.cache_write_input_tokens || 0) > u.input_tokens do
    ExamplesHelpers.fail!("prompt_cache — turn #{turn}: cached + write > input (#{inspect(u)})")
  end

  u
end

unwrap = fn
  {:ok, session, result} ->
    {session, result}

  {:error, err} ->
    ExamplesHelpers.fail!("prompt_cache — turn failed: #{inspect(err)}")
end

IO.puts("prompt_cache on #{provider} (#{engine.model}), session #{session.id}")

{session, r1} = unwrap.(ALLM.Session.start(engine, session))
report.(1, r1)

{session, r2} = unwrap.(ALLM.Session.reply(engine, session, "How long for step 12?"))
u2 = report.(2, r2)

{_session, r3} = unwrap.(ALLM.Session.reply(engine, session, "And step 40?"))
report.(3, r3)

if provider in ["openai", "anthropic"] and is_nil(u2.cached_input_tokens) do
  ExamplesHelpers.fail!(
    "prompt_cache — turn 2 on #{provider} reported cached_input_tokens: nil; " <>
      "the adapter should report the provider's cache counter (0 on a miss)"
  )
end

IO.puts("OK: prompt_cache — three turns; turn 2 cached=#{inspect(u2.cached_input_tokens)}")
