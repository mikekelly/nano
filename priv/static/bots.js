// Registered by the shared layout as hooks: {Follow, BotsUI: window.BotsUI}.
window.BotsUI = {
  mounted() {
    this.notified = new Set(); this.times = [];
    this.handleEvent("bots:sent", () => { const input = this.el.querySelector("#message-input"); if (input) input.value = ""; });
    this.handleEvent("bots:notify", data => {
      const now = Date.now(); this.times = this.times.filter(t => now - t < 3600000);
      if (!document.hidden || !("Notification" in window) || Notification.permission !== "granted" || this.notified.has(data.id) || this.times.length >= Math.max(1, Math.min(data.max_per_hour || 5, 20)) || (this.times.length && now - this.times.at(-1) < Math.max(data.min_interval_ms || 60000, 60000))) return;
      this.notified.add(data.id); this.times.push(now);
      try { const n = new Notification(data.title, {tag: "bots-" + data.id}); n.onclick = () => { window.focus(); window.location.assign("/bots/" + encodeURIComponent(data.session_id)); n.close(); }; } catch (_) { /* Permission or platform unavailable. Chat remains answerable. */ }
    });
    this.click = e => { const b = e.target.closest("[data-notification-opt-in]"); if (b && b.getAttribute("phx-value-enabled") === "true" && "Notification" in window) Notification.requestPermission().catch(() => {}); };
    this.key = e => {
      if (e.target.id === "to-query" && ["ArrowUp", "ArrowDown", "Enter"].includes(e.key)) e.preventDefault();
      if (e.metaKey && /^[1-9]$/.test(e.key)) { e.preventDefault(); this.pushEvent("recipient_key", {key: e.key, metaKey: true}); }
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter" && e.target.id === "message-input") { e.preventDefault(); e.target.form.requestSubmit(); }
    };
    this.el.addEventListener("click", this.click); this.el.addEventListener("keydown", this.key);
  },
  destroyed() { this.el.removeEventListener("click", this.click); this.el.removeEventListener("keydown", this.key); }
};
