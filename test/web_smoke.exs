# Optional live-network smoke: MIX_ENV=test mix run --no-start test/web_smoke.exs
# Kept outside the deterministic ExUnit suite; fails plainly if network/browser unavailable.
dir =
  Path.join(System.tmp_dir!(), "nano-web-smoke-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

opts = [cache_dir: dir, max_bytes: 1000]

try do
  {:ok, http} = Nano.Web.fetch("https://example.com", opts ++ [js: false])
  {:ok, cached} = Nano.Web.fetch("https://example.com", opts ++ [js: false])
  true = cached.cache_hit
  true = http.bytes <= 1000
  {:ok, browser} = Nano.Web.fetch("https://example.com", opts ++ [js: true])
  true = browser.method == "lightpanda"
  true = browser.bytes <= 1000
  {:ok, evidence} = Nano.Web.evidence(http.id, String.slice(http.text, 0, 100), opts)

  IO.inspect(%{
    http: Map.take(http, [:url, :method, :bytes, :total_chars, :cut]),
    browser: Map.take(browser, [:url, :method, :bytes, :total_chars, :cut]),
    cache_hit: cached.cache_hit,
    evidence: Map.take(evidence, [:url, :quote, :content_sha256])
  })
after
  File.rm_rf(dir)
end
