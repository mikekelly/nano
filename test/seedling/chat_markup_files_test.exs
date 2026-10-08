defmodule Seedling.ChatMarkupFilesTest do
  use ExUnit.Case, async: true
  alias Seedling.{ChatMarkup, BotFiles, CapabilityStore}

  test "untrusted HTML, dangerous links and code never execute; restricted Markdown is useful" do
    input =
      "# Hello\n**bold** and `code`\n[link](https://example.test/\"onmouseover=\"bad)\n<script>alert(1)</script>\n[bad](javascript:alert(1))\n```html\n<img src=x onerror=alert(1)>\n```"

    rendered = ChatMarkup.render(input) |> Phoenix.HTML.safe_to_string()
    refute rendered =~ "<script>"
    refute rendered =~ "<img"
    refute rendered =~ "href=\"javascript:"
    assert rendered =~ "&lt;script&gt;"
    assert rendered =~ "<h2>Hello</h2>"
    assert rendered =~ "<strong>bold</strong>"
    assert rendered =~ "<code>code</code>"
    assert rendered =~ "&quot;onmouseover=&quot;bad"
    parsed = LazyHTML.from_fragment(rendered)
    assert Enum.count(LazyHTML.query(parsed, "[onmouseover]")) == 0
    assert Enum.count(LazyHTML.query(parsed, "script")) == 0
  end

  test "opaque bounded files survive reload, path traversal fails and images are sniffed" do
    root = Path.join(System.tmp_dir!(), "orion-files-" <> CapabilityStore.id())
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    path = Path.join(root, "source")
    File.write!(path, "<script>dangerous HTML</script>")
    assert {:ok, file} = BotFiles.add(path, "../../danger.html", root: root)
    assert file["name"] == "danger.html"
    assert is_nil(file["image"])
    File.rm!(path)
    assert {:ok, ^file, copy} = BotFiles.get(file["id"], root: root)
    assert File.read!(copy) == "<script>dangerous HTML</script>"
    assert {:error, :invalid_id} = BotFiles.get("../../etc/passwd", root: root)
    File.write!(path, String.duplicate("x", 5_000_001))

    assert {:error, :attachment_must_be_regular_under_5mb} =
             BotFiles.add(path, "large", root: root)
  end
end
