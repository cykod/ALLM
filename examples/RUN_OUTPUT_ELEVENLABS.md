=== Provider: elevenlabs ===
[SKIP] 01_plain_text.exs (provider gate)
[SKIP] 02_streaming_text.exs (provider gate)
[SKIP] 03_single_tool_call.exs (provider gate)
[SKIP] 04_parallel_tool_calls.exs (provider gate)
[SKIP] 05_multi_turn_chat.exs (provider gate)
[SKIP] 06_structured_output.exs (provider gate)
[SKIP] 07_manual_tool_round_trip.exs (provider gate)
[SKIP] 08_session_round_trip.exs (provider gate)
[SKIP] 09_ask_user.exs (provider gate)
[SKIP] 10_generate_image.exs (provider gate)
[SKIP] 11_edit_image.exs (provider gate)
[SKIP] 12_vision_input.exs (provider gate)
[SKIP] 14_per_tool_manual.exs (provider gate)
[SKIP] 15_per_tool_manual_session.exs (provider gate)
[SKIP] 16_embed_single.exs (provider gate)
[SKIP] 17_embed_batch_chunked.exs (provider gate)
[SKIP] 18_embed_query_vs_document.exs (provider gate)
[SKIP] 19_moderate_text.exs (provider gate)
[SKIP] 20_moderate_image.exs (provider gate)
[SKIP] 21_compact_tools.exs (provider gate)
--- 23_synthesize_speech.exs ---

12:40:01.125 [info] Loading .env file /workspaces/ALLM/.env

12:40:01.126 [info] Loading .env file /workspaces/ALLM/.env

12:40:01.128 [info] Loading .env file /workspaces/ALLM/.env
OK: synthesize speech — bytes=45601 format=:mp3 mime=audio/mpeg model="eleven_flash_v2_5" path=/tmp/allm_example_23_4739.mp3
--- 24_transcribe_audio.exs ---

12:40:02.130 [info] Loading .env file /workspaces/ALLM/.env

12:40:02.131 [info] Loading .env file /workspaces/ALLM/.env
OK: transcribe audio — text="The quick brown fox jumps over the lazy dog" model="scribe_v2" duration_seconds=3.72 input_tokens=nil output_tokens=nil
--- 25_stream_speech.exs ---

12:40:03.259 [info] Loading .env file /workspaces/ALLM/.env

12:40:03.260 [info] Loading .env file /workspaces/ALLM/.env

12:40:03.265 [info] Loading .env file /workspaces/ALLM/.env
OK: stream speech — deltas=24 bytes=247432 sample_rate=24000 first_chunk_ms=468 total_ms=623 model="eleven_flash_v2_5" path=/tmp/allm_example_25_7938.pcm
--- 26_stream_transcribe.exs ---

12:40:04.265 [info] Loading .env file /workspaces/ALLM/.env

12:40:04.266 [info] Loading .env file /workspaces/ALLM/.env
  partial:   "The quick,"
  partial:   "The quick brown fox."
  partial:   "The quick brown fox jumps over the"
  committed: "The quick brown fox jumps over the lazy dog."
OK: stream transcribe — text="The quick brown fox jumps over the lazy dog." model="scribe_v2_realtime" chunks=38 sample_rate=24000 duration_seconds=3.8
--- 27_voice_loop.exs ---

12:40:05.599 [info] Loading .env file /workspaces/ALLM/.env

12:40:05.600 [info] Loading .env file /workspaces/ALLM/.env

12:40:05.602 [info] Loading .env file /workspaces/ALLM/.env

12:40:05.602 [info] Loading .env file /workspaces/ALLM/.env
  heard:  "The quick brown fox jumps over the lazy dog."

12:40:06.548 [info] Loading .env file /workspaces/ALLM/.env
OK: voice loop — heard="The quick brown fox jumps over the lazy dog." reply_deltas=7 reply_bytes=156038 sample_rate=24000 stt_first_partial_ms=822 tts_first_audio_ms=1593

=== Summary (provider: elevenlabs) ===
[SKIP] 01_plain_text.exs
[SKIP] 02_streaming_text.exs
[SKIP] 03_single_tool_call.exs
[SKIP] 04_parallel_tool_calls.exs
[SKIP] 05_multi_turn_chat.exs
[SKIP] 06_structured_output.exs
[SKIP] 07_manual_tool_round_trip.exs
[SKIP] 08_session_round_trip.exs
[SKIP] 09_ask_user.exs
[SKIP] 10_generate_image.exs
[SKIP] 11_edit_image.exs
[SKIP] 12_vision_input.exs
[SKIP] 14_per_tool_manual.exs
[SKIP] 15_per_tool_manual_session.exs
[SKIP] 16_embed_single.exs
[SKIP] 17_embed_batch_chunked.exs
[SKIP] 18_embed_query_vs_document.exs
[SKIP] 19_moderate_text.exs
[SKIP] 20_moderate_image.exs
[SKIP] 21_compact_tools.exs
[OK]   23_synthesize_speech.exs
[OK]   24_transcribe_audio.exs
[OK]   25_stream_speech.exs
[OK]   26_stream_transcribe.exs
[OK]   27_voice_loop.exs
