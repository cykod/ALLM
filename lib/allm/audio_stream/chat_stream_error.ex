defmodule ALLM.AudioStream.ChatStreamError do
  @moduledoc false
  # Raised by `ALLM.AudioStream.text_deltas/1` when the chat stream it reads
  # carries an `{:error, err}` event. It carries only the chat error's reason
  # and message, never the error struct: the speech adapter's input pump
  # turns the raise into a `%{kind, message}` map (an atom and a string,
  # never the raw exception) on the speech
  # error's `:cause`, and the message below is what that map shows.

  defexception [:reason, :message]

  @impl Exception
  def exception(err) do
    reason = reason_of(err)

    %__MODULE__{
      reason: reason,
      message: "the chat stream failed (#{inspect(reason)}): #{detail_of(err)}"
    }
  end

  defp reason_of(%{reason: reason}) when is_atom(reason), do: reason
  defp reason_of(_other), do: :unknown

  defp detail_of(err) when is_exception(err), do: Exception.message(err)
  defp detail_of(err), do: inspect(err)
end
