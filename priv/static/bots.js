/* Plain script, loaded before LiveSocket starts; no build pipeline or untrusted HTML. */
(() => {
  "use strict"
  const storageKey = "nano-bots-notifications-v1"
  const permission = () => "Notification" in window ? Notification.permission : "unsupported"
  const focusable = (root) => Array.from(root.querySelectorAll("button:not(:disabled), a[href], input:not(:disabled), textarea:not(:disabled), [tabindex='0']"))
    .filter(el => el.getClientRects().length)
  const boundedNumber = (value, fallback, min, max) => Number.isFinite(Number(value)) ? Math.min(max, Math.max(min, Number(value))) : fallback

  window.BotsHooks = Object.assign(window.BotsHooks || {}, {
    BotsShell: {
      mounted() {
        this.destroyedFlag = false
        this.following = true
        this.lastSession = this.el.dataset.session
        this.pickerIndex = -1
        this.notifications = new Set()
        this.onKey = event => this.keydown(event)
        this.onClick = event => this.click(event)
        this.onInput = event => {
          if (event.target.id === "recipient-input") { this.pickerIndex = -1; this.highlight() }
          if (event.target.id === "message-input") this.resizeComposer()
        }
        this.onScroll = event => {
          if (event.target.id !== "bots-messages") return
          const log = event.target
          this.following = log.scrollHeight - log.scrollTop - log.clientHeight < 70
          if (this.following) this.jumpButton(true)
        }
        this.el.addEventListener("keydown", this.onKey)
        this.el.addEventListener("click", this.onClick)
        this.el.addEventListener("input", this.onInput)
        this.el.addEventListener("scroll", this.onScroll, true)
        this.handleEvent("bots:focus", ({id}) => {
          if (["recipient-input", "message-input"].includes(id)) this.el.querySelector(`#${id}`)?.focus()
        })
        this.handleEvent("bots:sent", () => {
          const input = this.el.querySelector("#message-input")
          if (input) { input.value = ""; input.style.height = "auto"; input.focus() }
          this.following = true
          this.toBottom()
        })
        this.handleEvent("bots:notification", event => this.notify(event))
        this.resize = typeof ResizeObserver === "function" ? new ResizeObserver(() => { if (this.following) this.toBottom() }) : {observe(){}, unobserve(){}, disconnect(){}}
        this.pushEvent("permission", {permission: permission()})
        this.sync()
      },
      updated() { this.sync() },
      destroyed() {
        this.destroyedFlag = true
        this.el.removeEventListener("keydown", this.onKey)
        this.el.removeEventListener("click", this.onClick)
        this.el.removeEventListener("input", this.onInput)
        this.el.removeEventListener("scroll", this.onScroll, true)
        this.resize.disconnect()
        this.notifications.forEach(n => n.close())
      },
      sync() {
        const session = this.el.dataset.session
        if (session !== this.lastSession) {
          this.lastSession = session
          this.following = true
          this.pickerIndex = -1
        }
        const log = this.el.querySelector("#bots-messages")
        if (log !== this.log) {
          if (this.log) this.resize.unobserve(this.log)
          this.log = log
          if (log) this.resize.observe(log)
        }
        const last = log?.lastElementChild?.id
        if (last !== this.lastMessage) {
          this.lastMessage = last
          if (!this.following) this.jumpButton(false)
        }
        if (this.following) this.toBottom()
        this.highlight()
        this.resizeComposer()
        const modal = this.el.querySelector('[role="dialog"]')
        if (modal && modal !== this.modal) {
          this.returnFocus = document.activeElement
          this.modal = modal
          ;(modal.querySelector("[autofocus]") || focusable(modal)[0])?.focus()
        } else if (!modal && this.modal) {
          this.modal = null
          if (this.returnFocus?.isConnected) this.returnFocus.focus()
        }
      },
      toBottom() { if (this.log) { this.log.scrollTop = this.log.scrollHeight; this.jumpButton(true) } },
      jumpButton(hidden) { const button = this.el.querySelector("#bots-jump"); if (button) button.hidden = hidden },
      resizeComposer() {
        const input = this.el.querySelector("#message-input")
        if (input) { input.style.height = "auto"; input.style.height = `${Math.min(input.scrollHeight, 180)}px` }
      },
      options() { return Array.from(this.el.querySelectorAll("[data-recipient-option]")) },
      highlight() {
        const options = this.options()
        if (this.pickerIndex >= options.length) this.pickerIndex = -1
        options.forEach((option, index) => option.setAttribute("aria-selected", String(index === this.pickerIndex)))
        const input = this.el.querySelector("#recipient-input")
        if (this.pickerIndex >= 0) input?.setAttribute("aria-activedescendant", options[this.pickerIndex].id)
        else input?.removeAttribute("aria-activedescendant")
      },
      keydown(event) {
        if (event.isComposing) return
        if (event.key === "Tab" && this.modal) {
          const items = focusable(this.modal), first = items[0], last = items[items.length - 1]
          if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus() }
          else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus() }
          return
        }
        if ((event.metaKey || event.ctrlKey) && /^[1-9]$/.test(event.key) && !this.modal) {
          const option = this.el.querySelector(`[data-bot-shortcut="${event.key}"]`)
          if (option) { event.preventDefault(); option.click(); this.pickerIndex = -1 }
          return
        }
        if (event.target.id === "recipient-input") {
          const options = this.options()
          if (["ArrowDown", "ArrowUp"].includes(event.key) && options.length) {
            event.preventDefault()
            this.pickerIndex = this.pickerIndex < 0 ? (event.key === "ArrowDown" ? 0 : options.length - 1) : (this.pickerIndex + (event.key === "ArrowDown" ? 1 : -1) + options.length) % options.length
            this.highlight()
            options[this.pickerIndex].scrollIntoView({block:"nearest"})
          } else if (event.key === "Enter" && options.length) {
            event.preventDefault()
            const firstBot = options.findIndex(option => option.dataset.botShortcut)
            options[this.pickerIndex >= 0 ? this.pickerIndex : Math.max(0, firstBot)].click()
            this.pickerIndex = -1
          } else if (event.key === "Escape") { this.pickerIndex = -1; this.highlight() }
        }
        if (event.target.id === "message-input" && event.key === "Enter" && !event.shiftKey) {
          event.preventDefault()
          if (event.target.value.trim()) event.target.form.requestSubmit()
        }
      },
      click(event) {
        const attach = event.target.closest("[data-bots-attach]")
        if (attach && !attach.disabled) document.getElementById(attach.dataset.botsAttach)?.click()
        const focus = event.target.closest("[data-bots-focus]")
        if (focus?.dataset.botsFocus === "chat-search") this.el.querySelector("#chat-search")?.focus()
        if (event.target.closest("#bots-jump")) { this.following = true; this.toBottom() }
        if (event.target.closest("#bots-enable-browser")) {
          // Permission is requested only in this explicit user gesture, never on mount.
          if (permission() === "unsupported") this.pushEvent("permission", {permission:"unsupported"})
          else Notification.requestPermission().then(result => this.pushEvent("permission", {permission:result})).catch(() => this.pushEvent("permission", {permission:permission()}))
        }
      },
      notify(event) {
        // Server applies the real limits. This local guard also deduplicates across tabs
        // (Web Locks where supported) and never renders content as HTML.
        if (!event || typeof event.id !== "string" || typeof event.session_id !== "string") return
        const show = () => {
          if (this.destroyedFlag || this.el.dataset.notifications !== "true" || !document.hidden || permission() !== "granted") return
          const now = Date.now()
          let recent = []
          try { recent = JSON.parse(localStorage.getItem(storageKey) || "[]") } catch (_) { /* private mode */ }
          if (!Array.isArray(recent)) recent = []
          recent = recent.filter(item => item && typeof item.id === "string" && Number.isFinite(item.at) && item.at > now - 3600000).slice(-60)
          const max = boundedNumber(this.el.dataset.maxHour, 6, 0, 60)
          const cooldown = boundedNumber(this.el.dataset.cooldown, 300, 60, 86400) * 1000
          if (recent.some(item => item.id === event.id) || recent.length >= max || recent.some(item => now - item.at < cooldown)) return
          try {
            const n = new Notification(String(event.title || "Bots").slice(0, 100), {
              body:String(event.body || "A bot has an update for you.").slice(0, 240), tag:`bots-${event.id.slice(0, 100)}`
            })
            this.notifications.add(n)
            n.onclose = () => this.notifications.delete(n)
            n.onclick = () => {
              n.close()
              window.focus()
              window.location.assign(`/bots/${encodeURIComponent(event.session_id.slice(0, 200))}`)
            }
            recent.push({id:event.id.slice(0, 200), at:now})
            try { localStorage.setItem(storageKey, JSON.stringify(recent)) } catch (_) { /* server still enforces limits */ }
          } catch (_) { /* Browser/OS policy may prevent a notification; chat remains available. */ }
        }
        if (navigator.locks?.request) navigator.locks.request("nano-bots-notifications", show).catch(() => {})
        else show()
      }
    }
  })
})()
