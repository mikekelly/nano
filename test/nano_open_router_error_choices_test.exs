defmodule NanoOpenRouterErrorChoicesTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    %{model: Fake.model()}
  end

  defp request(ctx, body) do
    Fake.push(ctx.model, status: 200, body: body)

    Nano.OpenRouter.chat(
      ctx.model,
      [%{"role" => "system", "content" => "short"}, %{"role" => "user", "content" => "hello"}],
      []
    )
  end

  defp response(choice),
    do: %{
      "choices" => [choice],
      "provider" => "fake",
      "usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0}
    }

  test "HTTP200 finish_reason:error is failed attempt not empty successful response", ctx do
    body = response(%{"finish_reason" => "error", "message" => %{"content" => nil}})
    assert {:error, error} = request(ctx, body)
    assert error.status == 200
    assert error.body["choices"] == body["choices"]
    assert Nano.OpenRouter.transient?(error)
  end

  test "choice error code preserves nontransient classification", ctx do
    body =
      response(%{
        "finish_reason" => "error",
        "error" => %{"code" => 400, "message" => "invalid input"},
        "message" => %{"content" => nil}
      })

    assert {:error, error} = request(ctx, body)
    assert error.body["error"]["code"] == 400
    refute Nano.OpenRouter.transient?(error)
  end

  test "top-level error wins even with a seemingly successful choice", ctx do
    body =
      response(%{"finish_reason" => "stop", "message" => %{"content" => "not success"}})
      |> Map.put("error", %{"code" => 429, "message" => "rate limited"})

    assert {:error, error} = request(ctx, body)
    assert error.body["error"]["code"] == 429
    assert Nano.OpenRouter.transient?(error)
  end

  test "malformed messages and usage fail safely instead of crashing harness", ctx do
    for choice <- [
          %{"message" => nil},
          %{"message" => "bad"},
          %{"message" => %{"content" => []}},
          %{"message" => %{"content" => nil, "tool_calls" => [nil]}}
        ] do
      assert {:error, error} = request(ctx, response(choice))
      assert error.body["error"]["code"] == 502
    end

    assert {:error, _} =
             request(
               ctx,
               response(%{"message" => %{"content" => "ok"}}) |> Map.put("usage", "bad")
             )

    assert {:error, _} = request(ctx, %{"choices" => [nil]})

    for usage <- [
          %{"prompt_tokens" => "bad"},
          %{"completion_tokens" => -1},
          %{"prompt_tokens_details" => "bad"},
          %{"cost" => "bad"}
        ] do
      assert {:error, _} =
               request(
                 ctx,
                 response(%{"message" => %{"content" => "ok"}}) |> Map.put("usage", usage)
               )
    end
  end

  test "oversized unicode provider error stays bounded and retains code", ctx do
    body = %{"error" => %{"code" => 400, "message" => String.duplicate("😀", 30_000)}}
    assert {:error, error} = request(ctx, body)
    assert error.body["error"]["code"] == 400
    assert error.body["truncated"]
    assert String.valid?(error.body["preview"])
    assert byte_size(Jason.encode!(error.body)) < 16_384
    refute Nano.OpenRouter.transient?(error)
  end

  test "normal text and normal tool-only response remain successful", ctx do
    assert {:ok, %{message: %{"content" => "hello"}}} =
             request(
               ctx,
               response(%{"finish_reason" => "stop", "message" => %{"content" => "hello"}})
             )

    call = %{"id" => "tool-1", "function" => %{"name" => "eval", "arguments" => "{}"}}

    assert {:ok, %{message: %{"tool_calls" => [^call]}}} =
             request(
               ctx,
               response(%{
                 "finish_reason" => "tool_calls",
                 "message" => %{"content" => nil, "tool_calls" => [call]}
               })
             )
  end
end
