# examples/21_compact_tools.exs
#
# Demonstrates: compact tools (`compact: true` on `ALLM.tool/1`). The eight
#               GitHub-style tools of `examples/fixtures/compact_tools.exs`
#               are sent to the model as one-line stubs plus one built-in
#               `tool_help` tool, and the model still files the issue the
#               prompt asks for. The same prompt then runs again with every
#               tool in full, and the two runs' step-1 input tokens are
#               compared.
# Spec section: §40 (compact tool disclosure), §5.2 (`:compact`, `:summary`).
# Steering strategy: tight on outcome, loose on route. Asserted: (a) the
#                    compact run completes; (b) `create_issue`'s handler ran
#                    with "repo" and "title" present; (c) step-1
#                    `input_tokens` is lower with compact tools than without.
#                    NOT asserted, only printed: whether the model called
#                    `tool_help` before `create_issue`, the run-total input
#                    tokens of both runs (a `tool_help` answer stays in the
#                    thread, so it can eat into the saving), and whether
#                    `labels` arrived as an array (a stub carries no types,
#                    and nothing checks them).
# Cost: two short chat runs. Measured 2026-09-22 on the default models:
#       2 steps per run and, for both runs combined, about 2.4k (OpenAI),
#       3.8k (Gemini) and 6.2k (Anthropic) input tokens, under 400 output
#       tokens.
# Run with:    OPENAI_API_KEY=sk-... mix run examples/21_compact_tools.exs                                # default
#         OR:  ANTHROPIC_API_KEY=sk-ant-... ALLM_PROVIDER=anthropic mix run examples/21_compact_tools.exs
#         OR:  GEMINI_API_KEY=...           ALLM_PROVIDER=gemini    mix run examples/21_compact_tools.exs

Application.ensure_all_started(:allm)
Code.require_file("_helpers.exs", __DIR__)
Code.require_file("fixtures/compact_tools.exs", __DIR__)

# Captures the arguments each `create_issue` call receives. Handlers may run
# outside the calling process, so an Agent rather than the process dictionary.
{:ok, calls} = Agent.start_link(fn -> [] end)

build_tools = fn compact? ->
  Enum.map(CompactToolsFixture.tools(), fn %{name: name} = spec ->
    handler =
      case name do
        "create_issue" ->
          fn args ->
            Agent.update(calls, &[{compact?, args} | &1])

            {:ok,
             %{number: 1347, url: "https://github.com/#{args["repo"]}/issues/1347", state: "open"}}
          end

        _ ->
          fn _args -> {:ok, %{ok: true, tool: name}} end
      end

    ALLM.tool(Map.to_list(spec) ++ [handler: handler, compact: compact?])
  end)
end

prompt = "File an issue in acme/web titled 'Login button broken' with label bug."

run = fn compact? ->
  engine = ExamplesHelpers.engine(tools: build_tools.(compact?))

  case ALLM.chat(engine, [ALLM.user(prompt)]) do
    {:ok, result} ->
      result

    {:error, err} ->
      ExamplesHelpers.fail!(
        "compact=#{compact?} chat returned an error: want {:ok, _}, got #{inspect(err)}"
      )
  end
end

input_tokens = fn %ALLM.StepResult{response: %ALLM.Response{usage: usage}} ->
  (usage && usage.input_tokens) || 0
end

tool_names = fn result ->
  for %ALLM.StepResult{response: %ALLM.Response{tool_calls: tcs}} <- result.steps,
      tc <- tcs || [],
      do: tc.name
end

compact = run.(true)
full = run.(false)

compact_args =
  calls
  |> Agent.get(& &1)
  |> Enum.reverse()
  |> Enum.filter(fn {compact?, _} -> compact? end)
  |> Enum.map(fn {_, args} -> args end)

compact_step1 = compact.steps |> hd() |> input_tokens.()
full_step1 = full.steps |> hd() |> input_tokens.()

# (a) the compact run completes.
unless compact.halted_reason == :completed do
  ExamplesHelpers.fail!(
    "(a) compact run: want halted_reason :completed, got #{inspect(compact.halted_reason)} " <>
      "after #{length(compact.steps)} steps (tool calls: #{inspect(tool_names.(compact))})"
  )
end

# (b) create_issue's handler ran with "repo" and "title".
unless Enum.any?(compact_args, &(is_map_key(&1, "repo") and is_map_key(&1, "title"))) do
  ExamplesHelpers.fail!(
    "(b) compact run: want a create_issue call with \"repo\" and \"title\", got " <>
      inspect(compact_args)
  )
end

# (c) compact tools cost fewer input tokens on step 1.
unless compact_step1 > 0 and compact_step1 < full_step1 do
  ExamplesHelpers.fail!(
    "(c) step-1 input_tokens: want 0 < compact < full, got compact=#{compact_step1} full=#{full_step1}"
  )
end

total = fn result -> result.steps |> Enum.map(input_tokens) |> Enum.sum() end

output = fn result ->
  Enum.sum(for s <- result.steps, do: (s.response.usage && s.response.usage.output_tokens) || 0)
end

first_tool = compact |> tool_names.() |> List.first()
issue_args = List.last(compact_args)

IO.puts("""
compact run: steps=#{length(compact.steps)} tool_calls=#{inspect(tool_names.(compact))}
full run:    steps=#{length(full.steps)} tool_calls=#{inspect(tool_names.(full))} halted=#{inspect(full.halted_reason)}
recorded: tool_help_first=#{first_tool == "tool_help"} (first call: #{inspect(first_tool)})
recorded: labels_is_array=#{is_list(issue_args["labels"])} (create_issue args: #{inspect(issue_args)})
recorded: run_total_input_tokens compact=#{total.(compact)} full=#{total.(full)}
recorded: run_total_output_tokens compact=#{output.(compact)} full=#{output.(full)}\
""")

IO.puts(
  "OK: compact_tools — step1_input_tokens compact=#{compact_step1} full=#{full_step1} " <>
    "(#{round((1 - compact_step1 / full_step1) * 100)}% fewer)"
)
