defmodule NanoWeb.AgentGoalsTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NanoWeb.Endpoint

  test "bob, drift and experiment toggle log entries are visible in the reading timeline" do
    Nano.FakeOpenRouter.start()
    model = Nano.FakeOpenRouter.model()
    Nano.FakeOpenRouter.listen(model)
    name = "bob-ui-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    {:ok, _} = Nano.Ops.start_agent(name, Nano.FakeOpenRouter.opts(model, start_idle: true))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    agent = Nano.Ops.agent(name)

    Nano.Log.write(agent, :context_bob, %{
      text: "Agent's own note",
      distance_tokens: 4_001,
      reason: "distance"
    })

    Nano.Log.write(agent, :drift_judgement, %{probability: 0.9, model: "fake-jev", status: "ok"})
    Nano.Log.write(agent, :bobbing_config, %{config: %{bobbing: false, drift: false}})
    {:ok, view, _} = live(build_conn(), "/agents/#{name}")
    assert has_element?(view, "#timeline", "Agent's own note")
    assert has_element?(view, "#timeline", "distance_tokens")
    assert has_element?(view, "#timeline", "4001")
    assert has_element?(view, "#timeline", "probability")
    assert has_element?(view, "#timeline", "fake-jev")
    assert has_element?(view, "#timeline", "bobbing config")
  end

  test "event, paired eval result and orphan tool result attachments render in both timeline modes" do
    Nano.FakeOpenRouter.start()
    model = Nano.FakeOpenRouter.model()
    Nano.FakeOpenRouter.listen(model)
    name = "image-timeline-" <> Base.encode16(:crypto.strong_rand_bytes(8))
    {:ok, _} = Nano.Ops.start_agent(name, Nano.FakeOpenRouter.opts(model, start_idle: true))
    on_exit(fn -> Nano.Ops.stop_agent(name) end)
    agent = Nano.Ops.agent(name)
    ref = %{"id" => String.duplicate("a", 64), "width" => 1, "height" => 1}

    Nano.Log.write(agent, :event_received, %{
      message: "image",
      event_seq: 1,
      images: [ref],
      image_notice: "Event image omitted from model"
    })

    Nano.Log.write(agent, :tool_call, %{
      call_id: "paired",
      call_seq: 1,
      name: "eval",
      arguments: %{code: "image"}
    })

    Nano.Log.write(agent, :tool_result, %{
      call_id: "paired",
      ok: true,
      result: "image result",
      images: [ref],
      image_notice: "Paired image omitted from model"
    })

    Nano.Log.write(agent, :tool_result, %{
      call_id: "orphan",
      ok: true,
      result: "orphan image",
      images: [ref],
      image_notice: "Orphan image omitted from model"
    })

    for suffix <- ["", "?view=debug"] do
      {:ok, view, _} = live(build_conn(), "/agents/#{name}" <> suffix)
      assert has_element?(view, "#timeline img[src='/api/images/#{ref["id"]}']")
      html = view |> element("#timeline") |> render()
      assert length(String.split(html, "alt=\"Attached image\"")) - 1 == 3

      for notice <- [
            "Event image omitted from model",
            "Paired image omitted from model",
            "Orphan image omitted from model"
          ],
          do: assert(has_element?(view, "#timeline", notice))
    end
  end

  test "agent page shows open goals and why and refreshes status" do
    name = "goals-ui-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    {:ok, goal} =
      Seedling.Goals.create(name, title: "Visible goal", why: "Operator can understand")

    Seedling.Goals.focus(name, goal["id"])
    {:ok, view, html} = live(build_conn(), "/agents/#{name}")
    assert html =~ "Visible goal"
    assert has_element?(view, "#agent-goals", "Why: Operator can understand")
    assert has_element?(view, "#agent-goals", "current")
    Seedling.Goals.set_status(name, goal["id"], :done)
    send(view.pid, :refresh)
    assert render(view) =~ "No open goals."
    refute has_element?(view, "#agent-goals li")
  end
end
