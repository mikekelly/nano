defmodule Nano.Bots.RenderTest do
  use ExUnit.Case, async: true
  defp html(s), do: Nano.Bots.Render.markdown(s) |> Phoenix.HTML.safe_to_string()

  test "raw HTML and attribute payloads are text" do
    for text <- [
          "<script>fetch('/api/eval')</script>",
          "<img src=x onerror=alert(1)>",
          "<svg onload=alert(1)>",
          "<style>body{}</style>"
        ] do
      rendered = html(text)
      refute rendered =~ "<script"
      refute rendered =~ "<img"
      refute rendered =~ "<svg"
      refute rendered =~ "<style"
      assert rendered =~ "&lt;"
    end
  end

  test "unsafe URLs never produce links" do
    for url <- [
          "javascript:alert(1)",
          "JaVaScRiPt:alert(1)",
          "javascript&#58;alert(1)",
          "&#106;avascript:foo",
          "data:text/html,x",
          "//evil.test",
          "/api/eval",
          "https://good.test\\@evil.test",
          "https://good.test/\tfoo",
          "https://good.test/\u0000foo",
          "https://good.test/?x=&quot;onmouseover=x",
          "file:///etc/passwd"
        ] do
      refute html("[click](#{url})") =~ "<a "
    end

    assert html("[safe](https://example.com/path)") =~ ~s(href="https://example.com/path")
  end

  test "subset renders and code does not execute" do
    rendered =
      html(
        "**bold** *em* `code`\n\n- one\n- two\n\n1. first\n\n```html\n<script>bad</script>\n```"
      )

    assert rendered =~ "<strong>bold</strong>"
    assert rendered =~ "<em>em</em>"
    assert rendered =~ "<code>code</code>"
    assert rendered =~ "<ul><li>one</li><li>two</li></ul>"
    assert rendered =~ "<ol><li>first</li></ol>"
    assert rendered =~ "<pre><code>&lt;script&gt;bad&lt;/script&gt;</code></pre>"
    refute html("![image](https://evil.test/tracker)") =~ "<img"
    assert html("&lt;script&gt;") =~ "&amp;lt;script&amp;gt;"
  end
end
