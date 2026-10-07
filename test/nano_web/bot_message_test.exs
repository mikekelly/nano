defmodule NanoWeb.BotMessageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias NanoWeb.BotMessage

  test "block subset produces plain tuples with Unicode and preserved line breaks" do
    assert BotMessage.parse("# Hello 🌱\r\n## Two\r### 三\n\nhello\nworld\n\n- one\n* 二\n+ three") ==
             [
               {:heading, 1, "Hello 🌱"},
               {:heading, 2, "Two"},
               {:heading, 3, "三"},
               {:paragraph, "hello\nworld"},
               {:list, ["one", "二", "three"]}
             ]

    assert BotMessage.parse(" \n\t\n") == []
    assert BotMessage.parse("") == []
  end

  test "fences ignore info, preserve code and require matching marker and length" do
    assert BotMessage.parse("````elixir\n# code\n```\n~~~\n````\nend") == [
             {:code, "# code\n```\n~~~"},
             {:paragraph, "end"}
           ]

    assert BotMessage.parse("~~~ arbitrary <img>\n- not list\n~~~~ \t") == [
             {:code, "- not list"}
           ]

    assert BotMessage.parse("```\n<script>\n```not a close\nλ") == [
             {:code, "<script>\n```not a close\nλ"}
           ]

    assert BotMessage.parse("```") == [{:code, ""}]
  end

  test "unsupported and malformed syntax stays literal" do
    text =
      "#### deep\n#no space\n  - nested\n1. ordered\n[link](javascript:alert(1))\n![image](x)\n<b>HTML</b>\n**bold**\n``short"

    assert BotMessage.parse(text) == [{:paragraph, text}]
  end

  test "fixed tags render supported blocks without interpreting inline content" do
    html =
      render_component(&BotMessage.message/1,
        text:
          "# Title\n## Sub\n### Detail\n\n- first\n+ second\n\nparagraph\nnext\n\n```html\n<b>code</b>\n```"
      )

    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "h1") |> LazyHTML.text() == "Title"
    assert LazyHTML.query(document, "h2") |> LazyHTML.text() == "Sub"
    assert LazyHTML.query(document, "h3") |> LazyHTML.text() == "Detail"
    assert Enum.count(LazyHTML.query(document, "ul > li")) == 2
    assert LazyHTML.query(document, "p") |> LazyHTML.text() == "paragraph\nnext"
    assert LazyHTML.query(document, "pre > code") |> LazyHTML.text() == "<b>code</b>"
    assert Enum.empty?(LazyHTML.query(document, "b"))
  end

  test "HTML, attributes, links and images are escaped in every block" do
    payload =
      ~s|<script>alert(1)</script><img src=x onerror="alert(1)">& [x](javascript:evil) ![x](x)|

    text =
      "# #{payload}\n## #{payload}\n### #{payload}\n\n- #{payload}\n\n#{payload}\n\n```#{payload}\n#{payload}"

    html = render_component(&BotMessage.message/1, text: text)
    document = LazyHTML.from_fragment(html)
    assert Enum.empty?(LazyHTML.query(document, "script, img, a, iframe, svg, [onerror]"))

    for selector <- ["h1", "h2", "h3", "li", "p", "code"] do
      assert LazyHTML.query(document, selector) |> LazyHTML.text() == payload
    end

    assert html =~ "&lt;script&gt;"
    refute html =~ "javascript:evil\""
  end

  test "bounded maximum-size chat text and Unicode fences stay safe" do
    text = String.duplicate("λ", 16_000)
    assert BotMessage.parse(text) == [{:paragraph, text}]
    assert BotMessage.parse("```\n🌱\n```") == [{:code, "🌱"}]
  end
end
