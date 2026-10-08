defmodule SeedWebTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "seed-web-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, opts: [cache_dir: dir]}
  end

  test "cache slices are Unicode safe, explicit and independently readable", %{opts: opts} do
    assert {:ok, id} =
             SeedWeb.store("😀héllo\n" <> String.duplicate("a", 30), "https://example.com", opts)

    assert {:ok, page} = SeedWeb.read(id, opts ++ [limit: 3])
    assert page.text == "😀hé"
    assert page.next_offset == 3
    assert page.truncated
    assert {:ok, next} = SeedWeb.read(id, opts ++ [offset: 3, limit: 100])
    assert next.text == "llo\n" <> String.duplicate("a", 30)
    refute next.truncated
    assert next.next_offset == nil
    assert {:error, %{reason: :offset_out_of_range}} = SeedWeb.read(id, opts ++ [offset: 99])
    assert {:error, :invalid_paging_options} = SeedWeb.read(id, opts ++ [limit: 0])
    assert {:error, :invalid_id} = SeedWeb.read("../secret", opts)
  end

  test "HTML prefers main, removes script and preserves relative citations" do
    html =
      "<nav>noise</nav><main><h1>Title</h1><p>A &amp; B &#x1F600;</p><script>bad</script><a href='/docs'>Docs</a></main>outside"

    text = SeedWeb.extract(html, "https://example.com/page")
    assert text =~ "Title\nA & B 😀"
    assert text =~ "[Docs](https://example.com/docs)"
    refute text =~ "noise"
    refute text =~ "bad"
    refute text =~ "outside"
  end

  test "protocol and browser options are checked before execution" do
    assert {:error, :invalid_http_url} = SeedWeb.fetch("file:///etc/passwd")
    assert {:error, :invalid_http_url} = SeedWeb.fetch("https://user:pass@example.com")
    assert {:error, :invalid_http_url} = SeedWeb.Browser.fetch("javascript:alert(1)")
    assert {:error, :port_required_or_browser_missing} = SeedWeb.Browser.serve([])
  end

  test "expiry is explicit and cache is bounded", %{opts: opts} do
    for n <- 1..105, do: SeedWeb.store("content #{n}", "https://example.com/#{n}", opts)
    assert length(Path.wildcard(Path.join(opts[:cache_dir], "*.json"))) == 100
    {:ok, id} = SeedWeb.store("old", "https://example.com/old", opts)
    path = Path.join(opts[:cache_dir], id <> ".json")
    data = Jason.decode!(File.read!(path)) |> Map.put("fetched_at", 0)
    File.write!(path, Jason.encode!(data))
    assert {:ok, %{expired: true}} = SeedWeb.read(id, opts)
  end

  test "byte caps preserve continuation and announce oversized characters", %{opts: opts} do
    {:ok, id} = SeedWeb.store(String.duplicate("😀", 9000), "https://example.com", opts)
    assert {:ok, p} = SeedWeb.read(id, opts)
    assert byte_size(p.text) == 16000
    assert p.next_offset == 4000
    assert {:ok, q} = SeedWeb.read(id, opts ++ [offset: p.next_offset])
    assert q.next_offset == 8000
    {:ok, huge} = SeedWeb.store("a" <> String.duplicate("́", 20000), "https://example.com", opts)
    assert {:error, :character_exceeds_byte_limit} = SeedWeb.read(huge, opts)
  end

  test "browser deadlines and body limits kill their subprocess", %{opts: opts} do
    File.mkdir_p!(opts[:cache_dir])
    slow = Path.join(opts[:cache_dir], "slow")
    File.write!(slow, "#!/bin/sh\nexec sleep 10\n")
    File.chmod!(slow, 0o700)

    assert {:error, :timeout} =
             SeedWeb.Browser.fetch("https://example.com", executable: slow, timeout: 30)

    loud = Path.join(opts[:cache_dir], "loud")
    File.write!(loud, "#!/bin/sh\nprintf 'this output is larger than ten bytes'\n")
    File.chmod!(loud, 0o700)

    assert {:error, :body_too_large} =
             SeedWeb.Browser.fetch("https://example.com", executable: loud, max_body_bytes: 10)
  end
end
