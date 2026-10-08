defmodule Nano.RawLog do
  @moduledoc """
  A debugging record of model requests and responses (image data and secrets redacted), for the agents the
  `raw_model_log` setting names (`on?/1`), from their next request. The harness log keeps
  what the providers' answers were decoded to; this keeps what went over the wire, so a
  question such as "did the model send these words run together, or did we join them?" can
  be settled.

  Each HTTP exchange of a model call is three files under `<LOG_DIR>/raw/<agent id>/`, named
  for the request and the attempt (`NanoAgent` makes up to 3): `<request id>-<attempt>.request.txt`,
  `.response.txt` and `.timing.txt`. A second exchange in one attempt (the ChatGPT subscription
  refreshes a refused token once and sends again) adds `.2` to the name. The request and the
  response are each an HTTP message, a first line (`POST <url>`, or `HTTP <status>`), the
  headers one per line, a blank line, then the body's bytes exactly:

      HTTP 200
      content-type: text/event-stream
      ...

      event: response.created
      data: {"type":"response.created",...}

  The request is recorded as `Req` hands it to the HTTP client, after all its other request
  steps: the JSON as encoded, and the headers that were sent. The response body is read as the
  HTTP client takes each piece of it off the connection (`Req`'s `into:`), and recorded once
  whole, before any of `Req`'s response steps: before it decodes JSON, and before
  `Nano.ChatGPT` parses the event stream, which see the same bytes they would otherwise.
  (`Req` asks for no compression; a body the provider compressed anyway would be recorded
  compressed.) The timing file says when each piece came, a line each: milliseconds since the
  request was sent (connecting included), where the piece starts in the body, and its size in
  bytes, so the long silences of a model reasoning show:

      ms offset bytes
      812 0 297
      15204 297 1180

  No response at all is recorded as `no response:` and why, with no timing; so is a request
  `NanoAgent` cancels for taking too long (`cancelled/2`). The files of an exchange are
  written apart, the request before it is sent, so a request that never gets an answer is
  still there; each is written whole (a temp file, renamed).

  Headers that carry credentials (authorization, chatgpt-account-id, cookies, anything named
  like a key, token or secret) are written as `[redacted]`. Inline image data URLs in
  requests, responses and errors are replaced by `[redacted image data]`. Other body
  bytes are retained: a request holds the agent's whole conversation. Timing offsets refer
  to original wire bytes, not the redacted files. Compressed response bodies are omitted.

  Recording never fails or holds up a model call: a file that cannot be written is skipped,
  with one warning in the node's log (`Logger`) until the node restarts. After each attempt
  that wrote files, the oldest files under `raw/` (by modification time, over all agents) are
  deleted until they add up to at most the `raw_model_log_max_bytes` setting; the attempt's own
  are kept.
  """
  require Logger

  @key {__MODULE__, :recording}
  @warned {__MODULE__, :warned}
  @secret ~r/authorization|cookie|account|key|token|secret|password/i

  @doc "Redact inline image data URLs, including JSON-escaped slashes, from a log string."
  def redact(text) when is_binary(text) do
    Regex.replace(
      ~r/data:image(?:\\*\/)[^,\s"'<>]*,[A-Za-z0-9+\/_=\\%-]*/i,
      text,
      "[redacted image data]"
    )
  end

  @doc "Recursively redact image data in decoded provider responses/errors before harness logging."
  def sanitize(text) when is_binary(text), do: redact(text)
  def sanitize(list) when is_list(list), do: Enum.map(list, &sanitize/1)
  def sanitize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, sanitize(v)} end)
  def sanitize(other), do: other

  @doc "Where the files are: `<LOG_DIR>/raw`."

  def dir, do: Path.join(Application.fetch_env!(:nano, :log_dir), "raw")

  @doc "Whether an agent's model requests are recorded now (setting `raw_model_log`), by its name."
  def on?(agent) do
    case Nano.Settings.get(:raw_model_log) do
      "off" -> false
      "all" -> true
      names -> agent in String.split(names, ", ")
    end
  end

  @doc """
  Runs `fun`, one attempt of a model call, recording every exchange the model requests made in
  it (`attach/1`) under `name`, `"<agent id>/<request id>-<attempt>"`; nil records nothing.
  Returns `{fun's result, files}`, the files written, as paths relative to `dir/0`.
  """
  def recording(nil, fun), do: {fun.(), []}

  def recording(name, fun) do
    Process.put(@key, {name, 0, []})
    result = fun.()
    {_, _, files} = Process.delete(@key)
    files = Enum.reverse(files)
    if files != [], do: prune(files)
    {result, files}
  end

  @doc """
  Adds the recording steps to a model request, when it is made in `recording/2`: the body
  is then read as it streams in (`into:`), each piece timed, and put together again, byte for
  byte, before `Req`'s response steps and the provider see it.
  """
  def attach(%Req.Request{} = req) do
    if Process.get(@key) do
      %{req | into: &chunk/2}
      |> Req.Request.append_request_steps(raw_model_log: &request/1)
      |> Req.Request.prepend_response_steps(raw_model_log: &response/1)
      |> Req.Request.prepend_error_steps(raw_model_log: &no_response/1)
    else
      req
    end
  end

  @doc """
  What `recording/2` under `name` would have returned, after its `fun` was killed (`NanoAgent`
  cancels a model request at the `model_call_max_ms` setting): the files its exchanges wrote,
  an exchange left without a response recorded as `no response:` and `why`. What had arrived
  of that response is not kept.
  """
  def cancelled(nil, _why), do: []

  def cancelled(name, why) do
    Process.put(@key, {name, 0, []})
    # A file the killed process was writing.
    for tmp <- Path.wildcard(Path.join(dir(), name <> ".*.tmp")), do: File.rm(tmp)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&if(&1 == 1, do: name, else: "#{name}.#{&1}"))
    |> Stream.take_while(&File.regular?(Path.join(dir(), &1 <> ".request.txt")))
    |> Enum.each(fn exchange ->
      for kind <- ~w(request response timing),
          file = "#{exchange}.#{kind}.txt",
          File.regular?(Path.join(dir(), file)),
          do: written(file)

      if not File.regular?(Path.join(dir(), exchange <> ".response.txt")),
        do: write(exchange <> ".response.txt", fn -> ["no response: ", why, ?\n] end)
    end)

    {_, _, files} = Process.delete(@key)
    files = Enum.reverse(files)
    if files != [], do: prune(files)
    files
  end

  @doc """
  The file at `path` (relative to `dir/0`, as log entries name it): `{:ok, absolute path}`,
  or `:error` for anything but `<agent id>/<file>` naming a file that exists.
  """
  def file(path) do
    parts = String.split(path, "/")

    with true <- length(parts) == 2,
         true <- Enum.all?(parts, &(&1 =~ ~r/^[\w-][\w.-]*$/)),
         path = Path.join([dir() | parts]),
         true <- File.regular?(path) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  ## Steps

  # The last request step: the body is encoded and every header is set.
  defp request(req) do
    case Process.get(@key) do
      {base, n, files} ->
        name = if n == 0, do: base, else: "#{base}.#{n + 1}"
        Process.put(@key, {base, n + 1, files})

        write(name <> ".request.txt", fn ->
          method = req.method |> to_string() |> String.upcase()
          [method, ?\s, URI.to_string(req.url), ?\n, headers(req.headers), ?\n, body(req.body)]
        end)

        req
        |> Req.Request.put_private(:raw_model_log, name)
        |> Req.Request.put_private(:raw_model_log_body, {System.monotonic_time(), [], 0, []})

      nil ->
        req
    end
  end

  # Each piece of the body as the HTTP client reads it off the connection: kept, with when it
  # came (ms since the request was sent), where it starts in the body and its size.
  defp chunk({:data, data}, {req, resp}) do
    {sent, body, size, times} = req.private.raw_model_log_body
    ms = System.convert_time_unit(System.monotonic_time() - sent, :native, :millisecond)
    line = "#{ms} #{size} #{byte_size(data)}\n"
    body = {sent, [body | data], size + byte_size(data), [line | times]}
    {:cont, {Req.Request.put_private(req, :raw_model_log_body, body), resp}}
  end

  # The first response step: the body put together as the HTTP client returned it, and the
  # timing of its pieces.
  defp response({req, resp}) do
    case req.private[:raw_model_log_body] do
      {sent, body, _, times} ->
        resp = %{resp | body: IO.iodata_to_binary(body)}

        write(req.private.raw_model_log <> ".response.txt", fn ->
          ["HTTP #{resp.status}\n", headers(resp.headers), ?\n, logged_body(resp)]
        end)

        write(req.private.raw_model_log <> ".timing.txt", fn ->
          ["ms offset bytes\n" | Enum.reverse(times)]
        end)

        {Req.Request.put_private(req, :raw_model_log_body, {sent, [], 0, []}), resp}

      nil ->
        {req, resp}
    end
  end

  defp logged_body(resp) do
    case Map.get(resp.headers, "content-encoding", []) do
      enc when enc in [[], ["identity"]] -> resp.body
      _ -> "[compressed response body omitted]"
    end
  end

  defp no_response({req, exception}) do
    if name = req.private[:raw_model_log] do
      write(name <> ".response.txt", fn ->
        ["no response: ", Exception.message(exception), ?\n]
      end)
    end

    {req, exception}
  end

  defp headers(headers) do
    for {name, values} <- Enum.sort(headers), value <- List.wrap(values) do
      [name, ": ", if(name =~ @secret, do: "[redacted]", else: value), ?\n]
    end
  end

  defp body(nil), do: ""
  defp body(body) when is_binary(body) or is_list(body), do: body
  defp body(other), do: inspect(other)

  # Whole or not at all; never raises.
  defp write(name, content) do
    path = Path.join(dir(), name)
    tmp = path <> ".tmp"

    result =
      try do
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(tmp, content.() |> IO.iodata_to_binary() |> redact()),
             do: File.rename(tmp, path)
      rescue
        e -> {:error, Exception.message(e)}
      end

    case result do
      :ok ->
        written(name)

      {:error, reason} ->
        File.rm(tmp)
        warn(path, reason)
    end
  end

  # One of the attempt's files, as recording/2 returns them.
  defp written(name) do
    {base, n, files} = Process.get(@key)
    Process.put(@key, {base, n, [name | files]})
  end

  defp warn(path, reason) do
    if not :persistent_term.get(@warned, false) do
      :persistent_term.put(@warned, true)

      Logger.warning(
        "raw_model_log: could not write #{path} (#{inspect(reason)}); model calls go on " <>
          "without it, and further failures are not reported until the node restarts"
      )
    end
  end

  ## Retention

  @doc """
  Deletes the oldest files under `dir/0` until they add up to at most the
  `raw_model_log_max_bytes` setting, except `keep` (paths relative to `dir/0`).
  """
  def prune(keep \\ []) do
    keep = Enum.map(keep, &Path.join(dir(), &1))

    files =
      for path <- Path.wildcard(Path.join(dir(), "*/*")),
          {:ok, %{type: :regular, size: size, mtime: mtime}} <- [File.stat(path, time: :posix)],
          do: {mtime, path, size}

    total = files |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    files
    |> Enum.sort()
    |> Enum.reject(fn {_, path, _} -> path in keep end)
    |> Enum.reduce_while(total, fn {_, path, size}, total ->
      cond do
        total <= Nano.Settings.get(:raw_model_log_max_bytes) -> {:halt, total}
        File.rm(path) == :ok -> {:cont, total - size}
        true -> {:cont, total}
      end
    end)

    :ok
  rescue
    e -> warn(dir(), Exception.message(e))
  end
end
