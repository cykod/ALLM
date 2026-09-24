defmodule ALLM.AudioSizeStatTest do
  # async: false — `:erlang.trace_pattern/3` is VM-global state. Trace
  # messages go only to this test's collector, but the pattern itself is
  # shared, so this module must not overlap another that sets it.
  use ExUnit.Case, async: false

  alias ALLM.Audio

  # Every read of a file's contents goes through one of these: `File.read/1`
  # and `File.read!/1` call `:file.read_file/1`; `File.open/2` and
  # `File.stream!/2` call `:file.open/2`.
  @read_mfas [{:file, :read_file, :_}, {:file, :open, :_}]

  # Runs `fun` with call tracing on the read functions and returns the
  # `{m, f, args}` of each traced call. A process cannot usefully be its own
  # tracer, so a separate collector receives the trace messages.
  defp traced_reads(fun) do
    collector = spawn_link(fn -> collect([]) end)
    Enum.each(@read_mfas, &:erlang.trace_pattern(&1, true, []))
    :erlang.trace(self(), true, [:call, {:tracer, collector}])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      Enum.each(@read_mfas, &:erlang.trace_pattern(&1, false, []))
    end

    ref = :erlang.trace_delivered(self())
    assert_receive {:trace_delivered, _, ^ref}
    send(collector, {:done, self()})
    assert_receive {:calls, calls}
    calls
  end

  defp collect(acc) do
    receive do
      {:done, reply_to} -> send(reply_to, {:calls, Enum.reverse(acc)})
      {:trace, _pid, :call, mfa} -> collect([mfa | acc])
    end
  end

  test "size/1 on a {:file, path} source stats the file and never reads it" do
    path =
      Path.join(System.tmp_dir!(), "allm_audio_stat_#{System.unique_integer([:positive])}.bin")

    File.write!(path, :binary.copy(<<9>>, 2048))
    on_exit(fn -> File.rm(path) end)
    audio = Audio.from_file(path)

    assert traced_reads(fn -> assert Audio.size(audio) == {:ok, 2048} end) == []

    # Control: the same harness does see a read, so the empty list above is
    # not an artifact of tracing catching nothing.
    assert [{:file, :read_file, [^path | _]}] =
             traced_reads(fn -> assert {:ok, _} = Audio.to_binary(audio) end)
  end
end
