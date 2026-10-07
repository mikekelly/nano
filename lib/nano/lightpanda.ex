defmodule Nano.Lightpanda do
  @moduledoc "Bounded Lightpanda markdown rendering. For cached paging use Nano.Web.fetch(url, browser: true)."
  def fetch(url, opts \\ []) do
    with :ok <- Nano.Web.valid_url(url),
         executable when is_binary(executable) <-
           Keyword.get(opts, :executable, System.find_executable("lightpanda")) do
      case System.find_executable("timeout") do
        nil ->
          {:error, :timeout_executable_missing}

        timeout ->
          ms = Keyword.get(opts, :timeout, 20_000)

          port =
            Port.open({:spawn_executable, String.to_charlist(timeout)}, [
              :binary,
              :exit_status,
              {:args,
               ["--kill-after=1", "#{ms / 1000}s", executable, "fetch", "--dump", "markdown", url]}
            ])

          try do
            collect(
              port,
              [],
              0,
              Keyword.get(opts, :max_download_bytes, 5_000_000),
              System.monotonic_time(:millisecond) + ms + 1500
            )
          after
            try do
              Port.close(port)
            rescue
              ArgumentError -> :ok
            end
          end
      end
    else
      nil -> {:error, :lightpanda_missing}
      error -> error
    end
  rescue
    _ -> {:error, :browser_failed}
  end

  defp collect(port, acc, bytes, cap, deadline) do
    receive do
      {^port, {:data, data}} ->
        if bytes + byte_size(data) > cap,
          do: {:error, :page_too_large},
          else: collect(port, [data | acc], bytes + byte_size(data), cap, deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, code}} when code in [124, 137] ->
        {:error, :timeout}

      {^port, {:exit_status, code}} ->
        {:error, {:browser_exit, code}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :timeout}
    end
  end
end
