# Each case is one disposable fresh VM. Preserve original reproduced artifact unchanged.
[mode] = System.argv()
Mix.Task.run("app.config")

paths =
  Map.new(
    [:test_dir, :state_dir, :log_dir, :spill_dir, :image_dir, :web_cache_dir, :safety_dir],
    fn k ->
      path = Application.fetch_env!(:nano, k)
      unless String.starts_with?(path, "/tmp/altair-pull-ef1b6e8d-"), do: raise("unsafe root")
      {k, path}
    end
  )

IO.inspect(paths, label: "BINDING_DIGEST_PATH_AUDIT")
source = "/data/altair-flywheel/runs/pull-ef1b6e8d/runtime/restoration-final/state"
File.mkdir_p!(paths.state_dir)

for path <- Path.wildcard(source <> "/*"),
    File.regular?(path),
    do: File.cp!(path, Path.join(paths.state_dir, Path.basename(path)))

name = "u06-disposable-restoration"
epath = Path.join(paths.state_dir, name <> ".envelope-v1")
e = File.read!(epath) |> :erlang.binary_to_term()
b = Path.join(paths.state_dir, e.blob) |> File.read!() |> :erlang.binary_to_term()

b =
  case mode do
    "wrong-id" -> %{b | id: "other-id"}
    "wrong-generation" -> %{b | lifecycle_generation: b.lifecycle_generation + 1}
    _ -> b
  end

# Deliberately vary valid ETF small-map pair order, guaranteeing that decoding then
# re-encoding does not reproduce the immutable byte representation in this VM.
encode = fn map, reverse ->
  pairs = Enum.sort(Map.to_list(map))
  pairs = if reverse, do: Enum.reverse(pairs), else: pairs

  <<131, 116, map_size(map)::32>> <>
    Enum.map_join(pairs, fn {key, value} ->
      <<131, k::binary>> = :erlang.term_to_binary(key)
      <<131, v::binary>> = :erlang.term_to_binary(value)
      k <> v
    end)
end

bytes = encode.(b, false)
bytes = if bytes == :erlang.term_to_binary(b), do: encode.(b, true), else: bytes
true = :erlang.binary_to_term(bytes) == b
false = bytes == :erlang.term_to_binary(b)
digest = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
file = name <> "." <> digest <> ".bindings-v1"

File.write!(
  Path.join(paths.state_dir, file),
  if(mode == "corrupt", do: bytes <> <<0>>, else: bytes)
)

e = %{e | blob: file}
e = if mode == "wrong-revision", do: %{e | revision: 0}, else: e
File.write!(epath, :erlang.term_to_binary(e))
{:ok, _} = Application.ensure_all_started(:nano)

case mode do
  "valid" ->
    %{status: :durable} = Nano.StateStore.durability(name)
    pid = NanoAgent.whereis(name)
    true = is_pid(pid)
    true = :sys.get_state(pid).bindings[:durable] == 23
    true = File.read!(Path.join(paths.state_dir, file)) == bytes

  _ ->
    %{status: :unavailable} = Nano.StateStore.durability(name)
    nil = Nano.StateStore.get(name)
    nil = NanoAgent.whereis(name)
end

IO.puts("BINDING_DIGEST #{mode} passed; schema/identity/generation/revision fences preserved")
Application.stop(:nano)
