defmodule SeedlingWeb.BotLayouts do
  @moduledoc "Standalone consumer layout, sharing the existing endpoint and LiveSocket."
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <.live_title>{@page_title || "Bots"}</.live_title>
        <script defer src="/assets/phoenix/phoenix.min.js">
        </script>
        <script defer src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <style>
          *{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,sans-serif;color:#292832;background:#fff}button,input,textarea,select{font:inherit}button,a{touch-action:manipulation}button{cursor:pointer;border:0;border-radius:14px;background:#f3f2f7;padding:10px 14px;color:inherit}button:hover{background:#e9e6f5}button:focus-visible,input:focus-visible,textarea:focus-visible,a:focus-visible{outline:3px solid #9f8cdd;outline-offset:2px}a{color:#655396}input,textarea,select{border:1px solid #e5e3eb;border-radius:16px;padding:12px;background:#fff;color:inherit}textarea{resize:vertical;width:100%;min-height:56px;max-height:180px}.bots-app{height:100dvh;display:grid;grid-template-columns:300px minmax(0,1fr)}.bot-sidebar{border-right:1px solid #eeedf2;padding:22px 14px;display:flex;flex-direction:column;gap:16px;overflow:auto;background:#fcfbfe}.sidebar-actions{display:flex;gap:8px;align-items:center}.sidebar-actions h1{font-size:19px;flex:1}.main-bot{display:flex;align-items:center;gap:14px;background:transparent;text-align:left;padding:16px 8px;font-size:20px}.main-bot .bot-face{width:62px;height:62px}.bot-face{width:42px;height:42px;display:inline-flex;flex-direction:column;align-items:center;justify-content:center;flex-shrink:0;background:var(--face-color);color:white;border-radius:45%;font-style:normal;line-height:11px;box-shadow:inset 0 -4px 0 #00000010}.bot-face.small{width:26px;height:26px;font-size:11px;line-height:8px}.bot-face i{font-style:normal}.shape-1{border-radius:15px}.shape-2{border-radius:50% 50% 36% 36%}.thread-row{display:flex;gap:12px;align-items:center;padding:14px 10px;border-radius:18px;text-decoration:none;color:inherit}.thread-row.current{background:#ece8f7}.thread-row:hover{background:#f1eef8}.thread-copy{min-width:0;flex:1}.thread-copy strong,.thread-copy small{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.thread-copy small{color:#898391;margin-top:4px}.faces{display:flex;align-items:center;min-width:42px}.faces .small+.small{margin-left:-8px;border:2px solid white}.human-face{border-radius:50%;width:28px;height:28px;background:#e3e0eb;display:grid;place-items:center;font-size:11px;flex-shrink:0}.sidebar-bottom{margin-top:auto;display:flex;gap:12px;align-items:center;padding-top:16px;color:#8a8195}.bot-pane{display:flex;flex-direction:column;min-width:0;overflow:hidden}.chat-header{display:flex;align-items:center;gap:12px;padding:22px;border-bottom:1px solid #f3f1f6}.participant-pill{display:flex;align-items:center;gap:8px;border-radius:30px;background:#f7f5fb;padding:10px 15px;margin:auto;font-size:14px}.messages{flex:1;overflow:auto;padding:24px max(24px,calc((100% - 800px)/2));scroll-behavior:smooth}.chat-message{display:flex;gap:12px;margin:18px 0;align-items:flex-start}.chat-message.human{justify-content:flex-end}.chat-message.system{text-align:center;justify-content:center;color:#837991;font-size:13px}.message-body{max-width:85%;min-width:0}.message-body>small{color:#968ca3;display:block;margin:3px 0 8px}.bubble{background:#f7f5fb;border-radius:20px;padding:12px 18px;overflow-wrap:anywhere;line-height:1.55}.human .bubble{background:#eee9fa}.bubble p{margin:4px 0}.bubble h2,.bubble h3,.bubble h4{margin:10px 0;font-size:1.15em}.bubble pre{overflow:auto;white-space:pre;background:#edeaf3;padding:12px;border-radius:10px}.bubble code{font-size:13px}.bubble blockquote{border-left:3px solid #c3b7d9;padding-left:12px;margin:10px 0}.attachment{display:block;padding:8px;margin-top:6px}.composer-area{padding:16px max(24px,calc((100% - 800px)/2)) 24px}.composer{border:1px solid #e8e4ef;border-radius:28px;padding:8px;display:flex;gap:8px;align-items:center;box-shadow:0 3px 16px #30224c05}.composer textarea{border:0;border-radius:20px;min-height:54px}.composer button{flex-shrink:0}.muted{color:#958b9e;font-size:13px}.thinking{min-height:24px;color:#8c7aa9;font-size:13px;padding:4px 16px}.compose-to{margin:30px auto;max-width:750px;width:90%}.to-line{display:flex;gap:8px;align-items:center;flex-wrap:wrap;border-bottom:1px solid #ece8f0;padding:16px}.to-line input{border:0;flex:1;min-width:140px}.chip{display:flex;gap:8px;align-items:center;background:#f1edf8;border-radius:24px;padding:5px 10px}.chip button{padding:3px;background:transparent}.recipient-menu{margin:10px 0;background:white;box-shadow:0 6px 30px #39245912;border:1px solid #f2edf6;border-radius:20px;padding:8px;max-height:50vh;overflow:auto}.recipient-menu button{width:100%;display:flex;align-items:center;gap:12px;text-align:left;background:white}.recipient-menu button:hover,.recipient-menu button[data-selected=true]{background:#f6f3fc}.recipient-menu kbd{margin-left:auto;color:#b2a9bc;font-size:12px}.empty-chat{margin:auto;text-align:center;color:#9e94a8;padding:40px}.empty-chat h2{font-size:27px;color:#62576d}.alert{padding:12px 22px;background:#fff5df;color:#785d29}.panel{padding:20px;max-width:760px;margin:20px auto;border-radius:24px;background:#faf8fd}.panel form{display:flex;gap:10px;flex-wrap:wrap}.panel label{display:grid;gap:5px;font-size:13px}.panel h2{margin-top:0}.reply-form{display:flex;gap:8px;margin-top:12px}.reply-form input{flex:1;min-width:0}.request-label{font-size:12px;color:#8b5baa;margin-bottom:5px}.notification-controls{display:flex;gap:10px;align-items:center;flex-wrap:wrap;padding-top:12px;font-size:12px;color:#9c92a4}.notification-controls input[type=number]{width:70px;padding:5px}.mobile-back{display:none}#disconnected{display:none;position:fixed;bottom:0;background:#fff1d0;padding:10px;width:100%;text-align:center}.phx-error #disconnected{display:block}@media(max-width:700px){.bots-app{grid-template-columns:1fr}.bots-app.open .bot-sidebar{display:none}.bots-app:not(.open) .bot-pane{display:none}.mobile-back{display:block}.messages{padding:16px}.composer-area{padding:12px}.chat-header{padding:12px}.message-body{max-width:90%}.bot-sidebar{border:0}}
        </style>
        <script>
          const BotChat = {
            mounted() {
              this.seen = new Set(); this.follow = true;
              this.onScroll = () => { this.follow = this.el.scrollTop + this.el.clientHeight >= this.el.scrollHeight - 70; };
              this.el.addEventListener("scroll", this.onScroll, {passive:true});
              this.handleEvent("bot-notify", data => {
                if (this.seen.has(data.id)) return; this.seen.add(data.id);
                if (document.visibilityState === "hidden" && "Notification" in window && Notification.permission === "granted") {
                  const n = new Notification(data.title, {body:data.body,tag:data.id});
                  n.onclick = () => { window.focus(); window.location.href = "/bots?session=" + encodeURIComponent(data.session); n.close(); };
                }
              });
              this.toBottom();
            },
            updated() { if(this.follow) this.toBottom(); },
            destroyed() { this.el.removeEventListener("scroll",this.onScroll); },
            toBottom() { requestAnimationFrame(() => { this.el.scrollTop=this.el.scrollHeight; }); }
          };
          const BotRecipients = {
            mounted() {
              this.index=-1;
              this.keydown = e => {
                const buttons = Array.from(document.querySelectorAll("#recipient-menu button[data-recipient]"));
                if (!buttons.length) return;
                if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); this.index=this.index<0?(e.key==="ArrowDown"?0:buttons.length-1):(this.index+(e.key==="ArrowDown"?1:-1)+buttons.length)%buttons.length; buttons[this.index].focus(); }
                if (e.key === "Enter" && (e.target.id === "recipient-query" || e.target.hasAttribute("data-recipient"))) { e.preventDefault(); buttons[Math.max(this.index,0)].click(); }
                if ((e.metaKey || e.ctrlKey) && /^[1-9]$/.test(e.key)) { e.preventDefault(); const b=buttons[Number(e.key)-1]; if(b) b.click(); }
              };
              this.el.addEventListener("keydown",this.keydown);
            },
            destroyed() { this.el.removeEventListener("keydown",this.keydown); }
          };
          window.addEventListener("DOMContentLoaded", () => {
            window.liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {params:{_csrf_token:document.querySelector("meta[name='csrf-token']").content},hooks:{BotChat,BotRecipients}});
            window.liveSocket.disableDebug(); window.liveSocket.connect();
            document.addEventListener("click", e => {
              if(e.target.closest("#allow-notifications")) {
                if("Notification" in window) Notification.requestPermission().then(p => { const el=document.getElementById("notification-permission"); if(el) el.textContent="Browser notifications: "+p; });
              }
            });
          });
        </script>
      </head>
      <body>
        {@inner_content}
        <div id="disconnected" role="alert">Reconnecting — your conversation is saved.</div>
      </body>
    </html>
    """
  end
end
