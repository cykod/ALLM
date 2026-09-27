defmodule ALLM.Test.PCM do
  @moduledoc """
  PCM16 helpers for the realtime transcription tests. Internal test support
  — NOT part of the published Hex package.

  `wav_pcm_chunks/2` reads a mono 16-bit WAV file's `data` chunk and slices
  it into pieces of `ms` milliseconds, the shape a microphone delivers.

  **Streaming WAVs.** `test/fixtures/audio/quick_brown_fox.wav` was written
  by a streaming encoder: its RIFF size and its `data` size are both
  `0xFFFFFFFF` ("unknown"). A reader that trusts the declared `data` size
  either raises or slices past the end of the file, so a `0xFFFFFFFF` (or
  any size longer than the file) means "to end of file" here.
  """

  @unknown_size 0xFFFFFFFF

  @doc """
  Return `{sample_rate, chunks}`: the WAV's sample rate from its `fmt `
  chunk, and its `data` chunk as consecutive binaries of
  `sample_rate * 2 * ms / 1000` bytes each (the last may be shorter).
  Raises unless the file is mono 16-bit PCM.
  """
  @spec wav_pcm_chunks(Path.t(), pos_integer()) :: {pos_integer(), [binary()]}
  def wav_pcm_chunks(path, ms) when is_integer(ms) and ms > 0 do
    <<"RIFF", _riff_size::little-32, "WAVE", rest::binary>> = File.read!(path)
    {rate, pcm} = read_chunks(rest, nil)
    size = div(rate * 2 * ms, 1000)
    {rate, slice(pcm, size)}
  end

  defp read_chunks(<<"fmt ", size::little-32, body::binary-size(size), rest::binary>>, _rate) do
    <<1::little-16, 1::little-16, rate::little-32, _byte_rate::little-32, _align::little-16,
      16::little-16, _::binary>> = body

    read_chunks(rest, rate)
  end

  defp read_chunks(<<"data", size::little-32, rest::binary>>, rate) when is_integer(rate) do
    if size == @unknown_size or size > byte_size(rest),
      do: {rate, rest},
      else: {rate, binary_part(rest, 0, size)}
  end

  defp read_chunks(<<_id::binary-size(4), size::little-32, rest::binary>>, rate) do
    <<_skipped::binary-size(size), rest::binary>> = rest
    read_chunks(rest, rate)
  end

  defp slice(pcm, size) when byte_size(pcm) <= size, do: [pcm]

  defp slice(pcm, size) do
    <<chunk::binary-size(size), rest::binary>> = pcm
    [chunk | slice(rest, size)]
  end
end
