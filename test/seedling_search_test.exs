defmodule Seedling.SearchTest do
  use ExUnit.Case, async: true
  alias Seedling.Search

  defp opts(fun), do: [api_key: "fake", transport: fun]
  defp ok(data), do: {:ok, %{status: 200, body: data}}

  test "search asks for highlights, no full text, preserves citations and caps output" do
    transport = fn req ->
      assert req[:url] == "https://api.exa.ai/search"
      assert req[:json]["numResults"] == 5
      refute Map.has_key?(req[:json]["contents"], "text")

      ok(%{
        "results" => [
          %{
            "title" => "Official",
            "url" => "https://example.com",
            "id" => "id",
            "highlights" => [String.duplicate("é", 20000)],
            "text" => "not returned"
          }
        ]
      })
    end

    assert {:ok, data} = Search.search("question", opts(transport))
    assert data["_truncated"]
    assert String.valid?(hd(hd(data["results"])["highlights"]))
    refute Map.has_key?(hd(data["results"]), "text")
    assert byte_size(Jason.encode!(data)) < 22000
  end

  test "contents and answers preserve useful text and citations" do
    transport = fn req ->
      case req[:url] do
        "https://api.exa.ai/contents" ->
          assert req[:json]["ids"] == ["https://example.com"]
          ok(%{"results" => [%{"text" => "page", "url" => "https://example.com"}]})

        "https://api.exa.ai/answer" ->
          ok(%{"answer" => "fact", "citations" => [%{"url" => "https://example.com"}]})
      end
    end

    assert {:ok, %{"results" => [%{"text" => "page"}]}} =
             Search.contents(["https://example.com"], opts(transport))

    assert {:ok, %{"answer" => "fact", "citations" => [_]}} =
             Search.answer("question", opts(transport))
  end

  test "bad key, limits, malformed responses and transport failures return values" do
    for status <- [401, 429, 500] do
      assert {:error, %{kind: :http, status: ^status}} =
               Search.search(
                 "q",
                 opts(fn _ -> {:ok, %{status: status, body: %{"secret" => "never expose"}}} end)
               )
    end

    assert {:error, %{kind: :missing_api_key}} = Search.search("q", api_key: "")
    assert {:error, _} = Search.search("q", opts(fn _ -> raise "secret" end))
    assert {:error, _} = Search.search("q", opts(fn _ -> ok(%{}) end))
    assert {:error, _} = Search.search("", opts(fn _ -> flunk("must not request") end))
    assert {:error, _} = Search.search("q", num_results: 21)
    assert {:error, _} = Search.contents([])
    assert {:error, _} = Search.research("q")
  end

  test "research completes asynchronously, persists full output, supports schema" do
    parent = self()
    dir = Path.join(System.tmp_dir!(), "search-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    transport = fn req ->
      case req[:method] do
        :post ->
          assert req[:json]["effort"] == "minimal"
          assert req[:json]["outputSchema"] == %{"type" => "object"}
          ok(%{"id" => "agent_run_fake", "status" => "queued"})

        :get ->
          send(parent, :polled)

          ok(%{
            "id" => "agent_run_fake",
            "status" => "completed",
            "output" => %{"answer" => "Paris", "citations" => [%{"url" => "https://example.com"}]}
          })
      end
    end

    options = opts(transport) ++ [notify: self(), state_dir: dir, schema: %{"type" => "object"}]
    assert {:ok, %{id: id, worker: worker, path: path}} = Search.research("capital?", options)
    assert is_pid(worker)
    assert_receive :polled

    assert_receive {:search_research_done, ^id,
                    {:ok, %{path: ^path, data: %{"status" => "completed"}}}},
                   2000

    assert %{"result" => %{"ok" => %{"output" => %{"answer" => "Paris"}}}} =
             Jason.decode!(File.read!(path))

    assert {:ok, _} = Search.resume(id, options)
    assert_receive {:search_research_done, ^id, {:ok, _}}, 2000
  end

  test "poll retries transient failure and reports terminal failures and timeouts" do
    dir = Path.join(System.tmp_dir!(), "search-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    transport = fn _ ->
      case Agent.get_and_update(counter, &{&1, &1 + 1}) do
        0 -> {:ok, %{status: 429, body: %{}}}
        _ -> ok(%{"status" => "failed"})
      end
    end

    options = opts(transport) ++ [notify: self(), state_dir: dir, poll_interval: 1]
    assert {:ok, _} = Search.resume("fake", options)
    assert_receive {:search_research_done, "fake", {:error, %{kind: :research_failed}}}, 2000
    assert {:ok, _} = Search.resume("timeout", Keyword.put(options, :poll_timeout, 0))
    assert_receive {:search_research_done, "timeout", {:error, %{kind: :poll_timeout}}}, 2000
    assert {:error, _} = Search.resume("../../bad", options)
  end
end
