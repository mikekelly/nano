defmodule Nano.WebCacheTest do
  @moduledoc "The bounded cache and stored-text handles behind Nano.Web's paging."
  use ExUnit.Case, async: false

  alias Nano.Web.Cache

  test "stored text is retrievable by handle" do
    handle = Cache.store("https://x.test", "abcdefghij")
    assert %{text: "abcdefghij"} = Cache.get_stored(handle)
  end

  test "the cache holds urls and texts and can be emptied" do
    Cache.put("https://x.test/a", "body", %{status: 200, at: System.system_time(:millisecond)})
    assert %{body: "body"} = Cache.get("https://x.test/a")
    assert %{urls: u} = Cache.size()
    assert u >= 1
    Cache.clear()
    assert Cache.get("https://x.test/a") == nil
  end
end
