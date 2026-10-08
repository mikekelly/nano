defmodule NanoWeb.BotsMarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  require Phoenix.LiveViewTest

  alias NanoWeb.BotsMarkdown

  defp html(text), do: text |> BotsMarkdown.render() |> Phoenix.HTML.safe_to_string()
  defp escaped(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  defp dom(text), do: text |> html() |> LazyHTML.from_fragment()

  defp message(assigns) do
    ~H"""
    <div>{BotsMarkdown.render(@text)}</div>
    """
  end

  test "returns safe iodata that HEEx inserts without trusting source HTML" do
    assert {:safe, iodata} = BotsMarkdown.render("**hello** <script>alert(1)</script>")
    assert is_list(iodata)

    rendered =
      Phoenix.LiveViewTest.render_component(&message/1,
        text: "**hello** <script>alert(1)</script>"
      )

    assert rendered =~ "<strong>hello</strong> &lt;script&gt;alert(1)&lt;/script&gt;"
    refute rendered =~ "<script>"
    refute rendered =~ "&amp;lt;script"
  end

  test "empty and non-binary inputs cannot smuggle safe tuples or protocols" do
    for input <- [nil, "", " \n\t\n", 123, %{}, ["<script>"], {:safe, "<script>"}] do
      assert html(input) == ""
    end
  end

  test "paragraphs preserve soft line breaks and normalize CRLF and CR" do
    assert html("first\r\nsecond\r\n\r\nthird\rfourth\n") ==
             "<p>first\nsecond</p><p>third\nfourth</p>"
  end

  test "all six headings support inline markup and stop paragraphs" do
    for level <- 1..6 do
      assert html("before\n" <> String.duplicate("#", level) <> " **title**\nafter") ==
               "<p>before</p><h#{level}><strong>title</strong></h#{level}><p>after</p>"
    end

    assert html("   ## title") == "<h2>title</h2>"
    assert html("#") == "<h1></h1>"

    assert html("####### title\n#not a heading\n    # indented") ==
             "<p>####### title\n#not a heading\n    # indented</p>"
  end

  test "flat lists coalesce by type and close at paragraph or blank boundaries" do
    assert html("intro\n- one\n+ **two**\n* `three`\n4. four\n5. five\nend\n\n- six") ==
             "<p>intro</p><ul><li>one</li><li><strong>two</strong></li>" <>
               "<li><code>three</code></li></ul><ol><li>four</li><li>five</li></ol>" <>
               "<p>end</p><ul><li>six</li></ul>"

    assert html("- one\n\n- two") == "<ul><li>one</li></ul><ul><li>two</li></ul>"
    assert html("1234567890. not a list") == "<p>1234567890. not a list</p>"
  end

  test "inline tokens escape their text and do not interpret their contents" do
    assert html("`**literal** <b>&` *italics* _also_ **bold** __strong__") ==
             "<p><code>**literal** &lt;b&gt;&amp;</code> <em>italics</em> " <>
               "<em>also</em> <strong>bold</strong> <strong>strong</strong></p>"

    assert html("**<img src=x onerror=alert(1)>**") ==
             "<p><strong>&lt;img src=x onerror=alert(1)&gt;</strong></p>"

    assert html("*one*`two`**three**") ==
             "<p><em>one</em><code>two</code><strong>three</strong></p>"

    assert html("before `unclosed *unclosed [x](bad\nafter") ==
             "<p>before `unclosed *unclosed [x](bad\nafter</p>"
  end

  test "fenced code is opaque to Markdown and HTML and preserves blank lines" do
    source =
      "```elixir\n# heading\n\n- item\n[x](https://example.com)\n<script>&</script>\n```\nafter"

    assert html(source) ==
             "<pre><code># heading\n\n- item\n[x](https://example.com)\n" <>
               "&lt;script&gt;&amp;&lt;/script&gt;\n</code></pre><p>after</p>"
  end

  test "fences close only with the same character and sufficient length" do
    assert html("````\n```\n~~~\n```` trailing text\n`````\n# after") ==
             "<pre><code>```\n~~~\n```` trailing text\n</code></pre><h1>after</h1>"

    assert html("   ~~~ info\ncode\n   ~~~~ \t\nafter") ==
             "<pre><code>code\n</code></pre><p>after</p>"

    assert html("```\n```") == "<pre><code></code></pre>"
    assert html("```\n\n```") == "<pre><code>\n</code></pre>"
  end

  test "unclosed fences stay escaped through EOF and ignore malicious info strings" do
    source = "```\" onmouseover=\"alert(1)\"><script>\n</code></pre><svg/onload=alert(1)>\n\n"

    assert html(source) ==
             "<pre><code>&lt;/code&gt;&lt;/pre&gt;&lt;svg/onload=alert(1)&gt;\n\n</code></pre>"

    assert html("~~~\n**still code**") == "<pre><code>**still code**\n</code></pre>"
  end

  test "literal HTTP and HTTPS URLs are linked with escaped attributes and plain labels" do
    for url <- [
          "https://example.com",
          "http://example.com/path?q=one&x=two#anchor",
          "HTTPS://example.com"
        ] do
      source = "[**label** <b>&](#{url})"
      tree = dom(source)
      assert LazyHTML.attribute(LazyHTML.query(tree, "a"), "href") == [url]

      assert LazyHTML.attribute(LazyHTML.query(tree, "a"), "rel") == [
               "nofollow noopener noreferrer"
             ]

      assert LazyHTML.text(LazyHTML.query(tree, "a")) == "**label** <b>&"
      assert Enum.empty?(LazyHTML.query(tree, "b,strong"))
      assert html(source) =~ "href=\"#{escaped(url)}\""
    end
  end

  test "unsafe and ambiguous link destinations never create anchors" do
    urls = [
      "javascript:alert(1)",
      "javascript:alert%281%29",
      "JaVaScRiPt:alert%281%29",
      "data:text/html;base64,PHNjcmlwdD4=",
      "vbscript:msgbox%281%29",
      "file:///etc/passwd",
      "ftp://example.com",
      "blob:https://example.com/id",
      " javascript:alert%281%29",
      "https://example.com:not-a-port",
      "https://[broken",
      "mailto:attacker@example.com",
      "//example.com",
      "/api/eval",
      "#fragment",
      "https:",
      "https:///example.com",
      "http://",
      "https://user:password@example.com",
      "https://example.com\\@evil.example",
      "https://example.com/\"onmouseover=\"alert",
      "https://example.com/<script>",
      "https://example.com/`onclick`",
      "https://example.com/with space",
      "https://example.com/\tcontrol",
      "https://example.com/\ncontrol",
      "https://example.com/\rcontrol",
      "https://example.com/\u0000control",
      "https://example.com/\u007Fcontrol",
      "https://example.com/\u0085control",
      "https://example.com/\u00A0space",
      "https://example.com/\u200Bzero-width"
    ]

    for url <- urls do
      source = "[click](#{url})"
      assert Enum.empty?(LazyHTML.query(dom(source), "a")), "linked unsafe URL: #{inspect(url)}"
      assert_safe_tree(source)
    end
  end

  test "entity, percent and control obfuscation cannot bypass scheme validation" do
    for url <- [
          "jav&#x61;script:alert%281%29",
          "javascript&#58;alert%281%29",
          "&#106;avascript:alert%281%29",
          "&#x6a;avascript:alert%281%29",
          "&Tab;javascript:alert%281%29",
          "java&NewLine;script:alert%281%29",
          "java\tscript:alert%281%29",
          "java\nscript:alert%281%29",
          "java\rscript:alert%281%29",
          "java\u0000script:alert%281%29",
          "%6Aavascript:alert%281%29",
          "https&#58;//example.com",
          "https%3A//example.com"
        ] do
      source = "[click](#{url})"

      assert Enum.empty?(LazyHTML.query(dom(source), "a")),
             "linked obfuscated URL: #{inspect(url)}"

      assert_safe_tree(source)
    end
  end

  test "entities in otherwise valid URLs remain literal after one HTML parse" do
    url = "https://example.com/?x=&quot;onmouseover=&quot;alert&y=&#x27;"
    source = "[safe](#{url})"
    assert LazyHTML.attribute(LazyHTML.query(dom(source), "a"), "href") == [url]
    assert html(source) =~ "&amp;quot;"
    assert_safe_tree(source)
  end

  test "raw HTML and existing entities remain text in every supported block context" do
    for payload <- [
          "<script>fetch('/api/eval',{method:'POST'})</script>",
          "<img src=x onerror=alert(1)>",
          "<svg><a xlink:href=javascript:alert(1)>x</a></svg>",
          "<math><mtext><img src=x onerror=alert(1)></mtext></math>",
          "<iframe srcdoc='<script>alert(1)</script>'></iframe>",
          "<style>body{display:none}</style>",
          "<a href=javascript:alert(1)>click</a>",
          "<!--comment--><script>alert(1)</script>",
          "&lt;script&gt;alert(1)&lt;/script&gt;",
          "&#60;img src=x onerror=alert(1)&#62;",
          "</textarea><script>alert(1)</script>"
        ] do
      assert html(payload) == "<p>#{escaped(payload)}</p>"

      for source <- [
            payload,
            "# #{payload}",
            "- #{payload}",
            "1. #{payload}",
            "`#{payload}`",
            "```\n#{payload}\n```"
          ] do
        assert_safe_tree(source)
      end
    end
  end

  test "images, autolinks and reference links do not load remote resources" do
    source = "![image](https://example.com/image.svg) <https://example.com> [label][reference]"
    assert html(source) == "<p>#{escaped(source)}</p>"
    assert Enum.empty?(LazyHTML.query(dom(source), "a,img,iframe,video,audio,source"))
  end

  test "input is capped by bytes, emits a notice, and never sees content beyond the cap" do
    boundary = String.duplicate("a", 65_536)
    assert html(boundary) == "<p>#{boundary}</p>"
    output = html(boundary <> "<script>hidden</script>" <> String.duplicate("b", 1_000_000))
    assert output == "<p>#{boundary}</p><p>[Markdown truncated at 65,536 bytes.]</p>"
    refute output =~ "hidden"

    output = html("```\n" <> String.duplicate("<", 65_536) <> "\n```\n<script>")
    assert output =~ "</code></pre><p>[Markdown truncated at 65,536 bytes.]</p>"
    refute output =~ "<script>"
  end

  test "invalid and truncated UTF-8 become replacement characters, never crashes" do
    assert html(<<255, ?<, ?&, 192>>) == "<p>�&lt;&amp;�</p>"
    output = html(String.duplicate("a", 65_535) <> "😀")
    assert String.valid?(output)
    assert output =~ "�</p><p>[Markdown truncated"
    assert html("Hello 👋 café") == "<p>Hello 👋 café</p>"
  end

  test "inline scans have explicit size limits" do
    for {left, right} <- [{"`", "`"}, {"*", "*"}, {"_", "_"}] do
      source = left <> String.duplicate("a", 2049) <> right
      assert html(source) == "<p>#{source}</p>"
    end

    for source <- [
          "[" <> String.duplicate("a", 513) <> "](https://example.com)",
          "[label](https://example.com/" <> String.duplicate("a", 2049) <> ")"
        ] do
      assert html(source) == "<p>#{source}</p>"
    end
  end

  @tag timeout: 10_000
  test "bounded adversarial delimiters and many blocks complete with safe bounded output" do
    for fragment <- ["[x](", "[", "**_`", "[a](https://", "# x\n", "- x\n", "```\nx\n```\n"] do
      source = String.duplicate(fragment, div(65_536, byte_size(fragment)) + 1)
      output = html(source)
      assert String.valid?(output)
      assert byte_size(output) < 1_000_000
      assert output =~ "[Markdown truncated at 65,536 bytes.]"
    end
  end

  defp assert_safe_tree(source) do
    source |> dom() |> LazyHTML.to_tree() |> Enum.each(&assert_safe_node/1)
  end

  defp assert_safe_node(text) when is_binary(text), do: :ok

  defp assert_safe_node({tag, attributes, children}) do
    assert tag in ~w(p h1 h2 h3 h4 h5 h6 ul ol li pre code em strong a)

    if tag == "a" do
      assert Enum.sort(Enum.map(attributes, &elem(&1, 0))) == ["href", "rel"]
      assert {"rel", "nofollow noopener noreferrer"} in attributes
      {"href", href} = List.keyfind(attributes, "href", 0)
      assert Regex.match?(~r/\Ahttps?:\/\//i, href)
    else
      assert attributes == []
    end

    Enum.each(children, &assert_safe_node/1)
  end
end
