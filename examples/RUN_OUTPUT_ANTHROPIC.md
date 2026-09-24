=== Provider: anthropic ===
--- 01_plain_text.exs ---

10:11:42.087 [info] Loading .env file /workspaces/ALLM/.env
OK: plain_text — output="OK" finish=stop
--- 02_streaming_text.exs ---

10:11:43.821 [info] Loading .env file /workspaces/ALLM/.env
delta stream: OK
OK: streaming_text — deltas=1 completed=1 reduced="OK"
--- 03_single_tool_call.exs ---

10:11:45.462 [info] Loading .env file /workspaces/ALLM/.env
OK: single_tool_call — steps=2 tool_msgs=1 final="The weather forecast for Boston is **sunny**! 🌞 Enjoy the nice weather!"
--- 04_parallel_tool_calls.exs ---

10:11:49.230 [info] Loading .env file /workspaces/ALLM/.env
OK: parallel_tool_calls — tool_msgs=2 steps=2 final="Here's a quick summary:\n\n- **Boston Weather:** It's currently **sunny** in Boston — great weather to head outside!\n- **Tokyo Local Time:** The current local time in Tokyo is **12:00 PM** (noon)."
--- 05_multi_turn_chat.exs ---

10:11:54.655 [info] Loading .env file /workspaces/ALLM/.env
OK: multi_turn_chat — t1_msgs=2 t2_msgs=4 t2_text="14"
--- 06_structured_output.exs ---

10:11:57.025 [info] Loading .env file /workspaces/ALLM/.env
OK: structured_output — decoded={:ok, %{"message" => "OK"}} pass_1=nil
--- 07_manual_tool_round_trip.exs ---

10:11:59.371 [info] Loading .env file /workspaces/ALLM/.env
OK: manual_tool_round_trip — pass1=:manual_tool_calls pending=1 pass2=completed final="The weather forecast for Boston is **sunny**!"
--- 08_session_round_trip.exs ---

10:12:02.601 [info] Loading .env file /workspaces/ALLM/.env
OK: session_round_trip — both paths produced "PING" (binary length=687)
--- 09_ask_user.exs ---

10:12:05.983 [info] Loading .env file /workspaces/ALLM/.env
OK: ask_user — pass1=:ask_user ("Which city?") pass2=:completed final="The weather in Boston is **sunny**! 🌞"
[SKIP] 10_generate_image.exs (provider gate)
[SKIP] 11_edit_image.exs (provider gate)
--- 12_vision_input.exs ---

10:12:10.612 [info] Loading .env file /workspaces/ALLM/.env

10:12:10.622 [debug] ALLM.Providers.Anthropic: ImagePart.detail is not supported by Anthropic; dropping. This warning fires once per process.
OK: vision_input — finish=stop output="A kestrel perches on a frost-covered evergreen branch in a misty winter landscap"
--- 14_per_tool_manual.exs ---

10:12:12.428 [info] Loading .env file /workspaces/ALLM/.env
OK: per_tool_manual — pass1=:manual_tool_calls manual_pending=1 pass2=completed final="Here are the results from both tool calls:\n\n---\n\n### 🌤️ Boston Weather Forecast\nThe weather result returned verbatim:\n> **{\"forecast\":\"sunny\",\"city\":\"Boston\"}**\n\nBoston is looking **sunny**! Great day to be outside. ☀️\n\n---\n\n### 🗑️ Delete Confirmation\nThe confirmation result returned verbatim:\n> **{\"status\":\"approved\",\"action\":\"delete\"}**\n\nThe delete action has been **approved**. ✅ Proceeding with the deletion as confirmed.\n\n---\n\nLet me know if you need anything else!"
--- 15_per_tool_manual_session.exs ---

10:12:18.764 [info] Loading .env file /workspaces/ALLM/.env
OK: per_tool_manual_session — start=:awaiting_tools pending=1 submit=:idle continue=:completed final="Here are the results from both tool calls:\n\n---\n\n### 🌤️ Boston Weather Forecast\nThe weather forecast returned verbatim:\n> **{\"forecast\":\"sunny\",\"city\":\"Boston\"}**\n\nBoston is looking **sunny**! Great weather ahead. ☀️\n\n---\n\n### 🗑️ Delete Confirmation\nThe confirmation action returned:\n> **{\"status\":\"approved\",\"action\":\"delete\"}**\n\nThe delete action has been **approved**. ✅ Proceeding with the deletion is now confirmed by the user.\n\n---\n\nLet me know if you'd like to take any further steps!"
--- 16_embed_single.exs ---

10:12:25.169 [info] Loading .env file /workspaces/ALLM/.env

10:12:25.170 [info] Loading .env file /workspaces/ALLM/.env
OK: embed single — dimensions=1024 index=0 chunk_count=1 total_tokens=16 model="voyage-3.5-lite"
--- 17_embed_batch_chunked.exs ---

10:12:25.978 [info] Loading .env file /workspaces/ALLM/.env

10:12:25.979 [info] Loading .env file /workspaces/ALLM/.env
OK: embed batch — inputs=250 embeddings=250 cap=1000 chunk_count=1 dimensions=1024
--- 18_embed_query_vs_document.exs ---

10:12:27.661 [info] Loading .env file /workspaces/ALLM/.env

10:12:27.661 [info] Loading .env file /workspaces/ALLM/.env
OK: query vs document — dimensions=1024 on_topic=0.7112 off_topic=0.3519
[SKIP] 19_moderate_text.exs (provider gate)
[SKIP] 20_moderate_image.exs (provider gate)
--- 21_compact_tools.exs ---

10:12:28.791 [info] Loading .env file /workspaces/ALLM/.env

10:12:32.501 [info] Loading .env file /workspaces/ALLM/.env
compact run: steps=2 tool_calls=["create_issue"]
full run:    steps=2 tool_calls=["create_issue"] halted=:completed
recorded: tool_help_first=false (first call: "create_issue")
recorded: labels_is_array=true (create_issue args: %{"labels" => ["bug"], "repo" => "acme/web", "title" => "Login button broken"})
recorded: run_total_input_tokens compact=2243 full=3933
recorded: run_total_output_tokens compact=161 full=177
OK: compact_tools — step1_input_tokens compact=1054 full=1899 (44% fewer)
[SKIP] 23_synthesize_speech.exs (provider gate)
[SKIP] 24_transcribe_audio.exs (provider gate)

=== Summary (provider: anthropic) ===
[OK]   01_plain_text.exs
[OK]   02_streaming_text.exs
[OK]   03_single_tool_call.exs
[OK]   04_parallel_tool_calls.exs
[OK]   05_multi_turn_chat.exs
[OK]   06_structured_output.exs
[OK]   07_manual_tool_round_trip.exs
[OK]   08_session_round_trip.exs
[OK]   09_ask_user.exs
[SKIP] 10_generate_image.exs
[SKIP] 11_edit_image.exs
[OK]   12_vision_input.exs
[OK]   14_per_tool_manual.exs
[OK]   15_per_tool_manual_session.exs
[OK]   16_embed_single.exs
[OK]   17_embed_batch_chunked.exs
[OK]   18_embed_query_vs_document.exs
[SKIP] 19_moderate_text.exs
[SKIP] 20_moderate_image.exs
[OK]   21_compact_tools.exs
[SKIP] 23_synthesize_speech.exs
[SKIP] 24_transcribe_audio.exs
