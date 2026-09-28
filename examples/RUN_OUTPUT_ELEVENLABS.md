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
[SKIP] 22_classify_ticket.exs (provider gate)
--- 23_synthesize_speech.exs ---

18:35:34.071 [info] Loading .env file /workspaces/ALLM/.env

18:35:34.073 [info] Loading .env file /workspaces/ALLM/.env

18:35:34.075 [info] Loading .env file /workspaces/ALLM/.env
OK: synthesize speech — bytes=45601 format=:mp3 mime=audio/mpeg model="eleven_flash_v2_5" path=/tmp/allm_example_23_7043.mp3
--- 24_transcribe_audio.exs ---

18:35:36.321 [info] Loading .env file /workspaces/ALLM/.env

18:35:36.324 [info] Loading .env file /workspaces/ALLM/.env
OK: transcribe audio — text="The quick brown fox jumps over the lazy dog" model="scribe_v2" duration_seconds=3.72 input_tokens=nil output_tokens=nil
OK: transcribe audio with spans — spans=17 words=9 first=The@0.14s(-0.0) quick@0.32s(-0.0) brown@0.72s(-0.0) fox@1.16s(-0.0) mean_logprob=-2.4542568250277934e-5
--- 25_stream_speech.exs ---

18:35:38.629 [info] Loading .env file /workspaces/ALLM/.env

18:35:38.630 [info] Loading .env file /workspaces/ALLM/.env

18:35:38.638 [info] Loading .env file /workspaces/ALLM/.env
OK: stream speech — deltas=53 bytes=249660 sample_rate=24000 first_chunk_ms=433 total_ms=604 model="eleven_flash_v2_5" path=/tmp/allm_example_25_8130.pcm
--- 26_stream_transcribe.exs ---

18:35:39.856 [info] Loading .env file /workspaces/ALLM/.env

18:35:39.857 [info] Loading .env file /workspaces/ALLM/.env
  partial:   "The quick,"
  partial:   "The quick brown fox."
  committed: "The quick brown fox jumps over the lazy dog." spans=17
OK: stream transcribe — text="The quick brown fox jumps over the lazy dog." model="scribe_v2_realtime" chunks=38 sample_rate=24000 duration_seconds=3.8 words=9 first_word="The"@0.1s
--- 27_voice_loop.exs ---

18:35:41.267 [info] Loading .env file /workspaces/ALLM/.env

18:35:41.268 [info] Loading .env file /workspaces/ALLM/.env

18:35:41.270 [info] Loading .env file /workspaces/ALLM/.env

18:35:41.271 [info] Loading .env file /workspaces/ALLM/.env
  heard:  "The quick brown fox jumps over the lazy dog."

18:35:42.166 [info] Loading .env file /workspaces/ALLM/.env
OK: voice loop — heard="The quick brown fox jumps over the lazy dog." reply_deltas=7 reply_bytes=182788 sample_rate=24000 stt_first_transcript_ms=776 tts_first_audio_ms=2305
[SKIP] 28_prompt_cache.exs (provider gate)

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
[SKIP] 22_classify_ticket.exs
[OK]   23_synthesize_speech.exs
[OK]   24_transcribe_audio.exs
[OK]   25_stream_speech.exs
[OK]   26_stream_transcribe.exs
[OK]   27_voice_loop.exs
[SKIP] 28_prompt_cache.exs
