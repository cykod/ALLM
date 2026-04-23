defmodule ALLM.EventPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ALLM.{ChatResult, Event, Message, Response, Thread}

  @map_payload_tags ~w(
    message_started text_delta text_completed
    tool_call_started tool_call_delta tool_call_completed
    tool_execution_started tool_execution_completed tool_result_encoded
    ask_user_requested tool_halt
    message_completed step_completed chat_completed
  )a

  # --- generators ---------------------------------------------------------

  defp id_gen, do: StreamData.string(:alphanumeric, min_length: 1, max_length: 12)
  defp name_gen, do: StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
  defp text_gen, do: StreamData.string(:printable, max_length: 40)

  defp arguments_gen,
    do: StreamData.map_of(name_gen(), StreamData.one_of([text_gen(), StreamData.integer()]))

  defp event_gen do
    StreamData.one_of([
      # text_delta
      StreamData.bind(id_gen(), fn id ->
        StreamData.bind(text_gen(), fn d -> StreamData.constant(Event.text_delta(id, d)) end)
      end),
      # text_completed
      StreamData.bind(id_gen(), fn id ->
        StreamData.bind(text_gen(), fn t -> StreamData.constant(Event.text_completed(id, t)) end)
      end),
      # tool_call_started
      StreamData.bind(id_gen(), fn id ->
        StreamData.bind(name_gen(), fn n -> StreamData.constant(Event.tool_call_started(id, n)) end)
      end),
      # tool_call_delta
      StreamData.bind(id_gen(), fn id ->
        StreamData.bind(text_gen(), fn d -> StreamData.constant(Event.tool_call_delta(id, d)) end)
      end),
      # tool_call_completed
      StreamData.bind(id_gen(), fn id ->
        StreamData.bind(name_gen(), fn n ->
          StreamData.bind(arguments_gen(), fn args ->
            StreamData.bind(text_gen(), fn raw ->
              StreamData.constant(Event.tool_call_completed(id, n, args, raw))
            end)
          end)
        end)
      end),
      # tool_execution_started
      StreamData.bind(id_gen(), fn id ->
        StreamData.bind(name_gen(), fn n ->
          StreamData.bind(arguments_gen(), fn args ->
            StreamData.constant(Event.tool_execution_started(id, n, args))
          end)
        end)
      end),
      # tool_execution_completed
      StreamData.bind(id_gen(), fn id ->
        StreamData.bind(name_gen(), fn n ->
          StreamData.bind(text_gen(), fn r ->
            StreamData.constant(Event.tool_execution_completed(id, n, r))
          end)
        end)
      end),
      # tool_result_encoded
      StreamData.bind(id_gen(), fn id ->
        StreamData.bind(text_gen(), fn c ->
          StreamData.constant(Event.tool_result_encoded(id, c))
        end)
      end),
      # ask_user_requested
      StreamData.bind(id_gen(), fn id ->
        StreamData.bind(name_gen(), fn n ->
          StreamData.bind(text_gen(), fn q ->
            StreamData.constant(Event.ask_user_requested(id, n, q, []))
          end)
        end)
      end),
      # tool_halt
      StreamData.bind(id_gen(), fn id ->
        StreamData.bind(StreamData.member_of([:not_found, :custom, :other]), fn r ->
          StreamData.bind(text_gen(), fn result ->
            StreamData.constant(Event.tool_halt(id, r, result))
          end)
        end)
      end),
      # message_started
      StreamData.bind(text_gen(), fn c ->
        StreamData.constant(Event.message_started(%Message{role: :assistant, content: c}))
      end),
      # message_completed
      StreamData.bind(text_gen(), fn c ->
        StreamData.constant(Event.message_completed(%Message{role: :assistant, content: c}))
      end),
      # step_completed
      StreamData.bind(text_gen(), fn c ->
        StreamData.constant(Event.step_completed(%Response{output_text: c}, %Thread{messages: []}))
      end),
      # chat_completed
      StreamData.constant(
        Event.chat_completed(%ChatResult{
          thread: %Thread{},
          final_response: %Response{},
          halted_reason: :completed
        })
      ),
      # raw_chunk
      StreamData.bind(StreamData.term(), fn t -> StreamData.constant({:raw_chunk, t}) end),
      # error
      StreamData.bind(StreamData.term(), fn t -> StreamData.constant({:error, t}) end)
    ])
  end

  defp non_map_gen do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.string(:printable),
      StreamData.atom(:alphanumeric),
      StreamData.boolean(),
      StreamData.list_of(StreamData.integer(), max_length: 3),
      StreamData.constant(nil)
    ])
  end

  # --- properties ---------------------------------------------------------

  property "every generated event passes event?/1" do
    check all(ev <- event_gen()) do
      assert Event.event?(ev)
    end
  end

  property "every generated event round-trips through term_to_binary" do
    check all(ev <- event_gen()) do
      assert ev == ev |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    end
  end

  property "map-payload tags with non-map payloads are rejected" do
    check all(
            tag <- StreamData.member_of(@map_payload_tags),
            payload <- non_map_gen()
          ) do
      assert Event.event?({tag, payload}) == false
    end
  end
end
