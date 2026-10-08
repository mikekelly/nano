defmodule Nano.ModelTest do
  use ExUnit.Case, async: true

  alias Nano.Model

  test "class/2: a failure's class, by its HTTP status and what the provider said" do
    for status <- [nil, 408, 409, 425, 429, 500, 502, 503, 504, 529],
        do: assert(Model.class(status, %{}) == :transient)

    assert Model.class(401, %{}) == :auth
    assert Model.class(413, "Request Entity Too Large") == :context

    for message <- [
          "This model's maximum context length is 8192 tokens",
          "prompt is too long: 300000 tokens > 200000 maximum",
          "Your input exceeds the context window of this model."
        ],
        do: assert(Model.class(400, %{"error" => %{"message" => message}}) == :context)

    for status <- [400, 403, 404, 422],
        do:
          assert(
            Model.class(status, %{"error" => %{"message" => "Unsupported parameter"}}) == :refused
          )
  end

  test "retry_after/2: a header in ms or seconds, else a message's \"try again in\"" do
    assert Model.retry_after(%{"retry-after-ms" => ["1500"]}, %{}) == 1500
    assert Model.retry_after(%{"retry-after" => ["2"]}, %{}) == 2000
    assert Model.retry_after(%{"retry-after" => ["0.5"]}, %{}) == 500
    assert Model.retry_after(%{"retry-after" => ["Wed, 21 Oct 2015 07:28:00 GMT"]}, %{}) == nil

    said = &%{"error" => %{"code" => "rate_limit_exceeded", "message" => &1}}
    assert Model.retry_after(%{}, said.("Rate limit reached. Please try again in 1.5s.")) == 1500
    assert Model.retry_after(%{}, said.("Please try again in 20ms.")) == 20
    assert Model.retry_after(%{}, "socket closed") == nil
  end

  test "message/1: what the provider said" do
    assert Model.message(%{"error" => %{"code" => 502, "message" => "upstream"}}) == "upstream"

    assert Model.message(%{"error" => %{"code" => "server_is_overloaded"}}) ==
             "server_is_overloaded"

    assert Model.message("socket closed") == "socket closed"
    assert Model.message(%{"detail" => "x"}) == ~s(%{"detail" => "x"})
  end
end
