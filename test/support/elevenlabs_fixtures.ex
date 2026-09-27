defmodule ALLM.Providers.ElevenLabsTestFixtures do
  @moduledoc """
  Loaders for the ElevenLabs audio wire fixtures under
  `test/fixtures/elevenlabs/` (Phase 26.6).

  `recorded/` files are live responses written by
  `scripts/record_elevenlabs_audio_fixtures.exs` and carry no `_comment`
  marker. `synthesized/` files each carry one. The loaders strip it with
  `ALLM.Providers.OpenAITestFixtures.drop_comment/1`, so a provenance
  assertion must read the raw file bytes instead of going through a loader.

  Envelopes use the Phase 25 shape: `{"status", "headers", "header_names"?,
  "body_base64", "byte_size", "sha256"}` for audio and
  `{"status", "headers", "header_names"?, "body"}` for JSON. Decode audio
  with `ALLM.Providers.OpenAITestFixtures.envelope_bytes/1`.
  """

  alias ALLM.Providers.OpenAITestFixtures

  @fixtures_root "test/fixtures/elevenlabs"

  @typedoc "A decoded fixture envelope."
  @type envelope :: map()

  @doc "Load `speech/recorded/<name>.json`."
  @spec speech_recorded(atom()) :: envelope()
  def speech_recorded(name) when is_atom(name), do: load("speech/recorded", name)

  @doc "Load `speech/synthesized/<name>.json`, without its `_comment` marker."
  @spec speech_synthesized(atom()) :: envelope()
  def speech_synthesized(name) when is_atom(name), do: load("speech/synthesized", name)

  @doc "Load `transcriptions/recorded/<name>.json`."
  @spec transcription_recorded(atom()) :: envelope()
  def transcription_recorded(name) when is_atom(name), do: load("transcriptions/recorded", name)

  @doc "Load `transcriptions/synthesized/<name>.json`, without its `_comment` marker."
  @spec transcription_synthesized(atom()) :: envelope()
  def transcription_synthesized(name) when is_atom(name),
    do: load("transcriptions/synthesized", name)

  @doc """
  Load `speech_stream/recorded/<name>.json` (Phase 26.7): the `/stream`
  envelope with `"chunks"`, or a WebSocket session
  `{"status", "url", "frames", "summary"}`. A frame's `dir` is from the
  server's side: `"in"` is a client frame, `"out"` a server frame.
  """
  @spec speech_stream_recorded(atom()) :: envelope()
  def speech_stream_recorded(name) when is_atom(name), do: load("speech_stream/recorded", name)

  @doc """
  The server frames of a recorded WebSocket session, as
  `ALLM.Test.WebSocketStub` server frames: `{:text, json}` and
  `{:close, code, reason}`. The recorder keeps only the first audio frame's
  bytes; every later `"<N bytes>"` placeholder becomes N zero bytes, so the
  replayed audio has the recorded length.
  """
  @spec ws_server_frames(envelope()) :: [tuple()]
  def ws_server_frames(%{"frames" => frames}) do
    for %{"dir" => "out"} = frame <- frames,
        server_frame = to_server_frame(frame),
        server_frame != nil,
        do: server_frame
  end

  defp to_server_frame(%{"text" => text}) do
    case Jason.decode!(text) do
      %{"audio" => "<" <> placeholder} = payload ->
        {n, " bytes>"} = Integer.parse(placeholder)
        {:text, Jason.encode!(%{payload | "audio" => Base.encode64(:binary.copy(<<0>>, n))})}

      _ ->
        {:text, text}
    end
  end

  defp to_server_frame(%{"close" => [code, reason]}), do: {:close, code, reason}
  defp to_server_frame(%{"closed" => true}), do: :closed
  defp to_server_frame(_frame), do: nil

  @doc "The raw decoded JSON of a fixture file, `_comment` included (for provenance tests)."
  @spec raw(String.t(), String.t()) :: map()
  def raw(dir, name) do
    [@fixtures_root, dir, name <> ".json"] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  @doc "The base names of every `.json` file under `<dir>`, sorted."
  @spec names_on_disk(String.t()) :: [String.t()]
  def names_on_disk(dir) do
    [@fixtures_root, dir, "*.json"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.sort()
  end

  @doc """
  A `Req.Test` plug body that replays an envelope: its status, every
  recorded header, and the body bytes (audio decoded from base64, JSON
  re-encoded).
  """
  @spec replay(Plug.Conn.t(), envelope()) :: Plug.Conn.t()
  def replay(conn, env) do
    body =
      case env do
        %{"body_base64" => _} -> OpenAITestFixtures.envelope_bytes(env)
        %{"body" => b} -> Jason.encode!(b)
      end

    env
    |> Map.get("headers", %{})
    |> Enum.reduce(conn, fn {k, v}, acc -> Plug.Conn.put_resp_header(acc, k, v) end)
    |> Plug.Conn.send_resp(env["status"], body)
  end

  defp load(dir, name) do
    [@fixtures_root, dir, "#{name}.json"]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
    |> OpenAITestFixtures.drop_comment()
  end
end
