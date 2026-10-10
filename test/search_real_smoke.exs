# Explicit opt-in smoke; never prints provider bodies or credentials.
:ok = Nano.Settings.put("EXA_API_KEY", System.fetch_env!("EXA_API_KEY"))
for {operation, result} <- [
  search: Nano.Search.search("Elixir programming language official website", num_results: 1),
  contents: Nano.Search.contents(["https://elixir-lang.org"], params: %{"text" => %{"maxCharacters" => 1500}}),
  answer: Nano.Search.answer("What language runs on the Erlang VM and was created by Jose Valim?")
] do
  case result do
    {:ok, r} -> IO.inspect(%{operation: operation, ok: true, bytes: r.bytes, cut: r.cut, has_url: String.contains?(r.text, "https://"), result: r.result})
    {:error, e} -> IO.inspect(%{operation: operation, error: e})
  end
end
{:ok, h} = Nano.Search.research("What is the official website of the Elixir programming language? Return its URL with a source.", owner: "real-smoke-absent", poll_interval: 1000, research_timeout: 120000, delivery_timeout: 10)
ref = Process.monitor(h.pid)
receive do
  {:DOWN, ^ref, _, _, reason} ->
    {:ok, s} = Nano.Search.status(h)
    IO.inspect(%{operation: :research, worker_exit: reason, status: s.status, error: s[:error], has_remote_id: is_binary(s.remote_id), result: s[:result] && s.result.result})
after
  125000 -> IO.inspect(%{operation: :research, timed_out: true, handle: Map.drop(h, [:pid])})
end
