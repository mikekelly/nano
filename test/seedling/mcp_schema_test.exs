defmodule Seedling.MCPSchemaTest do
  use ExUnit.Case, async: true
  alias Seedling.MCP.{Schema, HTTP, Result}

  test "nested static annotations, safe integers, omitted nulls and invalid schemas" do
    schema = %{
      "properties" => %{
        "nested" => %{
          "properties" => %{"value" => %{"type" => "integer", "x-mcp-header" => "Tenant"}}
        }
      }
    }

    assert {:ok, %{"mcp-param-tenant" => "42"}} =
             Schema.headers(schema, %{"nested" => %{"value" => 42}})

    assert {:ok, %{}} = Schema.headers(schema, %{})

    assert {:error, :invalid_header_integer} =
             Schema.headers(schema, %{"nested" => %{"value" => 9_007_199_254_740_992}})

    assert {:error, :invalid_header_annotation} =
             Schema.annotations(%{"items" => %{"type" => "string", "x-mcp-header" => "Bad"}})

    assert {:error, :invalid_header_annotation} =
             Schema.annotations(%{
               "properties" => %{"x" => %{"type" => "number", "x-mcp-header" => "Bad"}}
             })

    dup = %{
      "properties" => %{
        "x" => %{"type" => "string", "x-mcp-header" => "Tenant"},
        "y" => %{"type" => "string", "x-mcp-header" => "tenant"}
      }
    }

    assert {:error, :duplicate_header_annotation} = Schema.annotations(dup)
    assert HTTP.header_value("safe") == "safe"
    assert HTTP.header_value(" padded ") == "=?base64?IHBhZGRlZCA=?="
    assert HTTP.header_value("=?base64?literal?=") == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?="
  end

  test "paged UTF-8 JSON preserves boundaries" do
    dir =
      Path.join(System.tmp_dir!(), "mcp-result-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, %{path: path}} =
             Result.bound(%{"text" => String.duplicate("世界", 1000)}, 256, dir)

    assert {:ok, %{text: text, next_offset: offset}} = Result.page(path, limit: 19)
    assert String.valid?(text)
    assert {:ok, %{text: next}} = Result.page(path, offset: offset, limit: 17)
    assert String.valid?(next)
    emoji = Path.join(dir, "emoji.json")
    File.write!(emoji, Jason.encode!("😀"))
    assert {:error, :unaligned_utf8_offset} = Result.page(emoji, offset: 2, limit: 8)
    assert {:ok, %{text: "😀", next_offset: 5}} = Result.page(emoji, offset: 1, limit: 1)
  end
end
