# Opt-in live probe, never part of the ordinary test suite. Requires explicit env key.
# MIX_ENV=test EXA_API_KEY=... mix run test/seed_web_live_smoke.exs
opts = [
  api_key: System.get_env("EXA_API_KEY"),
  cache_dir: "/tmp/seed-web-live-#{System.unique_integer([:positive])}"
]

try do
  summarize = fn label, result ->
    summary =
      case result do
        {:ok, %{results: results}} ->
          %{count: length(results), first_url: get_in(results, [Access.at(0), :url])}

        {:ok, %{pages: pages}} ->
          %{count: length(pages)}

        {:ok, %{text: text, url: url}} ->
          %{chars: String.length(text), url: url}

        {:ok, text} when is_binary(text) ->
          %{chars: String.length(text), prefix: String.slice(text, 0, 80)}

        other ->
          other
      end

    IO.inspect({label, summary})
  end

  summarize.(:http, SeedWeb.fetch("https://example.com", opts))
  summarize.(:browser, SeedWeb.Browser.fetch("https://example.com", timeout: 12000))
  summarize.(:search, SeedSearch.search("Elixir official documentation", opts ++ [limit: 2]))
  summarize.(:contents, SeedSearch.contents(["https://elixir-lang.org/docs.html"], opts))
  summarize.(:answer, SeedSearch.answer("What is the official Elixir documentation URL?", opts))

  {:ok, %{pid: pid}} =
    SeedSearch.research(
      "Find the official Elixir documentation URL; return one short sentence with citation.",
      opts ++ [effort: "low", research_timeout: 180_000, poll_interval: 2000]
    )

  receive do
    {:seed_search, ^pid, :started, started} -> IO.inspect({:research_started, started})
    {:seed_search, ^pid, :error, reason} -> IO.inspect({:research_start_error, reason})
  after
    20000 -> IO.puts("research start timed out")
  end

  receive do
    {:seed_search, ^pid, status, result} ->
      IO.inspect(
        {:research, status,
         case result do
           %{page: p} ->
             %{
               run_id: result.run_id,
               status: result.status,
               chars: p.total_chars,
               contains_output: String.contains?(p.text, "output")
             }

           other ->
             other
         end}
      )
  after
    190_000 -> IO.puts("research smoke deadline exceeded")
  end

  # CDP server: dedicated ephemeral port, no 9222 collision.
  {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
  {:ok, {_, port}} = :inet.sockname(sock)
  :gen_tcp.close(sock)
  {:ok, server} = SeedWeb.Browser.serve(port: port)
  Process.sleep(500)

  summarize.(
    :cdp,
    SeedWeb.HTTP.request(:get, server.endpoint <> "/json/version", nil, [], timeout: 2000)
    |> case do
      {:ok, resp} -> {:ok, %{status: resp.status}}
      other -> other
    end
  )

  SeedWeb.Browser.stop(server.pid)
after
  File.rm_rf(opts[:cache_dir])
end
