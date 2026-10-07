defmodule Nano.OpenRouterTest do
  # Not async: the base URL and the model cache are node-wide.
  use ExUnit.Case, async: false

  alias Nano.FakeOpenRouter, as: Fake

  setup do
    Fake.start()
    :persistent_term.erase({Nano.OpenRouter, :models})
    on_exit(fn -> :persistent_term.erase({Nano.OpenRouter, :models}) end)
  end

  test "models/0 parses the list, sorted by id, and caches it" do
    Fake.models([
      %{
        "id" => "b/two",
        "name" => "Two",
        "context_length" => 1000,
        "pricing" => %{"prompt" => "0.000002", "completion" => "0"}
      },
      %{"id" => "a/one", "name" => "One", "context_length" => 2000, "pricing" => %{}}
    ])

    assert [
             %{
               id: "a/one",
               name: "One",
               context_length: 2000,
               prompt_price: nil,
               completion_price: nil
             },
             %{
               id: "b/two",
               name: "Two",
               context_length: 1000,
               prompt_price: two,
               completion_price: zero
             }
           ] = Nano.OpenRouter.models()

    assert_in_delta two, 2.0, 1.0e-9
    assert zero == 0.0

    # The second call is answered from the cache.
    Fake.models([])
    assert [%{id: "a/one"}, %{id: "b/two"}] = Nano.OpenRouter.models()
  end

  test "models/0 returns [] when the request fails or nothing answers" do
    Fake.models(503)
    assert Nano.OpenRouter.models() == []

    :persistent_term.erase({Nano.OpenRouter, :models})
    saved = Application.get_env(:nano, :openrouter_base_url)
    Application.put_env(:nano, :openrouter_base_url, "http://127.0.0.1:1/unset")
    on_exit(fn -> Application.put_env(:nano, :openrouter_base_url, saved) end)
    assert Nano.OpenRouter.models() == []
  end
end
