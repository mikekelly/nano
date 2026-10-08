defmodule SeedlingWeb.BotBrowserTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  @lightpanda System.find_executable("lightpanda")
  if !@lightpanda, do: @moduletag(skip: "Lightpanda is not installed")

  test "actual browser JS recipient arrows, Enter, shortcuts and notification permission/dedup" do
    fixture = ~S"""
    <div id="recipients"><input id="recipient-query"><div id="recipient-menu"><button data-recipient="1">Muse</button><button data-recipient="2">Dots</button></div></div>
    <button id="allow-notifications">Allow</button><span id="notification-permission"></span><div id="chat-messages"></div><p id="result">PENDING</p>
    <script>
      window.addEventListener("DOMContentLoaded",()=>{
        try {
          const answers=[];let selected=null;let permissionRequests=0;let notices=0;let notify;
          const buttons=Array.from(document.querySelectorAll("[data-recipient]"));
          buttons.forEach(b=>b.addEventListener("click",()=>selected=b.dataset.recipient));
          const root=document.getElementById("recipients");const input=document.getElementById("recipient-query");
          BotRecipients.mounted.call({el:root});
          input.dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowDown",bubbles:true}));
          answers.push(document.activeElement===buttons[0]);
          input.dispatchEvent(new KeyboardEvent("keydown",{key:"Enter",bubbles:true,cancelable:true}));answers.push(selected==="1");
          input.dispatchEvent(new KeyboardEvent("keydown",{key:"2",ctrlKey:true,bubbles:true,cancelable:true}));answers.push(selected==="2");
          input.dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowDown",bubbles:true}));answers.push(document.activeElement===buttons[1]);
          input.dispatchEvent(new KeyboardEvent("keydown",{key:"ArrowUp",bubbles:true}));answers.push(document.activeElement===buttons[0]);
          class TestNotification {static permission="granted";static requestPermission(){permissionRequests++;return Promise.resolve("granted")}constructor(title,options){notices++;this.title=title;this.options=options}close(){}}
          Object.defineProperty(window,"Notification",{value:TestNotification,configurable:true});
          let hidden=true;Object.defineProperty(document,"visibilityState",{get:()=>hidden?"hidden":"visible",configurable:true});
          const chat={el:document.getElementById("chat-messages"),handleEvent:(event,fn)=>notify=fn,toBottom:()=>{}};
          BotChat.mounted.call(chat);
          document.getElementById("allow-notifications").click();answers.push(permissionRequests===1);
          notify({id:"a",title:"Muse",body:"Need a choice",session:"safe"});notify({id:"a",title:"Muse",body:"Duplicate",session:"safe"});answers.push(notices===1);
          hidden=false;notify({id:"b",title:"Dots",body:"Foreground",session:"safe"});answers.push(notices===1);
          document.getElementById("result").textContent=answers.every(Boolean)?"BOT_BROWSER_PASS":"BOT_BROWSER_FAIL "+JSON.stringify(answers);
        } catch(e){document.getElementById("result").textContent="BOT_BROWSER_ERROR "+String(e);}
      });
    </script>
    """

    html =
      render_component(&SeedlingWeb.BotLayouts.root/1, %{
        page_title: "Browser test",
        inner_content: Phoenix.HTML.raw(fixture)
      })

    server =
      start_supervised!(
        {Bandit,
         plug: {Seedling.Bots.BrowserFixture, html}, ip: :loopback, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    dir =
      Path.join(System.tmp_dir!(), "bots-browser-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, result} =
      Seedling.Shell.sh("#{@lightpanda} fetch --dump markdown http://127.0.0.1:#{port}/",
        timeout: 15000,
        spool_dir: dir,
        max_bytes: 8000
      )

    assert result.exit_code == 0, result.output
    assert String.replace(result.output, "\\_", "_") =~ "BOT_BROWSER_PASS", result.output
  end
end
