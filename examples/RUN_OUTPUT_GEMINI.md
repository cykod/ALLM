=== Provider: gemini ===
--- 01_plain_text.exs ---

03:03:54.261 [info] Loading .env file /workspaces/ALLM/.env
OK: plain_text — output="OK" finish=stop
--- 02_streaming_text.exs ---

03:03:55.474 [info] Loading .env file /workspaces/ALLM/.env
delta stream: OK
OK: streaming_text — deltas=1 completed=1 reduced="OK"
--- 03_single_tool_call.exs ---

03:03:56.270 [info] Loading .env file /workspaces/ALLM/.env
OK: single_tool_call — steps=2 tool_msgs=1 final="The weather in Boston is sunny."
--- 04_parallel_tool_calls.exs ---

03:03:58.158 [info] Loading .env file /workspaces/ALLM/.env
OK: parallel_tool_calls — tool_msgs=2 steps=2 final="The weather in Boston is currently sunny, and the local time in Tokyo is 12:00 PM."
--- 05_multi_turn_chat.exs ---

03:03:59.854 [info] Loading .env file /workspaces/ALLM/.env
OK: multi_turn_chat — t1_msgs=2 t2_msgs=4 t2_text="14"
--- 06_structured_output.exs ---

03:04:01.527 [info] Loading .env file /workspaces/ALLM/.env
OK: structured_output — decoded={:ok, %{"message" => "OK"}} pass_1=nil
--- 07_manual_tool_round_trip.exs ---

03:04:03.346 [info] Loading .env file /workspaces/ALLM/.env
OK: manual_tool_round_trip — pass1=:manual_tool_calls pending=1 pass2=completed final="The weather in Boston is sunny."
--- 08_session_round_trip.exs ---

03:04:04.744 [info] Loading .env file /workspaces/ALLM/.env
OK: session_round_trip — both paths produced "PING" (binary length=687)
--- 09_ask_user.exs ---

03:04:07.623 [info] Loading .env file /workspaces/ALLM/.env
OK: ask_user — pass1=:ask_user ("Which city?") pass2=:completed final="Boston is sunny."
--- 10_generate_image.exs ---

03:04:10.280 [info] Loading .env file /workspaces/ALLM/.env

03:04:10.280 [info] Loading .env file /workspaces/ALLM/.env
OK: generate_image — images=1 usage.images=1 bytes=1057053 path=/tmp/10_generate_image_1790219059227.jpg
--- 11_edit_image.exs ---

03:04:19.229 [info] Loading .env file /workspaces/ALLM/.env

03:04:19.230 [info] Loading .env file /workspaces/ALLM/.env
OK: edit_image — images=1 usage.images=1 bytes=404901 path=/tmp/11_edit_image_1790219066229.jpg
--- 12_vision_input.exs ---

03:04:26.233 [info] Loading .env file /workspaces/ALLM/.env

03:04:26.234 [debug] ALLM.Providers.Gemini: ImagePart.detail is not supported by Gemini; dropping. This warning fires once per process.
OK: vision_input — finish=stop output="A watercolor illustration of an American kestrel perched on an evergreen branch."
[SKIP] 13_image_variations.exs (provider gate)
--- 14_per_tool_manual.exs ---

03:04:28.194 [info] Loading .env file /workspaces/ALLM/.env
OK: per_tool_manual — pass1=:manual_tool_calls manual_pending=1 pass2=completed final="sunny"
--- 15_per_tool_manual_session.exs ---

03:04:30.327 [info] Loading .env file /workspaces/ALLM/.env
OK: per_tool_manual_session — start=:awaiting_tools pending=1 submit=:idle continue=:completed final="The weather forecast for Boston is sunny."
--- 16_embed_single.exs ---

03:04:32.702 [info] Loading .env file /workspaces/ALLM/.env

03:04:32.703 [info] Loading .env file /workspaces/ALLM/.env
OK: embed single — dimensions=3072 index=0 chunk_count=1 total_tokens=nil model="gemini-embedding-001"
--- 17_embed_batch_chunked.exs ---

03:04:32.908 [info] Loading .env file /workspaces/ALLM/.env

03:04:32.909 [info] Loading .env file /workspaces/ALLM/.env
OK: embed batch — inputs=250 embeddings=250 cap=100 chunk_count=3 dimensions=3072
--- 18_embed_query_vs_document.exs ---

03:04:35.997 [info] Loading .env file /workspaces/ALLM/.env

03:04:35.997 [info] Loading .env file /workspaces/ALLM/.env
OK: query vs document — dimensions=3072 on_topic=0.7903 off_topic=0.5442
[SKIP] 19_moderate_text.exs (provider gate)
[SKIP] 20_moderate_image.exs (provider gate)
--- 21_compact_tools.exs ---

03:04:36.463 [info] Loading .env file /workspaces/ALLM/.env

03:04:38.608 [info] Loading .env file /workspaces/ALLM/.env
compact run: steps=2 tool_calls=["create_issue"]
full run:    steps=2 tool_calls=["create_issue"] halted=:completed
recorded: tool_help_first=false (first call: "create_issue")
recorded: labels_is_array=true (create_issue args: %{"labels" => ["bug"], "repo" => "acme/web", "title" => "Login button broken"})
recorded: run_total_input_tokens compact=1129 full=2763
recorded: run_total_output_tokens compact=79 full=59
OK: compact_tools — step1_input_tokens compact=471 full=1294 (64% fewer)
[SKIP] 23_synthesize_speech.exs (provider gate)
--- 24_transcribe_audio.exs ---

03:04:40.613 [info] Loading .env file /workspaces/ALLM/.env

03:04:40.613 [info] Loading .env file /workspaces/ALLM/.env
OK: transcribe audio — text="The quick brown fox jumps over the lazy dog." model="gemini-flash-latest" duration_seconds=nil input_tokens=107 output_tokens=10

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
[SKIP] 13_image_variations.exs
[OK]   14_per_tool_manual.exs
[OK]   15_per_tool_manual_session.exs
[OK]   16_embed_single.exs
[OK]   17_embed_batch_chunked.exs
[OK]   18_embed_query_vs_document.exs
[SKIP] 19_moderate_text.exs
[SKIP] 20_moderate_image.exs
[OK]   21_compact_tools.exs
[SKIP] 23_synthesize_speech.exs
[OK]   24_transcribe_audio.exs
