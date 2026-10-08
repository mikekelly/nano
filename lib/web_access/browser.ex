defmodule WebAccess.Browser do
  @moduledoc """
  Bounded Lightpanda JavaScript rendering and localhost CDP jobs.

      WebAccess.Browser.fetch("https://example.org", timeout: 15_000, max_bytes: 100_000)
      {:ok, job} = WebAccess.Browser.serve(port: 0, timeout: 25_000)
      Background.cancel(job)

  `fetch/2` returns `{:ok, %{text: markdown, title: title, url: requested_url,
  truncated: boolean}}` or `{:error, reason}`. Title is the first Markdown heading,
  falling back to the URL host (Lightpanda's Markdown CLI does not expose document.title).
  URLs must be HTTP(S), without credentials or whitespace. This is not an SSRF sandbox:
  trusted callers may access local/private URLs and pages may load subresources.

  Both calls accept `:timeout` (default 15 seconds, capped at 25 seconds),
  and `:executable` (default
  `/usr/local/bin/lightpanda`, useful for per-call test doubles). Positive limits above
  the cap are clamped; invalid options return errors. Shell arguments are quoted.
  Fetch output defaults to 12000 bytes, hard cap24000. Use `WebAccess.fetch(url, browser: true)`
  for cached paging of larger pages. CDP logs default1MiB, hard cap2MiB via `:max_bytes`.
  GNU timeout independently enforces lifetime; shell file limits bound disk output.

  CDP binds only 127.0.0.1. `serve/1` requires `:port` (0 lets the OS choose); its
  Background job is a start acknowledgement, not readiness. Inspect its bounded log
  with `Workspace.tail(job.path)` for the endpoint or startup errors. Cancel with
  `Background.cancel(job)`; completion follows Background's usual event protocol.
  Background logs remain for inspection; fetch's temporary render files are removed.
  JavaScript is enabled; fetching waits for network-almost-idle, subject to timeout.
  No shared browser profile, cookies, cache, or paging state is kept here.
  """

  @default_bytes 1_048_576
  @max_bytes 2_097_152

  @doc "Render one HTTP(S) URL as bounded UTF-8 Markdown."
  def fetch(url, opts \\ []) do
    if is_list(opts) and Keyword.keyword?(opts) do
      bytes = Keyword.get(opts, :max_bytes, 12_000)

      if is_integer(bytes) and bytes > 0,
        do: render(url, Keyword.put(opts, :max_bytes, min(bytes, 24_000))),
        else: {:error, :invalid_max_bytes}
    else
      {:error, :invalid_options}
    end
  end

  @doc false
  def render(url, opts \\ []) do
    with {:ok, uri} <- validate_url(url),
         {:ok, config} <- config(opts),
         {:ok, dir} <- temp_dir() do
      try do
        output = Path.join(dir, "markdown")
        errors = Path.join(dir, "stderr")

        args = [
          "fetch",
          "--dump",
          "markdown",
          "--dump-max-bytes",
          to_string(config.max_bytes + 1),
          "--fail-on-http-error",
          "--wait-until",
          "networkalmostidle",
          "--wait-ms",
          to_string(config.timeout),
          "--log-level",
          "fatal",
          url
        ]

        command = bounded_command(config, args, quote_sh(output), quote_sh(errors))

        with {:ok, result} <-
               Workspace.sh(command,
                 timeout: config.timeout + 1000,
                 output_dir: dir
               ),
             {:ok, text} <- read_head(output, config.max_bytes + 32) do
          render_result(result.status, text, url, uri.host, config.max_bytes, errors)
        end
      after
        File.rm_rf(dir)
      end
    end
  rescue
    e -> {:error, {:browser, Exception.message(e)}}
  end

  @doc "Start a bounded localhost CDP Background job; stop with Background.cancel/1."
  def serve(opts \\ []) do
    with {:ok, config} <- config(opts),
         port when is_integer(port) and port >= 0 and port <= 65_535 <- opts[:port] do
      args = ["serve", "--host", "127.0.0.1", "--port", to_string(port)]
      command = bounded_command(config, args, nil, nil)

      job_opts = [
        timeout: config.timeout + 1000,
        output_dir: Path.join(System.tmp_dir!(), "web-access-browser-cdp")
      ]

      job_opts =
        if opts[:notify], do: Keyword.put(job_opts, :notify, opts[:notify]), else: job_opts

      Background.start(command, job_opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_port}
    end
  rescue
    e -> {:error, {:browser, Exception.message(e)}}
  end

  defp config(opts) do
    if is_list(opts) and Keyword.keyword?(opts) do
      timeout = Keyword.get(opts, :timeout, 15_000)
      bytes = Keyword.get(opts, :max_bytes, @default_bytes)
      executable = Keyword.get(opts, :executable, "/usr/local/bin/lightpanda")

      cond do
        not is_integer(timeout) or timeout <= 0 ->
          {:error, :invalid_timeout}

        not is_integer(bytes) or bytes <= 0 ->
          {:error, :invalid_max_bytes}

        not is_binary(executable) or String.contains?(executable, <<0>>) ->
          {:error, :invalid_executable}

        true ->
          case System.find_executable(executable) do
            nil ->
              {:error, :executable_not_found}

            path ->
              {:ok,
               %{
                 executable: path,
                 timeout: min(timeout, 25_000),
                 max_bytes: min(bytes, @max_bytes)
               }}
          end
      end
    else
      {:error, :invalid_options}
    end
  end

  defp validate_url(url) when is_binary(url) do
    with true <- String.valid?(url) and byte_size(url) <= 16_384,
         false <- Regex.match?(~r/[\s\x00-\x1f\x7f\\]/u, url),
         {:ok, uri} <- URI.new(url),
         true <- uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
         true <- is_nil(uri.userinfo),
         true <- is_integer(uri.port) and uri.port in 1..65_535 do
      {:ok, uri}
    else
      _ -> {:error, :invalid_url}
    end
  end

  defp validate_url(_), do: {:error, :invalid_url}

  defp bounded_command(config, args, output, errors) do
    # /bin/bash defines ulimit -f in KiB; allowance includes the truncation marker.
    blocks = div(config.max_bytes + 32 + 1023, 1024)
    executable = Enum.map_join([config.executable | args], " ", &quote_sh/1)
    redirects = if output, do: " > " <> output <> " 2> " <> errors, else: ""
    script = "ulimit -c 0; ulimit -f #{blocks}; exec " <> executable <> redirects

    "exec /usr/bin/timeout --foreground --signal=KILL #{config.timeout / 1000}s /bin/bash -c " <>
      quote_sh(script)
  end

  defp render_result(status, _text, _url, _host, _cap, _errors)
       when status in [:timeout, 124, 137], do: {:error, :timeout}

  defp render_result(status, text, url, host, cap, errors) do
    # SIGXFSZ (153) is expected for a misbehaving executable exceeding its disk cap.
    if status == 0 or (status in [25, 153] and byte_size(text) > cap) do
      truncated = byte_size(text) > cap or String.ends_with?(text, "[truncated]\n")
      text = utf8_prefix(text, cap)

      title =
        case Regex.run(~r/^\#{1,6}\s+(.+)$/m, text, capture: :all_but_first) do
          [heading] -> utf8_prefix(String.trim(heading), 300)
          _ -> host
        end

      {:ok, %{text: text, title: title, url: url, truncated: truncated}}
    else
      detail =
        case read_head(errors, 2048) do
          {:ok, detail} -> utf8_prefix(detail, 2048)
          _ -> ""
        end

      {:error, {:exit_status, status, detail}}
    end
  end

  defp utf8_prefix(text, cap) do
    prefix = binary_part(text, 0, min(byte_size(text), cap))

    case :unicode.characters_to_binary(prefix) do
      binary when is_binary(binary) -> binary
      {:incomplete, valid, _} -> valid
      {:error, valid, _} -> valid
    end
  end

  defp read_head(path, cap) do
    case :file.open(String.to_charlist(path), [:read, :binary]) do
      {:ok, file} ->
        try do
          case :file.read(file, cap) do
            :eof -> {:ok, ""}
            result -> result
          end
        after
          :file.close(file)
        end

      error ->
        error
    end
  end

  defp temp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "web-access-browser-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    case File.mkdir(dir) do
      :ok -> {:ok, dir}
      error -> error
    end
  end

  defp quote_sh(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
