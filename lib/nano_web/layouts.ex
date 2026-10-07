defmodule NanoWeb.Layouts do
  @moduledoc """
  The root HTML layout: stylesheet, Phoenix client JS, the LiveSocket connection, and a banner
  that app.css shows while the page has lost its connection to the node.
  """
  use Phoenix.Component

  @doc "The document around every LiveView."
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <.live_title>{assigns[:page_title] || "nano"}</.live_title>
        <link rel="stylesheet" href="/app.css" />
        <script defer src="/assets/phoenix/phoenix.min.js">
        </script>
        <script defer src="/assets/phoenix_live_view/phoenix_live_view.min.js">
        </script>
        <script>
          // Follow (on an agent's timeline): while the reader is at the bottom of the page, keep
          // it there as content grows; once they scroll up, nothing moves under them and #jump
          // offers a way back. Reaching the bottom again, by hand or by #jump, resumes following.
          const Follow = {
            mounted() {
              this.jump = document.getElementById("jump")
              this.view = this.el.dataset.view
              // Only an upward scroll detaches: our own scrollTo lands after more content may have
              // arrived, so "not at the bottom" alone would read as the reader leaving.
              this.lastY = scrollY
              this.onScroll = () => {
                if (innerHeight + scrollY >= document.documentElement.scrollHeight - 40) this.follow(true)
                else if (scrollY < this.lastY) this.follow(false)
                this.lastY = scrollY
              }
              this.jump.onclick = () => { this.follow(true); this.toBottom() }
              addEventListener("scroll", this.onScroll, {passive: true})
              // Any growth (entries, results, an opened <details>, the header) re-pins a follower.
              this.resized = new ResizeObserver(() => this.following && this.toBottom())
              this.resized.observe(document.body)
              // A new entry while detached changes the button's wording.
              this.added = new MutationObserver(() => this.following || (this.jump.textContent = "new activity ↓"))
              this.added.observe(this.el, {childList: true})
              this.follow(true)
              this.toBottom()
            },
            updated() {
              // A switch between reading and debug views starts again at the bottom.
              if (this.el.dataset.view !== this.view) { this.view = this.el.dataset.view; this.follow(true); this.toBottom() }
            },
            destroyed() { removeEventListener("scroll", this.onScroll); this.resized.disconnect(); this.added.disconnect() },
            toBottom() { scrollTo(0, document.documentElement.scrollHeight) },
            follow(on) {
              if (on === this.following) return
              this.following = on
              this.jump.hidden = on
              this.jump.textContent = "jump to latest ↓"
            }
          }

          // InboxSeen (on the inbox menu): counts messages newer than the newest one this viewer
          // had when they last opened the menu; kept in localStorage, which may be unavailable.
          const InboxSeen = {
            mounted() {
              this.seen = () => { try { return localStorage.getItem("nano:inbox-seen") || "" } catch { return "" } }
              this.count = () => {
                const ats = [...this.el.querySelectorAll("li[data-at]")].map(li => li.dataset.at)
                if (this.el.open && ats.length) { try { localStorage.setItem("nano:inbox-seen", ats.sort().pop()) } catch {} }
                const fresh = ats.filter(at => at > this.seen()).length
                const badge = document.getElementById("inbox-new")
                badge.hidden = fresh === 0
                // Only on change: the badge is inside what the observer below watches.
                if (badge.textContent !== `${fresh} new`) badge.textContent = `${fresh} new`
              }
              this.el.addEventListener("toggle", this.count)
              new MutationObserver(this.count).observe(this.el, {childList: true, subtree: true})
              this.count()
            }
          }

          // Explicit opt-in only; no history replay or background delivery.
          const BotNotifications = {
            mounted() {
              this.status = text => { const el = document.getElementById("bot-notification-status"); if (el) el.textContent = text }
              this.click = async e => {
                const button = e.target.closest("[data-bot-notifications]")
                if (!button || !this.el.contains(button)) return
                if (button.dataset.botNotifications === "disable") { this.pushEvent("notifications", {enabled: false, session_id: button.dataset.sessionId}); return }
                if (!("Notification" in window) || !window.isSecureContext) { this.status("Notifications unavailable: use a supported browser over HTTPS or localhost."); return }
                try {
                  const permission = await Notification.requestPermission()
                  if (permission === "granted") { this.pushEvent("notifications", {enabled: true, session_id: button.dataset.sessionId}); this.status("Permission granted. Notifications enabled for this conversation.") }
                  else this.status("Permission not granted. Change browser site permissions to enable notifications.")
                } catch { this.status("Browser notification permission failed.") }
              }
              this.el.addEventListener("click", this.click)
              this.handleEvent("bot-notification", data => {
                if (!("Notification" in window) || Notification.permission !== "granted") return
                if (document.visibilityState === "visible" && document.hasFocus()) return
                try {
                  const notification = new Notification(data.title, {body: data.body, tag: "nano-bot-" + data.id})
                  notification.onclick = () => { window.focus(); this.pushEvent("select", {id: data.session_id}); notification.close() }
                } catch { this.status("This browser could not display a notification.") }
              })
            },
            destroyed() { this.el.removeEventListener("click", this.click) }
          }

          // Dropdowns (<details class="dropdown">) close on a click outside them, on Escape, or
          // when the server says so (a message sent from one).
          window.addEventListener("phx:close", e => { const d = document.getElementById(e.detail.id); if (d) d.open = false })
          document.addEventListener("click", e =>
            document.querySelectorAll("details.dropdown[open]").forEach(d => d.contains(e.target) || (d.open = false)))
          document.addEventListener("keydown", e =>
            e.key === "Escape" && document.querySelectorAll("details.dropdown[open]").forEach(d => (d.open = false)))

          window.addEventListener("DOMContentLoaded", () => {
            const csrf = document.querySelector("meta[name='csrf-token']").content
            // When the server closes the socket (its endpoint restarting), LiveView reloads the page
            // after a random 5-10 s, meant to spread out many clients; one operator needs only ~1 s.
            window.liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
              params: {_csrf_token: csrf},
              hooks: {Follow, InboxSeen, BotNotifications},
              reloadJitterMin: 500,
              reloadJitterMax: 1500
            })
            // LiveView logs debug output on localhost unless told not to. To see it in this tab:
            // liveSocket.enableDebug() in the console, then reload.
            if (sessionStorage.getItem("phx:live-socket:debug") === null) window.liveSocket.disableDebug()
            window.liveSocket.connect()
          })
        </script>
      </head>
      <body>
        {@inner_content}
        <%!-- Shown by app.css while the LiveView above has phx-error: the page is stale. --%>
        <div id="disconnected" role="alert">
          Disconnected from the node — trying to reconnect. What you see here may be out of date.
        </div>
      </body>
    </html>
    """
  end
end
