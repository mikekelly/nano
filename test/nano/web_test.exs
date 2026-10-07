defmodule Nano.WebTest do
  @moduledoc "The pure parts of Nano.Web: URL normalisation, paging, in-text search, entity decoding."
  use ExUnit.Case, async: false

  alias Nano.Web.Extract

  test "fetch_content rejects a non-URL without raising" do
    assert %{error: {:bad_url, "not a url"}} = Nano.Web.fetch!("not a url")
  end

  test "the Elixir HTML fallback strips chrome and keeps headings and links" do
    html = """
    <html><head><style>b{}</style></head><body>
    <nav>menu</nav><h2>Title</h2><p>Hello <a href="https://x.test">link</a>.</p>
    <script>var x=1</script><ul><li>one</li></ul></body></html>
    """
    text = Extract.elixir_html(html)
    assert text =~ "Title"
    assert text =~ "link (https://x.test)"
    assert text =~ "- one"
    refute text =~ "var x"
    refute text =~ "menu"
  end

  test "entities are decoded, including numeric ones" do
    assert Extract.decode_entities("caf&#233; &amp; r&#xE9;sum&#233; &quot;ok&quot;") == "café & résumé \"ok\""
  end
end
