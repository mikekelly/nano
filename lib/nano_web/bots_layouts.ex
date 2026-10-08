defmodule NanoWeb.BotsLayouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><meta
          name="csrf-token"
          content={Plug.CSRFProtection.get_csrf_token()}
        /><title>Bots · Your companions</title>
        <script defer src="/assets/phoenix/phoenix.min.js">
        </script><script defer src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script>
          addEventListener("DOMContentLoaded",()=>{
            const Chat = {
              mounted(){
                this.last = 0;
                this.handleEvent("bot-notify",e=>{
                  const interval=Number(localStorage.getItem("bot-notification-interval")||300000);
                  if(document.visibilityState==="visible"||localStorage.getItem("bot-notifications")!=="on"||!("Notification" in window)||Notification.permission!=="granted"||Date.now()-this.last<interval)return;
                  this.last=Date.now(); const n=new Notification(e.title,{body:"A companion has an update for you.",tag:"bot-chat"});n.onclick=()=>{window.focus();n.close()};
                });
                this.el.addEventListener("click",async e=>{
                  if(e.target.id==="bot-notifications"){
                    if(!("Notification" in window)){e.target.textContent="Notifications unavailable";return}
                    const enabled=localStorage.getItem("bot-notifications")==="on";
                    if(enabled){localStorage.setItem("bot-notifications","off");e.target.textContent="Enable notifications";return}
                    const p=await Notification.requestPermission();localStorage.setItem("bot-notifications",p==="granted"?"on":"off");e.target.textContent=p==="granted"?"Mute notifications":"Notifications blocked";
                  }
                });
                this.el.addEventListener("change",e=>{if(e.target.id==="notification-rate")localStorage.setItem("bot-notification-interval",e.target.value)});
                this.el.addEventListener("keydown",e=>{
                  if((e.metaKey||e.ctrlKey)&&e.key==="n"){e.preventDefault();this.pushEvent("new",{})}
                  if((e.metaKey||e.ctrlKey)&&/^[1-9]$/.test(e.key)){const b=this.el.querySelectorAll("[data-bot-choice]")[Number(e.key)-1];if(b){e.preventDefault();b.click()}}
                  if(e.key==="ArrowDown"||e.key==="ArrowUp"){
                    const choices=[...this.el.querySelectorAll("[data-bot-choice]")];const at=choices.indexOf(document.activeElement);if(choices.length && (at>=0||document.activeElement.name==="q")){e.preventDefault();choices[(at+(e.key==="ArrowDown"?1:-1)+choices.length)%choices.length].focus()}
                  }
                  if(e.key==="Enter"&&!e.shiftKey&&e.target.tagName==="TEXTAREA"){e.preventDefault();e.target.form.requestSubmit()}
                });
                this.handleEvent("clear-composer",()=>{const t=this.el.querySelector("textarea");if(t){t.value="";t.focus()}});
              }
            };
            const csrf=document.querySelector("meta[name='csrf-token']").content;
            window.liveSocket=new LiveView.LiveSocket("/live",Phoenix.Socket,{params:{_csrf_token:csrf},hooks:{Chat}});window.liveSocket.connect();
          });
        </script>
      </head><body>{@inner_content}</body>
    </html>
    """
  end
end
