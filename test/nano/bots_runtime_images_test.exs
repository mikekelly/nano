defmodule Nano.Bots.RuntimeImagesTest do
  use ExUnit.Case, async: false
  alias Nano.FakeOpenRouter, as: Fake
  alias Nano.Bots

  defmodule Adapter do
    def ensure(bot, _, _), do: {:ok, bot.voice}
    defdelegate deliver(name, batch), to: Nano.Bots.Agent
    defdelegate notify(name, message), to: Nano.Bots.Agent
    defdelegate status(name), to: Nano.Bots.Agent
  end

  setup do
    Fake.start()

    dir =
      Path.join(
        Application.fetch_env!(:nano, :test_dir),
        "runtime-images-#{System.unique_integer([:positive])}"
      )

    previous = Application.get_env(:nano, :image_dir)
    Application.put_env(:nano, :image_dir, Path.join(dir, "images"))

    bytes =
      <<"GIF89a", 1::little-16, 1::little-16, 0, 0, 0, 44, 0::little-16, 0::little-16,
        1::little-16, 1::little-16, 0, 2, 2, 68, 1, 0, 59>>

    {:ok, image} = Nano.Images.import_bytes(bytes)
    model = Fake.model(%{"architecture" => %{"input_modalities" => ["text", "image"]}})
    name = "runtime-vision-test-#{System.unique_integer([:positive])}"
    Fake.listen(model)
    {:ok, _} = NanoAgent.start([name: name] ++ Fake.opts(model, max_context: 60_000))

    store =
      start_supervised!({Nano.Bots.Store, name: nil, store_dir: dir <> "/store", pubsub: nil})

    {:ok, bot} = Bots.create_bot(%{name: "Vision", voice: name}, server: store)
    {:ok, session} = Bots.create_session(%{participant_ids: [bot.id]}, server: store)

    runtime =
      start_supervised!(
        {Nano.Bots.Runtime,
         name: nil,
         state_dir: dir <> "/runtime",
         store: store,
         adapter: Adapter,
         pubsub: nil,
         retry_ms: 60_000,
         router_opts: [evaluate: fn _, _, _ -> {:error, :no_key} end]}
      )

    on_exit(fn ->
      if pid = NanoAgent.whereis(name) do
        DynamicSupervisor.terminate_child(Nano.AgentSupervisor, pid)
        NanoAgent.kill_tasks(pid)
      end

      Nano.StateStore.delete(name)

      if previous,
        do: Application.put_env(:nano, :image_dir, previous),
        else: Application.delete_env(:nano, :image_dir)

      File.rm_rf(dir)
    end)

    %{
      image: image,
      bytes: bytes,
      model: model,
      name: name,
      store: store,
      runtime: runtime,
      session: session,
      bot: bot
    }
  end

  test "consumer persisted upload reaches actual provider vision atomically, normal answers do not publish",
       c do
    Fake.push(c.model, text: "operator-only answer")

    {:ok, message} =
      Bots.post_human(
        c.session.id,
        %{
          text: "What is this image?",
          attachments: ["image:" <> c.image.image_ref],
          idempotency_key: "uploaded"
        },
        server: c.store
      )

    Nano.Bots.Runtime.reconcile(server: c.runtime)
    assert_receive {:openrouter_request, model, body}, 3000
    assert model == c.model
    content = List.last(body["messages"])["content"]
    assert [text, image] = content
    assert text["text"] =~ "What is this image?"
    assert text["text"] =~ message.id
    assert text["text"] =~ "image_bindings"
    assert image["image_url"]["url"] == "data:image/gif;base64," <> Base.encode64(c.bytes)
    wait_idle(c.name, 200)
    {:ok, page} = Bots.list_messages(c.session.id, server: c.store)
    assert page.messages == [message]
  end

  test "runtime upload remains one attributed image across repeated compaction", c do
    Fake.push(c.model,
      calls: [eval: ~S|Compaction.provide_summary("Goal: retain consumer image attribution")|]
    )

    Fake.push(c.model, calls: [eval: ~S|Compaction.provide_summary("Goal: retain twice")|])
    Fake.push(c.model, text: "operator only")

    {:ok, message} =
      Bots.post_human(
        c.session.id,
        %{
          text: "consumer image brief",
          attachments: ["image:" <> c.image.image_ref],
          idempotency_key: "compacted"
        }, server: c.store)

    Nano.Bots.Runtime.reconcile(server: c.runtime)

    for _ <- 1..3 do
      assert_receive {:openrouter_request, model, body}, 3000
      assert model == c.model

      images =
        for %{"content" => parts} <- body["messages"],
            is_list(parts),
            %{"type" => "image_url"} = image <- parts,
            do: image

      assert length(images) == 1
      assert Jason.encode!(body) =~ message.id
    end

    wait_idle(c.name, 200)
    assert NanoAgent.info(c.name).halted == nil
    assert {:ok, %{messages: [^message]}} = Bots.list_messages(c.session.id, server: c.store)
  end

  defp wait_idle(name, remaining) do
    case NanoAgent.info(name) do
      %{status: :idle} ->
        :ok

      _ when remaining > 0 ->
        Process.sleep(10)
        wait_idle(name, remaining - 1)

      _ ->
        flunk("fake agent did not become idle")
    end
  end

  test "image event canonicalizes, deduplicates, rejects missing refs and avoids chunk reattachment",
       c do
    message = %{
      id: "m",
      sequence: 1,
      text: "image",
      attachments: [
        "image:" <> c.image.image_ref,
        "image:" <> c.image.image_ref,
        "image:" <> String.duplicate("0", 64)
      ]
    }

    event = Nano.Bots.Agent.event(%{messages: [message], delivery_id: "d"})
    assert event.images == [c.image]
    assert event.bots_turn.unavailable_images == [String.duplicate("0", 64)]
    continuation = Nano.Bots.Agent.event(%{messages: [Map.put(message, :text_offset, 3000)]})
    refute Map.has_key?(continuation, :images)
    {clean, refs, notice} = Nano.ImageInput.event(event, ["text", "image"])
    assert refs == [c.image]
    assert clean.bots_turn.image_bindings != []
    assert notice == ""
    text_only = Nano.ImageInput.event(event, ["text"])
    assert elem(text_only, 2) =~ "cannot see"
  end
end
