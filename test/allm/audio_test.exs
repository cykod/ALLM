defmodule ALLM.AudioTest do
  use ExUnit.Case, async: true
  doctest ALLM.Audio

  alias ALLM.{Audio, Serializer}
  alias ALLM.Error.ValidationError

  @ext_to_mime [
    {".mp3", "audio/mpeg"},
    {".mp4", "audio/mp4"},
    {".m4a", "audio/mp4"},
    {".mpeg", "audio/mpeg"},
    {".mpga", "audio/mpeg"},
    {".wav", "audio/wav"},
    {".webm", "audio/webm"},
    {".ogg", "audio/ogg"},
    {".oga", "audio/ogg"},
    {".flac", "audio/flac"},
    {".aac", "audio/aac"},
    {".opus", "audio/opus"},
    {".aiff", "audio/aiff"}
  ]

  defp tmp_file!(bytes) do
    path =
      Path.join(System.tmp_dir!(), "allm_audio_#{System.unique_integer([:positive])}.bin")

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "from_file/1" do
    test "does not touch the filesystem — a nonexistent path builds fine" do
      path = "/definitely/not/here/clip.mp3"
      refute File.exists?(path)
      assert %Audio{source: {:file, ^path}, mime_type: "audio/mpeg"} = Audio.from_file(path)
    end

    for {ext, mime} <- @ext_to_mime do
      test "infers #{mime} for #{ext} (case-insensitive)" do
        assert Audio.from_file("/nope/clip" <> unquote(ext)).mime_type == unquote(mime)

        assert Audio.from_file("/nope/CLIP" <> String.upcase(unquote(ext))).mime_type ==
                 unquote(mime)
      end
    end

    test "an unknown extension leaves mime_type nil" do
      assert Audio.from_file("x.xyz").mime_type == nil
    end

    test "a missing extension leaves mime_type nil" do
      assert Audio.from_file("/tmp/noext").mime_type == nil
    end
  end

  describe "from_binary/2 and from_base64/2" do
    test "from_binary/2 stores bytes verbatim" do
      assert %Audio{source: {:binary, <<0, 255>>}, mime_type: "audio/wav", metadata: %{}} =
               Audio.from_binary(<<0, 255>>, "audio/wav")
    end

    test "from_base64/2 stores the encoded string verbatim, no decode" do
      assert %Audio{source: {:base64, "%%%"}, mime_type: "audio/mpeg"} =
               Audio.from_base64("%%%", "audio/mpeg")
    end
  end

  describe "struct construction" do
    test "struct!(ALLM.Audio, []) raises ArgumentError — :source is enforced" do
      assert_raise ArgumentError, fn -> struct!(Audio, []) end
    end
  end

  describe "to_binary/1" do
    test "{:binary, b} returns b" do
      assert Audio.to_binary(Audio.from_binary(<<1, 2, 3>>, "audio/wav")) == {:ok, <<1, 2, 3>>}
    end

    test "{:base64, s} decodes" do
      assert Audio.to_binary(Audio.from_base64(Base.encode64(<<9, 8>>), "audio/wav")) ==
               {:ok, <<9, 8>>}
    end

    test "{:base64, bad} returns {:error, :invalid_base64}" do
      assert Audio.to_binary(Audio.from_base64("%%%", "audio/wav")) == {:error, :invalid_base64}
    end

    test "{:file, path} reads the file" do
      path = tmp_file!(<<7, 7, 7>>)
      assert Audio.to_binary(Audio.from_file(path)) == {:ok, <<7, 7, 7>>}
    end

    test "{:file, missing} returns {:error, :enoent}" do
      assert Audio.to_binary(Audio.from_file("/definitely/not/here.mp3")) == {:error, :enoent}
    end

    test "an off-shape source returns {:error, :invalid_source}" do
      assert Audio.to_binary(%Audio{source: {:url, "https://example.com/a.mp3"}}) ==
               {:error, :invalid_source}

      assert Audio.to_binary(%Audio{source: nil}) == {:error, :invalid_source}
    end
  end

  describe "size/1" do
    test "{:binary, b} equals Kernel.byte_size/1 of the bytes" do
      bytes = :binary.copy(<<1>>, 1234)
      assert Audio.size(Audio.from_binary(bytes, "audio/wav")) == {:ok, Kernel.byte_size(bytes)}
    end

    test "{:base64, s} equals the decoded byte size" do
      bytes = :binary.copy(<<2>>, 77)

      assert Audio.size(Audio.from_base64(Base.encode64(bytes), "audio/wav")) ==
               {:ok, Kernel.byte_size(bytes)}
    end

    test "{:file, path} equals the byte size of File.read!/1, computed separately" do
      path = tmp_file!(:binary.copy(<<3>>, 4096))
      expected = path |> File.read!() |> Kernel.byte_size()
      assert Audio.size(Audio.from_file(path)) == {:ok, expected}
    end

    test "{:file, missing} returns {:error, :enoent}" do
      assert Audio.size(Audio.from_file("/definitely/not/here.mp3")) == {:error, :enoent}
    end

    test "{:file, directory} returns {:error, :eisdir}, agreeing with to_binary/1" do
      dir = System.tmp_dir!()
      assert Audio.to_binary(Audio.from_file(dir)) == {:error, :eisdir}
      assert Audio.size(Audio.from_file(dir)) == {:error, :eisdir}
    end

    test "{:base64, bad} returns {:error, :invalid_base64}" do
      assert Audio.size(Audio.from_base64("%%%", "audio/wav")) == {:error, :invalid_base64}
    end

    test "%Audio{source: {:url, _}} returns {:error, :invalid_source}" do
      assert Audio.size(%Audio{source: {:url, "x"}}) == {:error, :invalid_source}
    end
  end

  describe "Inspect" do
    test "renders a binary payload as a size, never the bytes" do
      rendered = inspect(Audio.from_binary(:binary.copy(<<0>>, 10_000), "audio/wav"))
      assert byte_size(rendered) < 200
      assert rendered =~ "10000 bytes"
      assert rendered =~ "audio/wav"
    end

    test "renders a base64 payload as a char count" do
      encoded = Base.encode64(:binary.copy(<<0>>, 3000))
      rendered = inspect(Audio.from_base64(encoded, "audio/wav"))
      assert byte_size(rendered) < 200
      assert rendered =~ "#{byte_size(encoded)} chars"
    end

    test "renders a file source with its path" do
      assert inspect(Audio.from_file("/tmp/clip.mp3")) =~ ~s("/tmp/clip.mp3")
    end
  end

  describe "serializability" do
    test "every source variant round-trips through :erlang.term_to_binary/1" do
      for audio <- [
            Audio.from_binary(<<0, 255, 1>>, "audio/wav"),
            Audio.from_base64("aGk=", "audio/mpeg"),
            %{Audio.from_file("/tmp/a.flac") | metadata: %{"k" => "v"}}
          ] do
        assert audio == audio |> :erlang.term_to_binary() |> :erlang.binary_to_term()
      end
    end

    test "JSON round-trip of {:binary, <<0, 255, 1>>} returns the same bytes" do
      audio = Audio.from_binary(<<0, 255, 1>>, "audio/wav")
      json = Serializer.to_json!(audio)

      assert json =~ Base.encode64(<<0, 255, 1>>)
      assert {:ok, ^audio} = Serializer.from_json(json)
    end

    test "JSON round-trip preserves base64 and file sources and string-keyed metadata" do
      for audio <- [
            Audio.from_base64("aGk=", "audio/mpeg"),
            %{Audio.from_file("/tmp/a.flac") | metadata: %{"k" => "v"}}
          ] do
        assert {:ok, ^audio} = audio |> Serializer.to_json!() |> Serializer.from_json()
      end
    end

    test "a binary source with invalid base64 surfaces {[:source], :invalid_base64}" do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.Audio",
          "data" => %{
            "source" => %{"type" => "binary", "value" => "%%%"},
            "mime_type" => "audio/wav",
            "metadata" => %{}
          }
        })

      assert {:error, %ValidationError{errors: errors}} = Serializer.from_json(json)
      assert {[:source], :invalid_base64} in errors
    end

    test "an unknown source type surfaces {:_unknown, :atom_decode_failed}" do
      json =
        Jason.encode!(%{
          "__type__" => "ALLM.Audio",
          "data" => %{"source" => %{"type" => "url", "value" => "x"}, "metadata" => %{}}
        })

      assert {:error, %ValidationError{errors: errors}} = Serializer.from_json(json)
      assert {:_unknown, :atom_decode_failed} in errors
    end
  end
end
