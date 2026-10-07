defmodule Vega.GoalsViewTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  test "summary shows status, why, relation and omission, safely escaped" do
    review =
      {:ok,
       %{
         goals: [
           %{
             "title" => "<script>ship</script>",
             "status" => "blocked",
             "why" => "Safety & evidence",
             "parent_id" => "root"
           }
         ],
         omitted: 2
       }}

    html = render_component(&Vega.GoalsView.panel/1, review: review)
    assert html =~ "&lt;script&gt;ship&lt;/script&gt;"
    assert html =~ "blocked"
    assert html =~ "Why: Safety &amp; evidence"
    assert html =~ "step of root"
    assert html =~ "2 more open goals"
  end

  test "empty and storage-error summaries are graceful" do
    assert render_component(&Vega.GoalsView.panel/1, review: {:ok, %{goals: [], omitted: 0}}) =~
             "No open goals"

    assert render_component(&Vega.GoalsView.panel/1, review: {:error, :corrupt_store}) =~
             "Goals unavailable"
  end
end
