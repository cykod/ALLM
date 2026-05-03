=== Provider: gemini ===
--- 01_plain_text.exs ---

02:00:27.205 [info] Loading .env file /workspaces/ALLM/.env
OK: plain_text — output="OK" finish=stop
--- 02_streaming_text.exs ---

02:00:28.253 [info] Loading .env file /workspaces/ALLM/.env
delta stream: OK
OK: streaming_text — deltas=1 completed=1 reduced="OK"
--- 03_single_tool_call.exs ---

02:00:29.094 [info] Loading .env file /workspaces/ALLM/.env
OK: single_tool_call — steps=2 tool_msgs=1 final="OK. The weather in Boston is sunny."
--- 04_parallel_tool_calls.exs ---

02:00:30.752 [info] Loading .env file /workspaces/ALLM/.env
OK: parallel_tool_calls — tool_msgs=2 steps=2 final="The weather in Boston is currently sunny, and the local time in Tokyo is 12:00."
--- 05_multi_turn_chat.exs ---

02:00:32.302 [info] Loading .env file /workspaces/ALLM/.env
OK: multi_turn_chat — t1_msgs=2 t2_msgs=4 t2_text="14"
--- 06_structured_output.exs ---

02:00:34.155 [info] Loading .env file /workspaces/ALLM/.env
OK: structured_output — decoded={:ok, %{"message" => "OK"}} pass_1=nil
--- 07_manual_tool_round_trip.exs ---

02:00:35.510 [info] Loading .env file /workspaces/ALLM/.env
OK: manual_tool_round_trip — pass1=:manual_tool_calls pending=1 pass2=completed final="The weather in Boston is sunny."
--- 08_session_round_trip.exs ---

02:00:36.727 [info] Loading .env file /workspaces/ALLM/.env
OK: session_round_trip — both paths produced "PING" (binary length=687)
--- 09_ask_user.exs ---

02:00:39.192 [info] Loading .env file /workspaces/ALLM/.env
OK: ask_user — pass1=:ask_user ("Which city?") pass2=:completed final="sunny"
--- 10_generate_image.exs ---

02:00:41.307 [info] Loading .env file /workspaces/ALLM/.env

02:00:41.307 [info] Loading .env file /workspaces/ALLM/.env
OK: generate_image — images=1 usage.images=1 bytes=902976 path=/tmp/10_generate_image_1777773694903.jpg
--- 11_edit_image.exs ---

02:01:34.905 [info] Loading .env file /workspaces/ALLM/.env

02:01:34.905 [info] Loading .env file /workspaces/ALLM/.env
OK: edit_image — images=1 usage.images=1 bytes=494327 path=/tmp/11_edit_image_1777773707917.jpg
--- 12_vision_input.exs ---

02:01:47.922 [info] Loading .env file /workspaces/ALLM/.env

02:01:47.923 [debug] ALLM.Providers.Gemini: ImagePart.detail is not supported by Gemini; dropping. This warning fires once per process.
OK: vision_input — finish=stop output="An American Kestrel perches on a pine branch in this minimalist watercolor paint"
[SKIP] 13_image_variations.exs (provider gate)

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
