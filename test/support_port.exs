# Standalone test support for PiTools: no app boot. Ports pi's own tool tests.
# Each test gets a fresh unique temp dir, created and removed by the runner.
Code.require_file("/app/lib/pi_tools.ex")
Application.ensure_all_started(:jason)

defmodule PortTest do
  @key {__MODULE__, :failures}

  def failures, do: :persistent_term.get(@key, 0)

  def run(name, fun) do
    dir = Path.join(System.tmp_dir!(), "pi_port_#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
      IO.puts("ok   - #{name}")
    rescue
      e ->
        IO.puts("FAIL - #{name}: " <> Exception.message(e))
        :persistent_term.put(@key, failures() + 1)
    after
      File.rm_rf!(dir)
    end
  end

  def tmp_file!(dir, name, content) do
    p = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(p))
    File.write!(p, content)
    p
  end
end

defmodule A do
  def truthy!(true, _), do: :ok
  def truthy!(v, m), do: raise("#{m} (got #{inspect(v)})")

  def eq!(a, a, _), do: :ok
  def eq!(a, b, m), do: raise("#{m}: expected #{inspect(b)}, got #{inspect(a)}")

  def has!(s, sub, m) do
    if String.contains?(s, sub), do: :ok, else: raise("#{m}: #{inspect(s)} does not contain #{inspect(sub)}")
  end

  def hasnt!(s, sub, m) do
    if String.contains?(s, sub), do: raise("#{m}: #{inspect(s)} unexpectedly contains #{inspect(sub)}"), else: :ok
  end

  def match!(s, regex, m) do
    if Regex.match?(regex, s), do: :ok, else: raise("#{m}: #{inspect(s)} does not match #{inspect(regex)}")
  end
end
