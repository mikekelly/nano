defmodule Vega.Bots.MarkdownTest do
  use ExUnit.Case, async: true
  alias Vega.Bots.Markdown
  defp html(text), do: text |> Markdown.render() |> Phoenix.HTML.safe_to_string()

  test "paragraphs, lists and emphasis" do
    assert html("hello **bold** and *italic*\nworld\n\nnext") ==
             "<p>hello <strong>bold</strong> and <em>italic</em>\nworld</p><p>next</p>"

    assert html("- one\n- two\n\n1. first\n2. second") ==
             "<ul><li>one</li><li>two</li></ul><ol><li>first</li><li>second</li></ol>"

    assert html(nil) == ""
    assert html(" \n\n") == ""
    assert html("héllo __世界__") == "<p>héllo <strong>世界</strong></p>"
  end

  test "inline and fenced code escape HTML and do not interpret markdown" do
    assert html("`<script>& **bold**`") == "<p><code>&lt;script&gt;&amp; **bold**</code></p>"

    assert html("```html\n<img src=x onerror=alert(1)>\n**bold**\n```\nafter") ==
             "<pre><code>&lt;img src=x onerror=alert(1)&gt;\n**bold**</code></pre><p>after</p>"

    assert html("```\n<script>") == "<pre><code>&lt;script&gt;</code></pre>"
  end

  test "all raw HTML, entities and attribute delimiters are escaped" do
    for payload <- [
          "<script>alert(1)</script>",
          "<img src=x onerror=alert(1)>",
          "<svg onload=alert(1)>",
          "</p><iframe srcdoc='evil'>",
          "<!-- comment -->",
          "<style>body{}</style>",
          "&lt;script&gt;",
          "\"'&<>"
        ] do
      rendered = html(payload)
      refute rendered =~ ~r/<(?:script|img|svg|iframe|style|!--)/i

      assert rendered ==
               "<p>" <>
                 (payload |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()) <>
                 "</p>"
    end

    assert html("**<img src=x>**") == "<p><strong>&lt;img src=x&gt;</strong></p>"
    assert html("- <script>") == "<ul><li>&lt;script&gt;</li></ul>"
  end

  test "links allow only unambiguous absolute HTTP(S) URLs" do
    assert html("[**safe**](https://example.com/?a=1&b=2)") ==
             "<p><a href=\"https://example.com/?a=1&amp;b=2\" rel=\"noopener noreferrer\"><strong>safe</strong></a></p>"

    assert html("[safe](http://example.com)") =~ "href=\"http://example.com\""

    for url <- [
          "javascript:alert(1)",
          "data:text/html,evil",
          "vbscript:evil",
          "/relative",
          "//evil.example",
          "https:",
          "https:///evil",
          "https://",
          "HTTPS://example.com",
          "https://user@evil.example",
          "https://example.com\\@evil",
          "https://example.com/\" onclick=evil",
          " https://example.com",
          "https://example.com/\tfoo",
          "java&#115;cript:evil",
          "https://example.com/\0evil"
        ] do
      refute html("[click](#{url})") =~ "<a "
    end

    assert html("[<img src=x>](https://example.com)") =~ "&lt;img src=x&gt;</a>"
  end

  test "images and malformed markup cannot embed remote resources" do
    for text <- [
          "![alt](https://example.com/image.png)",
          "![x](javascript:evil)",
          "[broken](",
          "**unfinished",
          "<a href='javascript:evil'>x</a>"
        ] do
      result = html(text)
      refute result =~ "<img"
      refute result =~ "<a "
    end
  end
end
