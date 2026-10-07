defmodule NanoWeb.BotsLayout do
  @moduledoc "Standalone consumer styling/client hooks on the same Phoenix endpoint."
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html><html lang="en">
      <head>
        <meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} /><title>Bots</title>
        <script defer src="/assets/phoenix/phoenix.min.js">
        </script><script defer src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <style>
          *{box-sizing:border-box}body{margin:0;font:16px system-ui;color:#283038;background:#fff}button,input{font:inherit}button{cursor:pointer;border:0;border-radius:18px;padding:10px 16px;background:#f3f5f7;color:inherit}button:focus-visible,input:focus-visible{outline:3px solid #8db8e7}button:disabled{opacity:.5}input{border:1px solid #e0e4e8;border-radius:20px;padding:14px;min-width:0}.bot-app{display:grid;grid-template-columns:300px 1fr;height:100dvh}aside{padding:24px;border-right:1px solid #e8ebef;display:flex;flex-direction:column;overflow:auto}header{display:flex;align-items:center;justify-content:space-between;padding:16px}nav{flex:1}nav button{display:block;text-align:left;width:100%;margin:8px 0;background:white}nav small{display:block;overflow:hidden;white-space:nowrap;text-overflow:ellipsis;color:#7b838c}nav .selected{background:#edf3fb}.main-bot{text-align:center;padding:24px 0}.main-bot p{font-size:13px;color:#7b838c}.face{display:inline-grid;place-items:center;width:80px;height:80px;border-radius:35%;font-size:28px}.mini-face{display:inline-grid;place-items:center;width:32px;height:32px;border-radius:45%;font-size:12px;margin-right:5px}footer small{display:block;font-size:12px;color:#7b838c}main{padding:28px;display:flex;flex-direction:column;gap:15px;overflow:hidden}.participants{border-radius:24px;background:#f6f7f9;align-self:center}.messages{flex:1;overflow:auto;padding:20px}.messages article{max-width:85%;margin:15px 0;padding:14px 20px;border-radius:24px;background:#f2f4f6}.messages article.human{margin-left:auto;background:#eaf2ff}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;margin:8px 0}.composer{display:flex;gap:10px}.composer input{flex:1}.choices{display:flex;flex-direction:column;gap:8px;box-shadow:0 6px 24px #0001;border-radius:20px;padding:12px;overflow:auto}.to-line{display:flex;gap:8px;align-items:center}.status{color:#7b838c;font-size:14px}@media(max-width:700px){.bot-app{grid-template-columns:110px 1fr}aside{padding:8px}.main-bot{display:none}main{padding:12px}nav strong{font-size:12px}.messages{padding:0}.messages article{max-width:100%}}
        </style>
        <script>
          window.addEventListener('DOMContentLoaded', () => {
            const csrf = document.querySelector("meta[name='csrf-token']").content;
            window.liveSocket = new LiveView.LiveSocket('/live', Phoenix.Socket, {params:{_csrf_token:csrf}});
            window.liveSocket.connect();
            window.addEventListener('phx:bot-permission', () => {if ('Notification' in window && Notification.permission === 'default') Notification.requestPermission()});
            window.addEventListener('phx:bot-notification', e => {if (document.hidden && 'Notification' in window && Notification.permission === 'granted') {const n = new Notification('Bots', {body:e.detail.text});n.onclick=()=>{window.focus();n.close()}}});
            document.addEventListener('submit', e => {if(e.target.classList.contains('composer')) setTimeout(()=>{const input=e.target.querySelector('input[name=text]');if(input)input.value=''},150)});
            document.addEventListener('keydown', e => {const choices=[...document.querySelectorAll('.choices button')];const i=choices.indexOf(document.activeElement);if(e.key==='ArrowDown'&&choices.length){e.preventDefault();choices[(i+1)%choices.length].focus()}if(e.key==='ArrowUp'&&choices.length){e.preventDefault();choices[(i+choices.length-1)%choices.length].focus()}if((e.metaKey||e.ctrlKey)&&/^[1-9]$/.test(e.key)){const b=choices[Number(e.key)-1];if(b){e.preventDefault();b.click()}}});
          });
        </script>
      </head><body>{@inner_content}</body>
    </html>
    """
  end
end
