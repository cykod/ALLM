defmodule ALLM.Providers.Support.HTTPResponseTest do
  @moduledoc """
  Unit tests for `ALLM.Providers.Support.HTTPResponse`, one describe block
  per extracted helper. The adapters' own suites pin each helper through
  its call sites; these pin the helper directly.
  """

  use ExUnit.Case, async: true

  alias ALLM.Providers.Support.HTTPResponse

  describe "header_value/2" do
    test "reads Req's lower-cased header map, taking the first of several values" do
      assert HTTPResponse.header_value(%{"x-request-id" => ["req_1", "req_2"]}, "x-request-id") ==
               "req_1"
    end

    test "matches a header-tuple list case-insensitively" do
      assert HTTPResponse.header_value([{"X-Request-Id", "req_9"}], "x-request-id") == "req_9"
    end

    test "absent headers, non-string names and non-string values are nil" do
      assert HTTPResponse.header_value(%{}, "x-request-id") == nil
      assert HTTPResponse.header_value([{:not_a_string, "x"}], "x-request-id") == nil
      assert HTTPResponse.header_value(%{"x-request-id" => [123]}, "x-request-id") == nil
      assert HTTPResponse.header_value(nil, "x-request-id") == nil
    end
  end

  describe "retry_after_ms/1" do
    test "delta-seconds become milliseconds, in either header shape" do
      assert HTTPResponse.retry_after_ms([{"retry-after", "2"}]) == 2_000
      assert HTTPResponse.retry_after_ms(%{"retry-after" => ["7"]}) == 7_000
      assert HTTPResponse.retry_after_ms([{"Retry-After", "0"}]) == 0
    end

    test "an HTTP-date, a negative number, junk and an absent header are all nil" do
      assert HTTPResponse.retry_after_ms([{"retry-after", "Wed, 21 Oct 2015 07:28:00 GMT"}]) ==
               nil

      assert HTTPResponse.retry_after_ms([{"retry-after", "-1"}]) == nil
      assert HTTPResponse.retry_after_ms([{"retry-after", "1.5"}]) == nil
      assert HTTPResponse.retry_after_ms([]) == nil
    end
  end

  describe "decode_error_body/1" do
    test "a map passes through; a binary or anything else becomes %{}" do
      assert HTTPResponse.decode_error_body(%{"error" => %{}}) == %{"error" => %{}}
      assert HTTPResponse.decode_error_body(~s({"error":{"message":"x"}})) == %{}
      assert HTTPResponse.decode_error_body(nil) == %{}
    end
  end

  describe "decode_json_error_body/1" do
    test "a map passes through and a JSON-object binary is decoded" do
      assert HTTPResponse.decode_json_error_body(%{"a" => 1}) == %{"a" => 1}

      assert HTTPResponse.decode_json_error_body(~s({"error":{"message":"x"}})) ==
               %{"error" => %{"message" => "x"}}
    end

    test "a non-object or invalid JSON binary, and any other term, become %{}" do
      assert HTTPResponse.decode_json_error_body("[1, 2]") == %{}
      assert HTTPResponse.decode_json_error_body("<html>") == %{}
      assert HTTPResponse.decode_json_error_body(nil) == %{}
    end
  end

  describe "error_object/1" do
    test "a map error is returned, a string error becomes a message, anything else %{}" do
      assert HTTPResponse.error_object(%{"error" => %{"code" => "x"}}) == %{"code" => "x"}
      assert HTTPResponse.error_object(%{"error" => "boom"}) == %{"message" => "boom"}
      assert HTTPResponse.error_object(%{"error" => 42}) == %{}
      assert HTTPResponse.error_object(%{}) == %{}
    end
  end

  describe "body_error_message/2" do
    test "returns the error object's message whatever its type, unredacted" do
      assert HTTPResponse.body_error_message(%{"error" => %{"message" => "AIzaSECRETKEY1"}}, "fb") ==
               "AIzaSECRETKEY1"

      assert HTTPResponse.body_error_message(%{"error" => %{"message" => 123}}, "fb") == 123
    end

    test "any other shape returns the fallback" do
      assert HTTPResponse.body_error_message(%{"error" => %{"code" => 400}}, "fb") == "fb"
      assert HTTPResponse.body_error_message(%{"error" => "boom"}, "fb") == "fb"
      assert HTTPResponse.body_error_message(%{}, nil) == nil
      assert HTTPResponse.body_error_message("not a map", "fb") == "fb"
    end
  end

  describe "redacted_error_message/3" do
    defp redactor, do: fn text -> String.replace(text, ~r/sk-\w+/, "[REDACTED]") end

    test "a binary message goes through the caller's redactor" do
      assert HTTPResponse.redacted_error_message(
               %{"message" => "bad key sk-abc123"},
               "OpenAI HTTP 401",
               redactor()
             ) == "bad key [REDACTED]"
    end

    test "a missing or non-binary message yields the fallback, unredacted" do
      assert HTTPResponse.redacted_error_message(%{}, "OpenAI HTTP 500", redactor()) ==
               "OpenAI HTTP 500"

      assert HTTPResponse.redacted_error_message(%{"message" => 42}, "sk-literal", redactor()) ==
               "sk-literal"
    end
  end

  describe "redact_optional/2" do
    test "a binary goes through the redactor; anything else becomes nil" do
      redactor = fn text -> String.replace(text, "pa-secret", "[REDACTED]") end

      assert HTTPResponse.redact_optional("code pa-secret", redactor) == "code [REDACTED]"
      assert HTTPResponse.redact_optional(nil, redactor) == nil
      assert HTTPResponse.redact_optional(429, redactor) == nil
      assert HTTPResponse.redact_optional(%{"a" => 1}, redactor) == nil
    end
  end

  describe "stringify_keys/1" do
    test "atom keys become strings; other keys and every value pass through" do
      assert HTTPResponse.stringify_keys(%{:temperature => 0.2, "top_p" => 1, 3 => :v}) ==
               %{"temperature" => 0.2, "top_p" => 1, 3 => :v}
    end

    test "only the top level is stringified; nested maps keep their atom keys" do
      assert HTTPResponse.stringify_keys(%{config: %{mode: :fast}}) ==
               %{"config" => %{mode: :fast}}
    end

    test "anything that is not a map becomes %{}" do
      assert HTTPResponse.stringify_keys(nil) == %{}
      assert HTTPResponse.stringify_keys(a: 1) == %{}
      assert HTTPResponse.stringify_keys("x") == %{}
    end
  end

  describe "sanitize_cause/1" do
    test "a Jason.DecodeError loses its payload and every offset, so message/1 still works" do
      {:error, cause} = Jason.decode("{\"secret\": sk-abcdefgh")
      sanitized = HTTPResponse.sanitize_cause(cause)

      assert %Jason.DecodeError{data: "", position: 0, token: nil} = sanitized
      refute inspect(sanitized) =~ "secret"
      assert Jason.DecodeError.message(sanitized) =~ "position 0"
    end

    test "any other cause passes through unchanged" do
      cause = %Req.TransportError{reason: :timeout}
      assert HTTPResponse.sanitize_cause(cause) == cause
      assert HTTPResponse.sanitize_cause(:econnrefused) == :econnrefused
    end
  end

  describe "build_metadata/2" do
    test "adds opts[:request_id] only when it is set" do
      assert HTTPResponse.build_metadata(%{status: 500}, request_id: "req_1") ==
               %{status: 500, request_id: "req_1"}

      assert HTTPResponse.build_metadata(%{status: 500}, []) == %{status: 500}
    end
  end

  describe "maybe_apply_req_test_stub/2" do
    test "wires adapter_opts[:plug] into the request, and leaves it alone without one" do
      req = Req.new(url: "https://example.invalid")
      plug = {Req.Test, :http_response_test_stub}

      assert HTTPResponse.maybe_apply_req_test_stub(req, adapter_opts: [plug: plug]).options.plug ==
               plug

      assert HTTPResponse.maybe_apply_req_test_stub(req, []) == req
      assert HTTPResponse.maybe_apply_req_test_stub(req, adapter_opts: []) == req
    end
  end

  describe "maybe_apply_request_timeout/2" do
    test "a positive request_timeout becomes receive_timeout; without one the request is unchanged" do
      req = Req.new(url: "https://example.invalid")

      assert HTTPResponse.maybe_apply_request_timeout(req, request_timeout: 5_000).options.receive_timeout ==
               5_000

      assert HTTPResponse.maybe_apply_request_timeout(req, []) == req
    end
  end

  describe "apply_receive_timeout/3" do
    test "a positive request_timeout wins; otherwise the caller's default applies" do
      req = Req.new(url: "https://example.invalid")

      assert HTTPResponse.apply_receive_timeout(req, [request_timeout: 5_000], 60_000).options.receive_timeout ==
               5_000

      assert HTTPResponse.apply_receive_timeout(req, [], 60_000).options.receive_timeout ==
               60_000

      assert HTTPResponse.apply_receive_timeout(req, [request_timeout: 0], 120_000).options.receive_timeout ==
               120_000
    end
  end
end
