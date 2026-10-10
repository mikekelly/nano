defmodule Nano.MCP.ToolHeadersTest do
  use ExUnit.Case, async: true
  alias Nano.MCP.ToolHeaders
  defp schema(properties), do: %{"type" => "object", "properties" => properties}
  defp field(name, type \\ "string"), do: %{"type" => type, "x-mcp-header" => name}

  test "primitive values and nested properties use lowercase headers and exact paths" do
    s =
      schema(%{
        "region" => field("Region"),
        "nested" =>
          schema(%{
            "count" => field("Count", "integer"),
            "enabled" => field("Enabled", "boolean")
          })
      })

    assert {:ok,
            %{
              "mcp-param-region" => "west",
              "mcp-param-count" => "-42",
              "mcp-param-enabled" => "false"
            }} =
             ToolHeaders.extract(s, %{
               "region" => "west",
               "nested" => %{"count" => -42, "enabled" => false}
             })

    assert {:ok, %{}} = ToolHeaders.extract(s, %{"region" => nil, "count" => 10})
  end

  test "encoding handles unicode, whitespace, control characters and sentinel ambiguity" do
    for value <- ["Hello, 世界", " padded ", "line\nbreak", "=?base64?literal?="] do
      assert {:ok, %{"mcp-param-value" => encoded}} =
               ToolHeaders.extract(schema(%{"v" => field("Value")}), %{"v" => value})

      assert encoded == "=?base64?" <> Base.encode64(value) <> "?="
    end
  end

  test "invalid names, duplicates and types reject even absent argument values" do
    for name <- ["", "bad name", "a\r\nb", "世界", 1, nil] do
      assert {:error, {:invalid_header_name, _}} =
               ToolHeaders.extract(schema(%{"v" => field(name)}), %{})
    end

    assert {:error, {:duplicate_header_name, "region"}} =
             ToolHeaders.extract(schema(%{"a" => field("Region"), "b" => field("REGION")}), %{})

    for type <- ["number", "object", "array", ["string", "null"], nil] do
      assert {:error, {:invalid_header_type, _}} =
               ToolHeaders.extract(schema(%{"v" => field("V", type)}), %{})
    end
  end

  test "annotations under items, composition, conditionals, definitions and refs are forbidden" do
    for key <- [
          "items",
          "additionalProperties",
          "oneOf",
          "anyOf",
          "allOf",
          "not",
          "if",
          "then",
          "else",
          "$defs",
          "$ref"
        ] do
      for nested <- [
            field("X"),
            schema(%{"deep" => field("X")}),
            [schema(%{"deep" => field("X")})]
          ] do
        assert {:error, {:unreachable_header_annotation, _}} =
                 ToolHeaders.extract(Map.put(schema(%{}), key, nested), %{})
      end
    end

    assert {:error, {:unreachable_header_annotation, []}} =
             ToolHeaders.extract(field("Root"), %{})

    assert {:error, {:unreachable_header_annotation, _}} =
             ToolHeaders.extract(schema(%{"x" => Map.put(field("X"), "$ref", "#/$defs/x")}), %{})
  end

  test "argument types and safe integer bounds are enforced without leaking values" do
    s = schema(%{"v" => field("V", "integer")})

    for value <- [9_007_199_254_740_992, -9_007_199_254_740_992, 42.0, "secret-value", %{}] do
      assert {:error, {:invalid_header_argument, ["v"]}} = ToolHeaders.extract(s, %{"v" => value})
    end

    for value <- [-9_007_199_254_740_991, 9_007_199_254_740_991] do
      assert {:ok, %{"mcp-param-v" => _}} = ToolHeaders.extract(s, %{"v" => value})
    end

    assert {:error, :invalid_schema_or_arguments} = ToolHeaders.extract(nil, %{})
    deep = Enum.reduce(1..70, field("V"), fn _, s -> schema(%{"x" => s}) end)
    assert {:error, :schema_too_large} = ToolHeaders.extract(deep, %{})
  end
end
