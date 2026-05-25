defmodule ALLM.UnwrapTest do
  @moduledoc """
  Phase 21.4 — `ALLM.unwrap/1` collapses the three-clause `generate/3`
  return into `{:ok, text} | {:error, term()}`.
  """

  use ExUnit.Case, async: true

  alias ALLM.{Engine, Message, Response}
  alias ALLM.Error.AdapterError
  alias ALLM.Providers.Fake

  describe "unwrap/1" do
    test "{:ok, %Response{finish_reason: :stop, output_text: text}} returns {:ok, text}" do
      resp = %Response{finish_reason: :stop, output_text: "hi"}
      assert ALLM.unwrap({:ok, resp}) == {:ok, "hi"}
    end

    test "falls back to message.content when output_text is nil" do
      msg = %Message{role: :assistant, content: "from-msg"}
      resp = %Response{finish_reason: :stop, output_text: nil, message: msg}
      assert ALLM.unwrap({:ok, resp}) == {:ok, "from-msg"}
    end

    test "{:error, %{}} pass-through preserves the error verbatim" do
      err = %AdapterError{reason: :rate_limited, message: "slow down"}
      assert ALLM.unwrap({:error, err}) == {:error, err}
    end

    test "finish_reason: :error returns {:error, e} from metadata.error" do
      err = %AdapterError{reason: :timeout, message: "took too long"}
      resp = %Response{finish_reason: :error, metadata: %{error: err}}
      assert ALLM.unwrap({:ok, resp}) == {:error, err}
    end

    test "finish_reason: :length returns {:error, {:non_stop_finish, :length}}" do
      resp = %Response{finish_reason: :length}
      assert ALLM.unwrap({:ok, resp}) == {:error, {:non_stop_finish, :length}}
    end

    test "finish_reason: :tool_calls returns {:error, {:non_stop_finish, :tool_calls}}" do
      resp = %Response{finish_reason: :tool_calls}
      assert ALLM.unwrap({:ok, resp}) == {:error, {:non_stop_finish, :tool_calls}}
    end

    test "structured-content message returns {:error, :structured_content}" do
      msg = %Message{
        role: :assistant,
        content: [%ALLM.TextPart{text: "hello"}]
      }

      resp = %Response{finish_reason: :stop, output_text: nil, message: msg}
      assert ALLM.unwrap({:ok, resp}) == {:error, :structured_content}
    end
  end

  describe "integration over Fake" do
    test "ALLM.generate(...) |> ALLM.unwrap() returns scripted text" do
      engine =
        Engine.new(
          adapter: Fake,
          adapter_opts: [script: [{:text, "scripted text"}, {:finish, :stop}]]
        )

      assert {:ok, "scripted text"} =
               engine
               |> ALLM.generate(ALLM.request([ALLM.user("hi")]))
               |> ALLM.unwrap()
    end
  end
end
