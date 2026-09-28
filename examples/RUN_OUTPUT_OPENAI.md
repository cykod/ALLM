=== Provider: openai ===
--- 01_plain_text.exs ---

12:06:54.215 [info] Loading .env file /workspaces/ALLM/.env
OK: plain_text — output="OK" finish=stop
--- 02_streaming_text.exs ---

12:06:55.896 [info] Loading .env file /workspaces/ALLM/.env
delta stream: OK
OK: streaming_text — deltas=1 completed=1 reduced="OK"
--- 03_single_tool_call.exs ---

12:06:57.162 [info] Loading .env file /workspaces/ALLM/.env
OK: single_tool_call — steps=2 tool_msgs=1 final="sunny"
--- 04_parallel_tool_calls.exs ---

12:06:59.533 [info] Loading .env file /workspaces/ALLM/.env
OK: parallel_tool_calls — tool_msgs=2 steps=2 final="- **Boston weather:** Sunny.  \n- **Tokyo local time:** 12:00."
--- 05_multi_turn_chat.exs ---

12:07:02.199 [info] Loading .env file /workspaces/ALLM/.env
OK: multi_turn_chat — t1_msgs=2 t2_msgs=4 t2_text="14"
--- 06_structured_output.exs ---

12:07:04.202 [info] Loading .env file /workspaces/ALLM/.env
OK: structured_output — decoded={:ok, %{"message" => "OK"}} pass_1=nil
--- 07_manual_tool_round_trip.exs ---

12:07:05.483 [info] Loading .env file /workspaces/ALLM/.env
OK: manual_tool_round_trip — pass1=:manual_tool_calls pending=1 pass2=completed final="sunny"
--- 08_session_round_trip.exs ---

12:07:08.832 [info] Loading .env file /workspaces/ALLM/.env
OK: session_round_trip — both paths produced "PING" (binary length=687)
--- 09_ask_user.exs ---

12:07:11.775 [info] Loading .env file /workspaces/ALLM/.env
OK: ask_user — pass1=:ask_user ("Which city?") pass2=:completed final="sunny"
--- 10_generate_image.exs ---

12:07:15.927 [info] Loading .env file /workspaces/ALLM/.env

12:07:15.928 [info] Loading .env file /workspaces/ALLM/.env
OK: generate_image — images=1 usage.images=1 bytes=1471060 path=/tmp/10_generate_image_1790597245336.png
--- 11_edit_image.exs ---

12:07:25.681 [info] Loading .env file /workspaces/ALLM/.env

12:07:25.682 [info] Loading .env file /workspaces/ALLM/.env
OK: edit_image — images=1 usage.images=1 bytes=1883082 path=/tmp/11_edit_image_1790597282978.png
--- 12_vision_input.exs ---

12:08:03.351 [info] Loading .env file /workspaces/ALLM/.env
OK: vision_input — finish=stop output="The image depicts a watercolor-style illustration of a bird perched on a branch "
--- 14_per_tool_manual.exs ---

12:08:05.338 [info] Loading .env file /workspaces/ALLM/.env
OK: per_tool_manual — pass1=:manual_tool_calls manual_pending=1 pass2=completed final="sunny\n\nDo you want me to proceed with deleting?"
--- 15_per_tool_manual_session.exs ---

12:08:07.670 [info] Loading .env file /workspaces/ALLM/.env
OK: per_tool_manual_session — start=:awaiting_tools pending=1 submit=:idle continue=:completed final="Boston weather forecast: **sunny**.\n\nDo you want me to proceed with the **delete** action?"
--- 16_embed_single.exs ---

12:08:11.057 [info] Loading .env file /workspaces/ALLM/.env

12:08:11.058 [info] Loading .env file /workspaces/ALLM/.env
OK: embed single — dimensions=1536 index=0 chunk_count=1 total_tokens=16 model="text-embedding-3-small"
--- 17_embed_batch_chunked.exs ---

12:08:11.977 [info] Loading .env file /workspaces/ALLM/.env

12:08:11.978 [info] Loading .env file /workspaces/ALLM/.env

12:08:12.019 [debug] ALLM.Providers.OpenAI.Embeddings: task_type :search_document is not supported by OpenAI's /v1/embeddings endpoint; dropping.
OK: embed batch — inputs=250 embeddings=250 cap=2048 chunk_count=1 dimensions=1536
--- 18_embed_query_vs_document.exs ---

12:08:13.971 [info] Loading .env file /workspaces/ALLM/.env

12:08:13.972 [info] Loading .env file /workspaces/ALLM/.env

12:08:14.012 [debug] ALLM.Providers.OpenAI.Embeddings: task_type :search_document is not supported by OpenAI's /v1/embeddings endpoint; dropping.

12:08:14.406 [debug] ALLM.Providers.OpenAI.Embeddings: task_type :search_query is not supported by OpenAI's /v1/embeddings endpoint; dropping.
OK: query vs document — dimensions=1536 on_topic=0.6738 off_topic=0.1237
--- 19_moderate_text.exs ---

12:08:15.110 [info] Loading .env file /workspaces/ALLM/.env

12:08:15.110 [info] Loading .env file /workspaces/ALLM/.env
OK: moderate text — results=2 clean_flagged=false threat_flagged=true categories=["harassment", "harassment/threatening", "violence"] top_score=0.5267 model="omni-moderation-latest" id="modr-9784"
--- 20_moderate_image.exs ---

12:08:16.176 [info] Loading .env file /workspaces/ALLM/.env

12:08:16.177 [info] Loading .env file /workspaces/ALLM/.env
OK: moderate image — multimodal=true input_elements=2 results=1 index=0 flagged=false categories_scored=13 applied_to_image=["self-harm", "self-harm/instructions", "self-harm/intent", "sexual", "violence", "violence/graphic"] model="omni-moderation-latest"
--- 21_compact_tools.exs ---

12:08:17.141 [info] Loading .env file /workspaces/ALLM/.env

12:08:19.165 [info] Loading .env file /workspaces/ALLM/.env
compact run: steps=2 tool_calls=["create_issue"]
full run:    steps=2 tool_calls=["create_issue"] halted=:completed
recorded: tool_help_first=false (first call: "create_issue")
recorded: labels_is_array=true (create_issue args: %{"body" => "", "labels" => ["bug"], "repo" => "acme/web", "title" => "Login button broken"})
recorded: run_total_input_tokens compact=766 full=1636
recorded: run_total_output_tokens compact=80 full=136
OK: compact_tools — step1_input_tokens compact=348 full=755 (54% fewer)
[SKIP] 22_classify_ticket.exs (provider gate)
--- 23_synthesize_speech.exs ---

12:08:22.263 [info] Loading .env file /workspaces/ALLM/.env

12:08:22.264 [info] Loading .env file /workspaces/ALLM/.env

12:08:22.265 [info] Loading .env file /workspaces/ALLM/.env
OK: synthesize speech — bytes=57600 format=:mp3 mime=audio/mpeg model="gpt-4o-mini-tts" path=/tmp/allm_example_23_7490.mp3
--- 24_transcribe_audio.exs ---

12:08:23.840 [info] Loading .env file /workspaces/ALLM/.env

12:08:23.841 [info] Loading .env file /workspaces/ALLM/.env
OK: transcribe audio — text="The quick brown fox jumps over the lazy dog." model="gpt-transcribe" duration_seconds=4 input_tokens=nil output_tokens=nil
OK: transcribe audio with logprobs — tokens=10 first=["The", " quick", " brown", " fox"] mean_logprob=-3.77655029296875e-5
--- 25_stream_speech.exs ---

12:08:25.889 [info] Loading .env file /workspaces/ALLM/.env

12:08:25.890 [info] Loading .env file /workspaces/ALLM/.env

12:08:25.895 [info] Loading .env file /workspaces/ALLM/.env
OK: stream speech — deltas=15 bytes=259200 sample_rate=24000 first_chunk_ms=904 total_ms=2908 model="gpt-4o-mini-tts" path=/tmp/allm_example_25_8132.pcm
[SKIP] 26_stream_transcribe.exs (provider gate)
[SKIP] 27_voice_loop.exs (provider gate)
--- 28_prompt_cache.exs ---

12:08:29.167 [info] Loading .env file /workspaces/ALLM/.env
prompt_cache on openai (gpt-5.4-nano), session cook-mode-1790597309
  turn 1: input_tokens=6081 cached_input_tokens=0 cache_write_input_tokens=0 (cached 0%)
  turn 2: input_tokens=6109 cached_input_tokens=5888 cache_write_input_tokens=0 (cached 96%)
  turn 3: input_tokens=6139 cached_input_tokens=5888 cache_write_input_tokens=0 (cached 96%)
OK: prompt_cache — three turns; turn 2 cached=5888

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
[SKIP] 22_classify_ticket.exs
[OK]   23_synthesize_speech.exs
[OK]   24_transcribe_audio.exs
[OK]   25_stream_speech.exs
[SKIP] 26_stream_transcribe.exs
[SKIP] 27_voice_loop.exs
[OK]   28_prompt_cache.exs
