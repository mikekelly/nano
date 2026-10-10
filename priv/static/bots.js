// Origin-wide interruption budget. Web Locks serialize the read/check/write across
// tabs. Without locks or working durable storage we suppress notifications, not
// silently fall back to an unbounded per-tab budget. Chat requests remain visible.
// Reservations count even if the platform constructor fails. Dedup retains up to
// 200 IDs for 24 hours; the hourly budget retains at most 20 timestamps. User
// clearing site data resets the budget. No OS delivery guarantee is implied.
window.BotsNotificationPolicy = {
  key: "nano:bots:notifications:v1",
  async notify(data) {
    const eligible = () => document.hidden && "Notification" in window && Notification.permission === "granted";
    if (!eligible() || !navigator.locks || typeof navigator.locks.request !== "function" || typeof data.id !== "string" || !data.id || data.id.length > 200) return false;
    try {
      return await navigator.locks.request("nano:bots:notifications:v1", {mode: "exclusive", ifAvailable: true}, lock => {
        if (!lock || !eligible()) return false;
        const now = Date.now();
        const raw = localStorage.getItem(this.key);
        let state = raw === null ? {version: 1, times: [], seen: []} : JSON.parse(raw);
        if (!state || state.version !== 1 || !Array.isArray(state.times) || state.times.length > 20 || !Array.isArray(state.seen) || state.seen.length > 200 ||
            !state.times.every(t => Number.isFinite(t) && t >= 0 && t <= now) ||
            !state.seen.every(e => e && typeof e.id === "string" && e.id.length <= 200 && Number.isFinite(e.at) && e.at >= 0 && e.at <= now)) return false;
        state.times = state.times.filter(t => now - t < 3600000).sort((a, b) => a - b);
        state.seen = state.seen.filter(e => now - e.at < 86400000);
        const cap = Math.max(1, Math.min(Number(data.max_per_hour) || 5, 20));
        const interval = Math.max(Number(data.min_interval_ms) || 60000, 60000);
        if (state.seen.some(e => e.id === data.id) || state.times.length >= cap || (state.times.length && now - state.times.at(-1) < interval)) return false;
        state.times.push(now); state.seen.push({id: data.id, at: now}); state.seen = state.seen.slice(-200);
        const encoded = JSON.stringify(state);
        localStorage.setItem(this.key, encoded);
        if (localStorage.getItem(this.key) !== encoded) return false;
        const n = new Notification(data.title, {tag: "bots-" + data.id});
        n.onclick = () => { window.focus(); window.location.assign("/bots/" + encodeURIComponent(data.session_id)); n.close(); };
        return true;
      });
    } catch (_) { return false; }
  }
};
// Registered by the shared layout as hooks: {Follow, BotsUI: window.BotsUI}.
window.BotsUI = {
  mounted() {
    this.handleEvent("bots:sent", () => { const input = this.el.querySelector("#message-input"); if (input) input.value = ""; });
    this.handleEvent("bots:notify", data => { window.BotsNotificationPolicy.notify(data); });
    this.click = e => { const b = e.target.closest("[data-notification-opt-in]"); if (b && b.getAttribute("phx-value-enabled") === "true" && "Notification" in window) { try { Promise.resolve(Notification.requestPermission()).catch(() => {}); } catch (_) { /* Chat works without permission. */ } } };
    this.key = e => {
      if (e.target.id === "to-query" && ["ArrowUp", "ArrowDown", "Enter"].includes(e.key)) e.preventDefault();
      if (e.metaKey && /^[1-9]$/.test(e.key)) { e.preventDefault(); this.pushEvent("recipient_key", {key: e.key, metaKey: true}); }
      if ((e.metaKey || e.ctrlKey) && e.key === "Enter" && e.target.id === "message-input") { e.preventDefault(); e.target.form.requestSubmit(); }
    };
    this.el.addEventListener("click", this.click); this.el.addEventListener("keydown", this.key);
  },
  destroyed() { this.el.removeEventListener("click", this.click); this.el.removeEventListener("keydown", this.key); }
};
