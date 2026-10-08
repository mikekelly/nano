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

  test "HTTP boundary disables retries/redirects and maps errors without exposing secrets" do
    for status <- [401, 402, 429, 503] do
      request_fun = fn opts ->
        assert opts[:retry] == false
        assert opts[:redirect] == false
        assert opts[:headers] == [{"x-api-key", "TEST-KEY"}]
        {:ok, %{status: status, headers: %{"retry-after" => ["10"]}, body: "TEST-KEY"}}
      end

      assert {:error, err} = Exa.answer("x", api_key: "TEST-KEY", request_fun: request_fun)
      assert err.status == status
      assert err.retry_after == "10"
      refute inspect(err) =~ "TEST-KEY"
    end

    assert {:error, %{kind: :transport, retryable: true}} =
             Exa.answer("x", api_key: "TEST", request_fun: fn _ -> {:error, :timeout} end)
  end

  test "HTTP wall-clock deadline kills a stuck request and caps output below harness limit" do
    parent = self()
    started = System.monotonic_time(:millisecond)

    assert {:error, %{kind: :transport, retryable: true}} =
             Exa.answer("x",
               api_key: "TEST",
               timeout: 20,
               request_fun: fn _ ->
                 send(parent, {:http_worker, self()})
                 Process.sleep(:infinity)
               end
             )

    assert System.monotonic_time(:millisecond) - started < 1000
    assert_receive {:http_worker, pid}
    refute Process.alive?(pid)
    assert {:error, %{kind: :invalid_input}} = Exa.answer("x", max_bytes: 24001)

    assert byte_size(Jason.encode!(Exa.bound(String.duplicate("x", 50000), max_bytes: 24000))) <=
             24000
  end

  test "one unbounded grapheme cannot exceed byte limits" do
    inputs = ["a" <> String.duplicate("\u0301", 50000), String.duplicate("👩‍", 20000) <> "👩"]

    for input <- inputs, cap <- [256, 1000, 24000] do
      result = Exa.bound(input, max_bytes: cap)
      assert result.truncated
      assert String.valid?(result.data)
      assert byte_size(Jason.encode!(result)) <= cap
    end
  end

  test "bounds preserve URLs

 intact rather than returning corrupted citation links" do
    data = %{"url" => "https://example.com", "text" => String.duplicate("x", 2000)}

    assert %{data: %{"url" => "https://example.com"}, truncated: true} =
             Exa.bound(data, max_bytes: 256)

    result =
      Exa.bound(%{"url" => "https://example.com/" <> String.duplicate("a", 1000)}, max_bytes: 256)

    assert result.truncated
    refute Map.has_key?(result.data, "url")
  end

  test "recursive bounds
 are explicit, UTF8 valid and respect JSON size budgets" do
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
