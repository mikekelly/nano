defmodule Seedling.Search do
  @moduledoc "Exa search/query, contents and grounded answer. Results compact; full provider responses cached for Web.read/2. :api_key and :base_url allow isolated clients."
  alias Seedling.Web.{Transport, Cache}

  def request(path, body, opts \\ []) do
    key =
      Keyword.get_lazy(opts, :api_key, fn ->
        Nano.Settings.get("EXA_API_KEY") || System.get_env("EXA_API_KEY")
      end)

    if is_binary(key) and key != "" do
      root =
        Path.join(
          System.tmp_dir!(),
          "seedling-exa-" <> Integer.to_string(System.unique_integer([:positive]))
        )

      File.mkdir!(root)
      File.chmod!(root, 0o700)
      headers = Path.join(root, "headers")
      File.write!(headers, "x-api-key: " <> key <> "\n")
      File.chmod!(headers, 0o600)

      try do
        url = Keyword.get(opts, :base_url, "https://api.exa.ai") <> path

        args = [
          "--silent",
          "--show-error",
          "--max-time",
          "24",
          "-H",
          "@" <> headers,
          "-H",
          "Content-Type: application/json",
          "--write-out",
          "\n%{http_code}"
        ]

        args =
          if body == nil,
            do: args,
            else: args ++ ["-X", "POST", "--data-binary", Jason.encode!(body)]

        with {:ok, raw} <- Transport.run("curl", args ++ [url], opts) do
          size = byte_size(raw) - 4
          <<data::binary-size(^size), "\n", code::binary-size(3)>> = raw

          if String.to_integer(code) in 200..299,
            do: Jason.decode(data),
            else: {:error, {:http, String.to_integer(code)}}
        end
      after
        File.rm_rf(root)
      end
    else
      {:error, :missing_exa_api_key}
    end
  rescue
    _ -> {:error, :invalid_response}
  end

  def query(query, opts \\ []) do
    count = Keyword.get(opts, :limit, 5) |> max(1) |> min(10)

    body =
      Map.merge(Keyword.get(opts, :params, %{}), %{
        query: query,
        numResults: count,
        contents: %{highlights: %{maxCharacters: 800}}
      })

    with {:ok, data} <- request("/search", body, opts),
         {:ok, id} <- Cache.put(Jason.encode!(data), %{query: query, provider: "exa"}, opts) do
      results =
        Enum.take(data["results"] || [], count)
        |> Enum.map(fn r ->
          Map.take(r, ["id", "url", "title", "publishedDate"])
          |> Map.put(
            "highlights",
            Enum.take(r["highlights"] || [], 2) |> Enum.map(&String.slice(&1, 0, 800))
          )
        end)

      {:ok, %{id: id, results: results}}
    end
  end

  def contents(urls, opts \\ []) do
    with {:ok, data} <-
           request(
             "/contents",
             %{ids: Enum.take(List.wrap(urls), 10), text: %{maxCharacters: 100_000}},
             opts
           ),
         {:ok, id} <- Cache.put(Jason.encode!(data), %{provider: "exa", kind: "contents"}, opts),
         do: Seedling.Web.read(id, opts)
  end

  def answer(query, opts \\ []) do
    with {:ok, data} <- request("/answer", %{query: query, text: false}, opts),
         {:ok, id} <- Cache.put(Jason.encode!(data), %{provider: "exa", kind: "answer"}, opts),
         do: Seedling.Web.read(id, opts)
  end
end
