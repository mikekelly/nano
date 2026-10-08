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

  test "file composition loads nested partials without a delegation report contract" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "prompt-compose-#{Base.encode16(:crypto.strong_rand_bytes(10))}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    facts = Path.join(dir, "facts.txt")
    File.write!(facts, "Node {{node}}; process {{pid}}")
    File.write!(Path.join(dir, "role.md"), "{{! lean role }}{{>nested}}")
    File.write!(Path.join(dir, "nested.md"), "Bot: {{identity}}")

    assert {:ok, r} =
             Prompts.compose(["role"], %{"identity" => "Helper"},
               facts_file: facts,
               prompt_root: dir
             )

    assert r.text == "Node {{node}}; process {{pid}}\nBot: Helper"
    refute r.text =~ "report"

    assert {:error, %{reason: :prompt_too_large}} =
             Prompts.compose(["role"], %{"identity" => "Helper"},
               facts_file: facts,
               prompt_root: dir,
               max_bytes: 5
             )

    assert {:error, %{reason: :invalid_options}} = Prompts.compose(["../unsafe"], %{})
  end

  test "composition supports injected flavours and rejects missing variables" do
    assert {:ok, r} = Prompts.compose(["bot"], %{}, partials: %{"bot" => "Only this identity."})
    assert r.text =~ "Only this identity."
    assert r.text =~ "You are process {{pid}}"
    refute r.text =~ "Seedling.Delegation.report"

    assert {:error, %{reason: :missing_variable}} =
             Prompts.compose(["bot"], %{}, partials: %{"bot" => "{{unknown}}"})

    assert {:error, %{reason: :partial_cycle}} =
             Prompts.compose(["bot"], %{}, partials: %{"bot" => "{{>bot}}"})
  end
end
