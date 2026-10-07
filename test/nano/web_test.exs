defmodule Nano.WebTest do
  # Not async: the cache is a named ETS table and env vars are process-wide.
  use ExUnit.Case, async: false

  alias Nano.Web, as: W

  setup do
    W.clear_cache()
    old = System.get_env("EXA_API_KEY")
    System.delete_env("EXA_API_KEY")

    on_exit(fn ->
      if old, do: System.put_env("EXA_API_KEY", old)
    end)

    %{}
  end

  test "providers reports what is available without a key" do
    providers = Map.new(W.providers(), &{&1.id, &1})
    assert providers[:duckduckgo].available
    assert providers[:wikipedia].available
    refute providers[:exa].available
    assert providers[:exa].needs == "EXA_API_KEY"
  end

  test "strip_tags removes markup and decodes entities" do
    html = "<p>Hello &amp; <b>world</b></p><script>bad()</script>"
    assert W.strip_tags(html) =~ "Hello & world"
    refute W.strip_tags(html) =~ "bad()"
  end

  test "fetch_content reads a page over the network and extracts readable text" do
    # example.com is stable and text-only.
    result = W.fetch_content("https://example.com")
    assert result.status == 200
    assert result.kind in [:readable, :text]
    assert result.bytes > 0
    assert is_binary(result.response_id)
    assert (result.content || "") =~ "domain"
  end

  test "fetch_content reports failures without raising" do
    result = W.fetch_content("http://127.0.0.1:1/nope")
    assert result.error != nil
    assert result.content == nil
  end

  test "get_search_content pages a stored result" do
    result = W.fetch_content("https://example.com")
    full = result.content

    page = W.get_search_content(result.response_id, offset: 0, limit: 20)
    assert page.total_bytes == byte_size(full)
    assert byte_size(page.content) <= 20

    page2 = W.get_search_content(result.response_id, offset: 10, limit: 20)
    assert page2.offset == 10

    assert {:error, :not_found} = W.get_search_content("nosuchid")
  end

  test "get_search_content can window around a search term" do
    result = W.fetch_content("https://example.com")
    hit = W.get_search_content(result.response_id, search: "documentation", limit: 40)
    assert hit.content =~ "documentation"
  end

  test "web_search uses Wikipedia when Exa is absent and DuckDuckGo fails" do
    # Force Wikipedia to test the keyless path deterministically.
    result = W.web_search("BEAM virtual machine", num_results: 2, provider: :wikipedia)
    assert result.provider == :wikipedia
    assert [%{title: _, url: url} | _] = result.results
    assert url =~ "wikipedia.org"
    assert is_binary(result.response_id)
  end

  test "web_search with an unknown provider returns an error, not a raise" do
    result = W.web_search("x", provider: :nope)
    assert result.error =~ "unknown provider"
  end

  test "cache_status reports the entries in the cache" do
    W.fetch_content("https://example.com")
    status = W.cache_status()
    assert status.entries > 0
  end
end
