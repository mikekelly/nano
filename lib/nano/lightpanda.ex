defmodule Nano.Lightpanda do
  @moduledoc "Bounded Lightpanda markdown rendering. For cached paging use Nano.Web.fetch(url, browser: true)."
  def fetch(url, opts \\ []) do
    with :ok <- Nano.Web.valid_url(url),
         executable when is_binary(executable) <-
           Keyword.get(opts, :executable, System.find_executable("lightpanda")) do
      timeout = System.find_executable("timeout")

      if timeout do
        case System.cmd(
               timeout,
               [
                 "--kill-after=1",
                 "#{Keyword.get(opts, :timeout, 20_000) / 1000}s",
                 executable,
                 "fetch",
                 "--dump",
                 "markdown",
                 url
               ],
               stderr_to_stdout: false
             ) do
          {text, 0} ->
            if byte_size(text) <= Keyword.get(opts, :max_download_bytes, 5_000_000),
              do: {:ok, text},
              else: {:error, :page_too_large}

          {_, code} when code in [124, 137] ->
            {:error, :timeout}

          {_, code} ->
            {:error, {:browser_exit, code}}
        end
      else
        {:error, :timeout_executable_missing}
      end
    else
      nil -> {:error, :lightpanda_missing}
      error -> error
    end
  rescue
    _ -> {:error, :browser_failed}
  end
end
