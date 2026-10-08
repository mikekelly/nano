defmodule ExaTest do
  use ExUnit.Case, async: true

  test "search requests highlights, bounds count, strips full text and retains citations" do
    transport = fn :post, "/search", body, _ ->
      assert body["numResults"] == 2
      assert body["contents"] == %{"highlights" => true, "text" => false}
      assert body["query"] == "question"

      {:ok,
       %{
         "results" =>
           Enum.map(1..2, fn n ->
             %{
               "id" => "#{n}",
               "url" => "https://example.com/#{n}",
               "title" => "Title",
               "text" => "not returned",
               "highlights" => ["Evidence"]
             }
           end)
       }}
    end

    assert {:ok, %{data: %{"results" => results}, truncated: false}} =
             Exa.search("question",
               transport: transport,
               num_results: 2,
               params: %{"query" => "override", "contents" => %{"text" => true}}
             )

    assert length(results) == 2
    refute Map.has_key?(hd(results), "text")
    assert hd(results)["url"] == "https://example.com/1"
  end

  test "contents limits requests and answer retains source URLs" do
    transport = fn :post, path, body, _ ->
      case path do
        "/contents" ->
          assert body["urls"] == ["https://example.com"]
          assert body["text"] == %{"maxCharacters" => 100}
          {:ok, %{"results" => [%{"url" => "https://example.com", "text" => "example"}]}}

        "/answer" ->
          assert body["stream"] == false
          assert body["text"] == false
          {:ok, %{"answer" => "Example", "citations" => [%{"url" => "https://example.com"}]}}
      end
    end

    assert {:ok, _} = Exa.contents("https://example.com", max_chars: 100, transport: transport)

    assert {:ok, %{data: %{"citations" => [%{"url" => "https://example.com"}]}}} =
             Exa.answer("Q?", transport: transport)
  end

  test "invalid inputs do not reach transport" do
    opts = [transport: fn _, _, _, _ -> flunk("must not call provider") end]

    for q <- [nil, "", "  ", String.duplicate("a", 10001)] do
      assert {:error, %{kind: :invalid_input}} = Exa.search(q, opts)
    end

    for urls <- [[], ["file:///etc/passwd"], [12], List.duplicate("https://example.com", 11)] do
      assert {:error, %{kind: :invalid_input}} = Exa.contents(urls, opts)
    end

    assert {:error, _} = Exa.search("x", Keyword.put(opts, :num_results, 11))
    assert {:error, _} = Exa.answer("x", Keyword.put(opts, :max_bytes, -1))
    assert {:error, %{kind: :missing_key}} = Exa.answer("x", api_key: nil)
  end

  test "errors are values and exceptions cannot leak secrets" do
    for status <- [401, 402, 429, 503] do
      err = %{kind: :http, status: status, retryable: status >= 429}
      assert {:error, ^err} = Exa.answer("x", transport: fn _, _, _, _ -> {:error, err} end)
    end

    assert {:error, err} = Exa.search("x", transport: fn _, _, _, _ -> raise "SECRET" end)
    refute inspect(err) =~ "SECRET"

    assert {:error, %{kind: :invalid_response}} =
             Exa.answer("x", transport: fn _, _, _, _ -> {:ok, "bad"} end)
  end

  test "recursive bounds are explicit, UTF8 valid and respect JSON size budgets" do
    for cap <- [256, 1000, 16000],
        input <- [
          String.duplicate("世界\n", 30000),
          %{
            "items" =>
              Enum.map(
                1..1000,
                &%{"url" => "https://example.com/#{&1}", "text" => String.duplicate("x", 1000)}
              )
          }
        ] do
      result = Exa.bound(input, max_bytes: cap)
      assert result.truncated
      assert result.continuation =~ "max_bytes"
      assert byte_size(Jason.encode!(result)) <= cap
      assert String.valid?(Jason.encode!(result))
    end

    assert %{data: %{"a" => [1, true, nil]}, truncated: false} =
             Exa.bound(%{"a" => [1, true, nil]})
  end
end
