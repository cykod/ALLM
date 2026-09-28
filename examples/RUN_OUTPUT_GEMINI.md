=== Provider: gemini ===
--- 01_plain_text.exs ---

12:05:22.091 [info] Loading .env file /workspaces/ALLM/.env
OK: plain_text — output="OK" finish=stop
--- 02_streaming_text.exs ---

12:05:23.975 [info] Loading .env file /workspaces/ALLM/.env
delta stream: OK
OK: streaming_text — deltas=1 completed=1 reduced="OK"
--- 03_single_tool_call.exs ---

12:05:25.667 [info] Loading .env file /workspaces/ALLM/.env
OK: single_tool_call — steps=2 tool_msgs=1 final="The weather in Boston is sunny."
--- 04_parallel_tool_calls.exs ---

12:05:28.567 [info] Loading .env file /workspaces/ALLM/.env
OK: parallel_tool_calls — tool_msgs=2 steps=2 final="The weather in Boston is currently sunny, and the local time in Tokyo is 12:00."
--- 05_multi_turn_chat.exs ---

12:05:31.678 [info] Loading .env file /workspaces/ALLM/.env
OK: multi_turn_chat — t1_msgs=2 t2_msgs=4 t2_text="14"
--- 06_structured_output.exs ---

12:05:35.153 [info] Loading .env file /workspaces/ALLM/.env
OK: structured_output — decoded={:ok, %{"message" => "OK"}} pass_1=nil
--- 07_manual_tool_round_trip.exs ---

12:05:37.508 [info] Loading .env file /workspaces/ALLM/.env
OK: manual_tool_round_trip — pass1=:manual_tool_calls pending=1 pass2=completed final="Sunny"
--- 08_session_round_trip.exs ---

12:05:40.165 [info] Loading .env file /workspaces/ALLM/.env
OK: session_round_trip — both paths produced "PING" (binary length=687)
--- 09_ask_user.exs ---

12:05:45.322 [info] Loading .env file /workspaces/ALLM/.env
OK: ask_user — pass1=:ask_user ("Which city?") pass2=:completed final="{\"forecast\":\"sunny\",\"city\":\"Boston\"}"
--- 10_generate_image.exs ---

12:05:49.613 [info] Loading .env file /workspaces/ALLM/.env

12:05:49.614 [info] Loading .env file /workspaces/ALLM/.env
OK: generate_image — images=1 usage.images=1 bytes=997673 path=/tmp/10_generate_image_1790597159086.jpg
--- 11_edit_image.exs ---

12:05:59.430 [info] Loading .env file /workspaces/ALLM/.env

12:05:59.431 [info] Loading .env file /workspaces/ALLM/.env
OK: edit_image — images=1 usage.images=1 bytes=539734 path=/tmp/11_edit_image_1790597168697.jpg
--- 12_vision_input.exs ---

12:06:09.045 [info] Loading .env file /workspaces/ALLM/.env

12:06:09.087 [debug] ALLM.Providers.Gemini: ImagePart.detail is not supported by Gemini; dropping. This warning fires once per process.
OK: vision_input — finish=stop output="A watercolor painting of a kestrel perched on a pine branch."
--- 14_per_tool_manual.exs ---

12:06:12.119 [info] Loading .env file /workspaces/ALLM/.env
OK: per_tool_manual — pass1=:manual_tool_calls manual_pending=1 pass2=completed final="sunny"
--- 15_per_tool_manual_session.exs ---

12:06:14.799 [info] Loading .env file /workspaces/ALLM/.env
OK: per_tool_manual_session — start=:awaiting_tools pending=1 submit=:idle continue=:completed final="The weather forecast for Boston is sunny."
--- 16_embed_single.exs ---

12:06:18.454 [info] Loading .env file /workspaces/ALLM/.env

12:06:18.454 [info] Loading .env file /workspaces/ALLM/.env
OK: embed single — dimensions=3072 index=0 chunk_count=1 total_tokens=nil model="gemini-embedding-001"
--- 17_embed_batch_chunked.exs ---

12:06:19.257 [info] Loading .env file /workspaces/ALLM/.env

12:06:19.258 [info] Loading .env file /workspaces/ALLM/.env
OK: embed batch — inputs=250 embeddings=250 cap=100 chunk_count=3 dimensions=3072
--- 18_embed_query_vs_document.exs ---

12:06:22.532 [info] Loading .env file /workspaces/ALLM/.env

12:06:22.533 [info] Loading .env file /workspaces/ALLM/.env
OK: query vs document — dimensions=3072 on_topic=0.7903 off_topic=0.5442
[SKIP] 19_moderate_text.exs (provider gate)
[SKIP] 20_moderate_image.exs (provider gate)
--- 21_compact_tools.exs ---

12:06:23.627 [info] Loading .env file /workspaces/ALLM/.env

12:06:25.853 [info] Loading .env file /workspaces/ALLM/.env
compact run: steps=2 tool_calls=["create_issue"]
full run:    steps=2 tool_calls=["create_issue"] halted=:completed
recorded: tool_help_first=false (first call: "create_issue")
recorded: labels_is_array=true (create_issue args: %{"labels" => ["bug"], "repo" => "acme/web", "title" => "Login button broken"})
recorded: run_total_input_tokens compact=1117 full=2769
recorded: run_total_output_tokens compact=51 full=61
OK: compact_tools — step1_input_tokens compact=471 full=1294 (64% fewer)
[SKIP] 22_classify_ticket.exs (provider gate)
[SKIP] 23_synthesize_speech.exs (provider gate)
--- 24_transcribe_audio.exs ---

12:06:28.664 [info] Loading .env file /workspaces/ALLM/.env

12:06:28.665 [info] Loading .env file /workspaces/ALLM/.env
OK: transcribe audio — text="The quick brown fox jumps over the lazy dog." model="gemini-flash-latest" duration_seconds=nil input_tokens=107 output_tokens=10
OK: transcribe audio with logprobs — refused locally on Gemini, as documented
[SKIP] 25_stream_speech.exs (provider gate)
[SKIP] 26_stream_transcribe.exs (provider gate)
[SKIP] 27_voice_loop.exs (provider gate)
--- 28_prompt_cache.exs ---

12:06:32.066 [info] Loading .env file /workspaces/ALLM/.env
prompt_cache on gemini (gemini-3-flash-preview), session cook-mode-1790597192
  turn 1: input_tokens=6581 cached_input_tokens=nil cache_write_input_tokens=nil (cached n/a)
  turn 2: input_tokens=6603 cached_input_tokens=4074 cache_write_input_tokens=nil (cached 62%)
  turn 3: input_tokens=6633 cached_input_tokens=4069 cache_write_input_tokens=nil (cached 61%)
OK: prompt_cache — three turns; turn 2 cached=4074

=== Summary (provider: gemini) ===
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
[OK]   11_edit_image.exs
[OK]   12_vision_input.exs
[OK]   14_per_tool_manual.exs
[OK]   15_per_tool_manual_session.exs
[OK]   16_embed_single.exs
[OK]   17_embed_batch_chunked.exs
[OK]   18_embed_query_vs_document.exs
[SKIP] 19_moderate_text.exs
[SKIP] 20_moderate_image.exs
[OK]   21_compact_tools.exs
[SKIP] 22_classify_ticket.exs
[SKIP] 23_synthesize_speech.exs
[OK]   24_transcribe_audio.exs
[SKIP] 25_stream_speech.exs
[SKIP] 26_stream_transcribe.exs
[SKIP] 27_voice_loop.exs
[OK]   28_prompt_cache.exs
