defmodule NanoWeb.ApiGuard do
  @moduledoc """
  Trusted-local intent barrier, not authentication. Runs before parsers and Plug.Head:
  configured origins never derive from Host or forwarded headers, and mutation params
  come only from one JSON object plus route identifiers. No CORS grants are made here.
  """
  import Plug.Conn
  @safe ~w(GET HEAD OPTIONS)
  @overrides ~w(x-http-method-override x-method-override x-http-method)
  def init(opts), do: opts

  def call(%{path_info: ["api" | _]} = conn, _) do
    unsafe = conn.method not in @safe

    with {:ok, _} <- if(unsafe, do: policy(), else: {:ok, nil}),
         {:ok, body, conn} <- body(conn),
         :ok <- overrides(conn, body),
         :ok <- if(unsafe, do: intent(conn), else: :ok),
         {:ok, params} <- if(unsafe, do: input(conn, body), else: safe_input(conn)) do
      if unsafe, do: %{conn | body_params: params, params: params}, else: conn
    else
      {:error, status, code} -> refuse(conn, status, code)
    end
  end

  # Plug.Head would otherwise turn HEAD into the sole OAuth safe-method exception.
  def call(%{path_info: ["openrouter", "callback"], method: method} = conn, _)
      when method != "GET", do: conn |> send_resp(405, "GET required") |> halt()

  def call(conn, _), do: conn

  @doc "Validated deployment origins; invalid explicit configuration fails closed."
  def policy do
    port = Application.get_env(:nano, :api_public_port, 4000)

    origins =
      Application.get_env(:nano, :api_trusted_origins, [
        "http://localhost:#{port}",
        "http://127.0.0.1:#{port}",
        "http://[::1]:#{port}"
      ])

    if is_integer(port) and port in 1..65535 and is_list(origins) do
      tuples = Enum.map(origins, &origin/1)

      if Enum.all?(tuples, &match?({:ok, _}, &1)),
        do: {:ok, Enum.map(tuples, &elem(&1, 1))},
        else: unavailable()
    else
      unavailable()
    end
  end

  @doc "Fixed trusted callback, independent of the request's address."
  def callback_url do
    port = Application.get_env(:nano, :api_public_port, 4000)

    url =
      Application.get_env(
        :nano,
        :openrouter_callback_url,
        "http://localhost:#{port}/openrouter/callback"
      )

    with {:ok, origins} <- policy(),
         true <- is_binary(url),
         uri <- URI.parse(url),
         true <- uri.path == "/openrouter/callback" and is_nil(uri.query) and is_nil(uri.fragment),
         {:ok, tuple} <- origin(URI.to_string(%{uri | path: nil})),
         true <- tuple in origins do
      {:ok, url}
    else
      _ -> unavailable()
    end
  end

  defp unavailable, do: {:error, 503, "api_policy_unavailable"}

  defp origin(value) when is_binary(value) do
    uri = URI.parse(value)
    scheme = if(is_binary(uri.scheme), do: String.downcase(uri.scheme), else: nil)
    uri = %{uri | scheme: scheme, port: uri.port || URI.default_port(scheme)}

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and valid_host?(uri.host) and
         is_integer(uri.port) and uri.port in 1..65535 and is_nil(uri.userinfo) and
         uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment) and
         not String.contains?(value, [" ", "\t", "\r", "\n", ",", "\\"]) do
      {:ok, {String.downcase(uri.scheme), String.downcase(uri.host), uri.port}}
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp origin(_), do: :error

  defp valid_host?(host) do
    if String.contains?(host, ":") do
      match?({:ok, _}, :inet.parse_ipv6_address(String.to_charlist(host)))
    else
      Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\z/, host) and
        not String.contains?(host, "..")
    end
  end

  defp intent(conn) do
    with ["mutate"] <- get_req_header(conn, "x-nano-api-intent"),
         {:ok, origins} <- policy() do
      case get_req_header(conn, "origin") do
        [] ->
          :ok

        [value] ->
          case origin(value) do
            {:ok, tuple} ->
              if tuple in origins, do: :ok, else: {:error, 403, "api_origin_untrusted"}

            _ ->
              {:error, 403, "api_origin_untrusted"}
          end

        _ ->
          {:error, 403, "api_origin_untrusted"}
      end
    else
      _ -> {:error, 403, "api_intent_required"}
    end
  end

  defp body(conn, acc \\ "") do
    case read_body(conn, length: 8_000_000) do
      {:ok, bytes, conn} -> {:ok, acc <> bytes, conn}
      {:more, _, _} -> {:error, 400, "api_body_forbidden"}
      {:error, _} -> {:error, 400, "api_body_forbidden"}
    end
  end

  defp overrides(conn, bytes) do
    query = URI.query_decoder(conn.query_string) |> Enum.any?(fn {k, _} -> k == "_method" end)

    form =
      if media(conn) == "application/x-www-form-urlencoded",
        do: URI.query_decoder(bytes) |> Enum.any?(fn {k, _} -> k == "_method" end),
        else: false

    json =
      case Jason.decode(bytes, objects: :ordered_objects) do
        {:ok, %Jason.OrderedObject{values: pairs}} ->
          Enum.any?(pairs, fn {k, _} -> k == "_method" end)

        _ ->
          false
      end

    if query or form or json or Enum.any?(@overrides, &(get_req_header(conn, &1) != [])),
      do: {:error, 400, "api_method_override_forbidden"},
      else: :ok
  rescue
    _ -> {:error, 400, "api_method_override_forbidden"}
  end

  defp safe_input(%{path_info: ["api", "users", _, "inbox"]} = conn) do
    if Enum.any?(URI.query_decoder(conn.query_string), fn {key, _} -> key == "clear" end),
      do: {:error, 400, "api_query_forbidden"},
      else: {:ok, nil}
  rescue
    _ -> {:error, 400, "api_query_forbidden"}
  end

  defp safe_input(_), do: {:ok, nil}

  defp input(conn, bytes) do
    bodyless = bodyless?(conn)

    cond do
      conn.query_string != "" ->
        {:error, 400, "api_query_forbidden"}

      bytes == "" and bodyless ->
        {:ok, %{}}

      media(conn) != "application/json" ->
        {:error, 415, "api_json_required"}

      true ->
        with {:ok, %Jason.OrderedObject{} = object} <-
               Jason.decode(bytes, objects: :ordered_objects),
             {:ok, params} <- plain(object),
             false <- Enum.any?(path_keys(conn), &Map.has_key?(params, &1)),
             true <- not bodyless or map_size(params) == 0 do
          {:ok, params}
        else
          {:error, :duplicate} -> {:error, 400, "api_duplicate_key"}
          true -> {:error, 400, "api_path_key_collision"}
          false -> {:error, 400, "api_body_forbidden"}
          _ -> {:error, 400, "api_object_required"}
        end
    end
  end

  defp media(conn) do
    case get_req_header(conn, "content-type") do
      [value] -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      _ -> nil
    end
  end

  defp bodyless?(%{method: "POST", path_info: ["api", "agents", _, action]}),
    do: action in ~w(stop restart resume unhalt)

  defp bodyless?(%{method: "POST", path_info: ["api", "chatgpt", action]}),
    do: action in ~w(login logout)

  defp bodyless?(%{method: "POST", path_info: ["api", "users", _, "inbox", "consume"]}), do: true
  defp bodyless?(%{method: "DELETE", path_info: ["api", "settings", _]}), do: true
  defp bodyless?(_), do: false

  defp path_keys(%{path_info: ["api", resource, _ | _]}) when resource in ~w(agents users),
    do: ["name"]

  defp path_keys(%{path_info: ["api", "settings", _]}), do: ["key"]
  defp path_keys(_), do: []

  defp plain(%Jason.OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if length(keys) != MapSet.size(MapSet.new(keys)) do
      {:error, :duplicate}
    else
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case plain(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp plain(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case plain(value) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  defp plain(value), do: {:ok, value}

  defp refuse(conn, status, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{error: code, message: "Request refused by trusted-local API policy."})
    )
    |> halt()
  end
end
