defmodule Seedling.Web.Transport do
  @moduledoc "Bounded curl/Lightpanda port runner. No shell interpolation; errors are values."
  def run(executable, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 25_000)
    cap = Keyword.get(opts, :max_bytes, 2_000_000)

    case System.find_executable(executable) do
      nil ->
        {:error, {:missing_executable, executable}}

      path ->
        runner = System.find_executable("timeout")
        args = ["--signal=KILL", Float.to_string(timeout / 1000), path | args]

        port =
          Port.open({:spawn_executable, runner}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            args: args
          ])

        collect(port, [], 0, cap, System.monotonic_time(:millisecond) + timeout)
    end
  rescue
    e -> {:error, {:transport, Exception.message(e)}}
  end

  defp collect(port, acc, size, cap, deadline) do
    receive do
      {^port, {:data, data}} ->
        if size + byte_size(data) > cap do
          Port.close(port)
          {:error, {:body_too_large, cap}}
        else
          collect(port, [data | acc], size + byte_size(data), cap, deadline)
        end

      {^port, {:exit_status, 0}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, code}} when code in [124, 137] ->
        {:error, :timeout}

      {^port, {:exit_status, code}} ->
        {:error, {:exit, code}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Port.close(port)
        {:error, :timeout}
    end
  end

  def http(url, opts \\ []) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      headers =
        Enum.flat_map(Keyword.get(opts, :headers, []), fn {k, v} -> ["-H", k <> ": " <> v] end)

      body =
        case Keyword.get(opts, :body) do
          nil ->
            []

          body ->
            [
              "-X",
              "POST",
              "-H",
              "Content-Type: application/json",
              "--data-binary",
              Jason.encode!(body)
            ]
        end

      args =
        [
          "--silent",
          "--show-error",
          "--location",
          "--max-redirs",
          "5",
          "--proto",
          "=http,https",
          "--proto-redir",
          "=http,https",
          "--max-time",
          "24",
          "--write-out",
          "\n%{http_code}"
        ] ++ headers ++ body ++ [url]

      with {:ok, raw} <- run("curl", args, opts) do
        split = byte_size(raw) - 4
        <<content::binary-size(^split), "\n", status::binary-size(3)>> = raw
        code = String.to_integer(status)
        if code in 200..299, do: {:ok, content}, else: {:error, {:http, code}}
      end
    else
      {:error, :invalid_url}
    end
  rescue
    _ -> {:error, :invalid_response}
  end
end
