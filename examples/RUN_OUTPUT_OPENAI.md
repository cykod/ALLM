=== Provider: openai ===
--- 01_plain_text.exs ---

10:10:08.207 [info] Loading .env file /workspaces/ALLM/.env
OK: plain_text — output="OK" finish=stop
--- 02_streaming_text.exs ---

10:10:10.087 [info] Loading .env file /workspaces/ALLM/.env
delta stream: OK
OK: streaming_text — deltas=1 completed=1 reduced="OK"
--- 03_single_tool_call.exs ---

10:10:11.530 [info] Loading .env file /workspaces/ALLM/.env
OK: single_tool_call — steps=2 tool_msgs=1 final="sunny"
--- 04_parallel_tool_calls.exs ---

10:10:14.853 [info] Loading .env file /workspaces/ALLM/.env
OK: parallel_tool_calls — tool_msgs=2 steps=2 final="- **Boston weather:** Sunny.  \n- **Tokyo local time:** 12:00."
--- 05_multi_turn_chat.exs ---

10:10:17.466 [info] Loading .env file /workspaces/ALLM/.env
OK: multi_turn_chat — t1_msgs=2 t2_msgs=4 t2_text="14"
--- 06_structured_output.exs ---

10:10:21.109 [info] Loading .env file /workspaces/ALLM/.env
OK: structured_output — decoded={:ok, %{"message" => "OK"}} pass_1=nil
--- 07_manual_tool_round_trip.exs ---

10:10:22.324 [info] Loading .env file /workspaces/ALLM/.env
OK: manual_tool_round_trip — pass1=:manual_tool_calls pending=1 pass2=completed final="sunny"
--- 08_session_round_trip.exs ---

10:10:24.878 [info] Loading .env file /workspaces/ALLM/.env
OK: session_round_trip — both paths produced "PING" (binary length=687)
--- 09_ask_user.exs ---

10:10:27.830 [info] Loading .env file /workspaces/ALLM/.env
OK: ask_user — pass1=:ask_user ("Which city?") pass2=:completed final="sunny"
--- 10_generate_image.exs ---

10:10:31.270 [info] Loading .env file /workspaces/ALLM/.env

10:10:31.272 [info] Loading .env file /workspaces/ALLM/.env
OK: generate_image — images=1 usage.images=1 bytes=1579075 path=/tmp/10_generate_image_1790244643087.png
--- 11_edit_image.exs ---

10:10:43.473 [info] Loading .env file /workspaces/ALLM/.env

10:10:43.473 [info] Loading .env file /workspaces/ALLM/.env
OK: edit_image — images=1 usage.images=1 bytes=2019945 path=/tmp/11_edit_image_1790244679546.png
--- 12_vision_input.exs ---

10:11:19.911 [info] Loading .env file /workspaces/ALLM/.env
OK: vision_input — finish=stop output="The image features a beautifully illustrated bird perched on a branch, set again"
--- 14_per_tool_manual.exs ---

10:11:22.238 [info] Loading .env file /workspaces/ALLM/.env
OK: per_tool_manual — pass1=:manual_tool_calls manual_pending=1 pass2=completed final="{\"forecast\":\"sunny\",\"city\":\"Boston\"}\n\nDo you want to proceed with deleting?"
--- 15_per_tool_manual_session.exs ---

10:11:25.068 [info] Loading .env file /workspaces/ALLM/.env
OK: per_tool_manual_session — start=:awaiting_tools pending=1 submit=:idle continue=:completed final="Boston weather forecast: **sunny**.\n\nDo you want me to proceed with the **delete** action?"
--- 16_embed_single.exs ---

10:11:28.077 [info] Loading .env file /workspaces/ALLM/.env

10:11:28.077 [info] Loading .env file /workspaces/ALLM/.env
OK: embed single — dimensions=1536 index=0 chunk_count=1 total_tokens=16 model="text-embedding-3-small"
--- 17_embed_batch_chunked.exs ---

10:11:29.092 [info] Loading .env file /workspaces/ALLM/.env

10:11:29.093 [info] Loading .env file /workspaces/ALLM/.env

10:11:29.104 [debug] ALLM.Providers.OpenAI.Embeddings: task_type :search_document is not supported by OpenAI's /v1/embeddings endpoint; dropping.
OK: embed batch — inputs=250 embeddings=250 cap=2048 chunk_count=1 dimensions=1536
--- 18_embed_query_vs_document.exs ---

10:11:31.179 [info] Loading .env file /workspaces/ALLM/.env

10:11:31.180 [info] Loading .env file /workspaces/ALLM/.env

10:11:31.191 [debug] ALLM.Providers.OpenAI.Embeddings: task_type :search_document is not supported by OpenAI's /v1/embeddings endpoint; dropping.

10:11:31.633 [debug] ALLM.Providers.OpenAI.Embeddings: task_type :search_query is not supported by OpenAI's /v1/embeddings endpoint; dropping.
OK: query vs document — dimensions=1536 on_topic=0.6738 off_topic=0.1236
--- 19_moderate_text.exs ---

10:11:32.349 [info] Loading .env file /workspaces/ALLM/.env

10:11:32.350 [info] Loading .env file /workspaces/ALLM/.env
OK: moderate text — results=2 clean_flagged=false threat_flagged=true categories=["harassment", "harassment/threatening", "violence"] top_score=0.5255 model="omni-moderation-latest" id="modr-5880"
--- 20_moderate_image.exs ---

10:11:33.030 [info] Loading .env file /workspaces/ALLM/.env

10:11:33.031 [info] Loading .env file /workspaces/ALLM/.env
OK: moderate image — multimodal=true input_elements=2 results=1 index=0 flagged=false categories_scored=13 applied_to_image=["self-harm", "self-harm/instructions", "self-harm/intent", "sexual", "violence", "violence/graphic"] model="omni-moderation-latest"
--- 21_compact_tools.exs ---

10:11:34.553 [info] Loading .env file /workspaces/ALLM/.env

10:11:36.506 [info] Loading .env file /workspaces/ALLM/.env
compact run: steps=2 tool_calls=["create_issue"]
full run:    steps=2 tool_calls=["create_issue"] halted=:completed
recorded: tool_help_first=false (first call: "create_issue")
recorded: labels_is_array=true (create_issue args: %{"body" => "", "labels" => ["bug"], "repo" => "acme/web", "title" => "Login button broken"})
recorded: run_total_input_tokens compact=766 full=1676
recorded: run_total_output_tokens compact=80 full=176
OK: compact_tools — step1_input_tokens compact=348 full=755 (54% fewer)
--- 23_synthesize_speech.exs ---

10:11:39.069 [info] Loading .env file /workspaces/ALLM/.env

10:11:39.070 [info] Loading .env file /workspaces/ALLM/.env
OK: synthesize speech — bytes=56832 format=:mp3 mime=audio/mpeg model="gpt-4o-mini-tts" path=/tmp/allm_example_23_6595.mp3
--- 24_transcribe_audio.exs ---

10:11:40.640 [info] Loading .env file /workspaces/ALLM/.env

10:11:40.641 [info] Loading .env file /workspaces/ALLM/.env
OK: transcribe audio — text="The quick brown fox jumps over the lazy dog." model="gpt-transcribe" duration_seconds=4 input_tokens=nil output_tokens=nil

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
[OK]   11_edit_image.exs
[OK]   12_vision_input.exs
[OK]   14_per_tool_manual.exs
[OK]   15_per_tool_manual_session.exs
[OK]   16_embed_single.exs
[OK]   17_embed_batch_chunked.exs
[OK]   18_embed_query_vs_document.exs
[OK]   19_moderate_text.exs
[OK]   20_moderate_image.exs
[OK]   21_compact_tools.exs
[OK]   23_synthesize_speech.exs
[OK]   24_transcribe_audio.exs
