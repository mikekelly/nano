defmodule Seedling.PromptsTest do
  use ExUnit.Case, async: true
  alias Seedling.Prompts

  test "partials, comments, non-recursive raw data and explicit harness placeholders" do
    assert {:ok, r} =
             Prompts.render("{{! remove me }}{{>a}} {{pid}}", %{"job" => "{{!literal}} & <data>"},
               partials: %{"a" => "{{>b}}", "b" => "{{job}}"},
               preserve: ["pid"]
             )

    assert r.text == "{{!literal}} & <data> {{pid}}"
    assert r.bytes == byte_size(r.text)
  end

  test "strict errors, cycles and output caps" do
    assert {:error, %{reason: :missing_variable}} = Prompts.render("{{absent}}")
    assert {:error, %{reason: :missing_partial}} = Prompts.render("{{>absent}}")

    assert {:error, %{reason: :partial_cycle}} =
             Prompts.render("{{>a}}", %{}, partials: %{"a" => "{{>a}}"})

    assert {:error, %{reason: :syntax}} = Prompts.render("{{#section}}")
    assert {:error, %{reason: :syntax}} = Prompts.render("{{broken")
    assert {:error, %{reason: :prompt_too_large}} = Prompts.render("12345", %{}, max_bytes: 4)
    assert {:error, %{reason: :invalid_options}} = Prompts.render(nil)
  end
end
