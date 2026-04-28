# RUN_OUTPUT_OPENAI.md

Captured stdout of `OPENAI_API_KEY=… ALLM_PROVIDER=openai mix run examples/run_all.exs`.

## Phase 15.6 snapshot — 2026-04-28 (`01_*` through `10_*`)

```
=== Provider: openai ===
--- 01_plain_text.exs ---

03:05:38.338 [info] Loading .env file /workspaces/ALLM/.env
OK: plain_text — output="OK" finish=stop
--- 02_streaming_text.exs ---

03:05:40.497 [info] Loading .env file /workspaces/ALLM/.env
delta stream: OK
OK: streaming_text — deltas=1 completed=1 reduced="OK"
--- 03_single_tool_call.exs ---

03:05:41.969 [info] Loading .env file /workspaces/ALLM/.env
OK: single_tool_call — steps=2 tool_msgs=1 final="sunny"
--- 04_parallel_tool_calls.exs ---

03:05:43.597 [info] Loading .env file /workspaces/ALLM/.env
OK: parallel_tool_calls — tool_msgs=2 steps=2 final="- **Boston weather:** Sunny.  \n- **Tokyo local time:** 12:00."
--- 05_multi_turn_chat.exs ---

03:05:45.323 [info] Loading .env file /workspaces/ALLM/.env
OK: multi_turn_chat — t1_msgs=2 t2_msgs=4 t2_text="14"
--- 06_structured_output.exs ---

03:05:47.955 [info] Loading .env file /workspaces/ALLM/.env
OK: structured_output — decoded={:ok, %{"message" => "OK"}} pass_1=nil
--- 07_manual_tool_round_trip.exs ---

03:05:48.983 [info] Loading .env file /workspaces/ALLM/.env
OK: manual_tool_round_trip — pass1=:manual_tool_calls pending=1 pass2=completed final="sunny"
--- 08_session_round_trip.exs ---

03:05:50.594 [info] Loading .env file /workspaces/ALLM/.env
OK: session_round_trip — both paths produced "PING" (binary length=687)
--- 09_ask_user.exs ---

03:05:52.253 [info] Loading .env file /workspaces/ALLM/.env
OK: ask_user — pass1=:ask_user ("Which city?") pass2=:completed final="sunny"
--- 10_generate_image.exs ---

03:05:55.140 [info] Loading .env file /workspaces/ALLM/.env

03:05:55.140 [info] Loading .env file /workspaces/ALLM/.env
OK: generate_image — images=1 usage.images=1 bytes=197143 path=/tmp/10_generate_image_1777345564752.png

=== Summary (provider: openai) ===
[OK]   01_plain_text.exs
[OK]   02_streaming_text.exs
[OK]   03_single_tool_call.exs
[OK]   04_parallel_tool_calls.exs
[OK]   05_multi_turn_chat.exs
[OK]   06_structured_output.exs
[OK]   07_manual_tool_round_trip.exs
[OK]   08_session_round_trip.exs
[OK]   09_ask_user.exs
[OK]   10_generate_image.exs
```

On the Anthropic arm (`ALLM_PROVIDER=anthropic mix run examples/run_all.exs`)
the image script is skipped via the `# Provider: openai` header marker:

```
[SKIP] 10_generate_image.exs (provider gate)
…
[SKIP] 10_generate_image.exs
```
