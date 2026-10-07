/* This surface owns its hooks and socket; operator assets remain untouched. */
(() => {
  'use strict';
  const Hooks = {};
  Hooks.BotsRecipients = {
    mounted() {
      this.active = -1;
      this.key = e => {
        const options = [...document.querySelectorAll('#recipient-options [role="option"]')].filter(x => !x.disabled);
        if (e.key === 'Escape') { e.preventDefault(); this.pushEvent('close-recipients', {}); return; }
        let index;
        if ((e.ctrlKey || e.metaKey) && /^[1-9]$/.test(e.key)) index = options.findIndex(x => x.dataset && x.dataset.shortcut === e.key);

        else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
          e.preventDefault();
          if (!options.length) return;
          this.active = (this.active + (e.key === 'ArrowDown' ? 1 : -1) + options.length) % options.length;
          options.forEach((x, i) => x.setAttribute('aria-selected', String(i === this.active)));
          const selected = options[this.active];
          if (selected.id) this.el.setAttribute('aria-activedescendant', selected.id);
          selected.scrollIntoView({block: 'nearest'}); return;
        } else if (e.key === 'Enter' && options.length) index = Math.max(0, this.active);
        if (index !== undefined && options[index]) { e.preventDefault(); options[index].click(); this.active = -1; }
      };
      this.el.addEventListener('keydown', this.key);
    },
    updated() { this.active = -1; this.el.removeAttribute('aria-activedescendant'); },
    destroyed() { this.el.removeEventListener('keydown', this.key); }
  };
  Hooks.BotsComposer = {
    mounted() {
      this.key = e => {
        if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) {
          e.preventDefault();
          const form = this.el.closest('form');
          const submit = form && form.querySelector('[type="submit"]');
          if (form && (!submit || !submit.disabled)) form.requestSubmit(submit || undefined);
        }
      };
      this.el.addEventListener('keydown', this.key);
    },
    destroyed() { this.el.removeEventListener('keydown', this.key); }
  };
  Hooks.BotsFollow = {
    mounted() {
      this.follow = true;
      this.session = (this.el.dataset.sessionId || this.el.dataset.session);
      this.jump = () => { this.follow = true; this.el.scrollTop = this.el.scrollHeight; this.showJump(false); };
      this.showJump = visible => { const button = document.getElementById('jump-latest'); if (button) button.hidden = !visible; };
      this.scroll = () => { this.follow = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 96; if (this.follow) this.showJump(false); };
      this.click = e => { if (e.target.closest('#jump-latest')) this.jump(); };
      this.el.addEventListener('scroll', this.scroll, {passive:true});
      document.addEventListener('click', this.click);
      this.handleEvent('bots-show-latest', () => this.jump());
      this.jump();
    },
    beforeUpdate() { this.wasFollowing = this.follow; this.firstMessage = this.el.querySelector('article[id]')?.id; this.oldHeight = this.el.scrollHeight; this.oldTop = this.el.scrollTop; },
    updated() {
      if (this.session !== (this.el.dataset.sessionId || this.el.dataset.session)) { this.session = (this.el.dataset.sessionId || this.el.dataset.session); this.wasFollowing = true; }
      const first = this.el.querySelector('article[id]')?.id;
      if (this.firstMessage && first && first !== this.firstMessage && this.el.querySelector(`[id="${this.firstMessage}"]`)) {
        this.follow = false; this.el.scrollTop = this.oldTop + this.el.scrollHeight - this.oldHeight;
      } else if (this.wasFollowing) this.jump(); else this.showJump(true);
    },
    destroyed() { this.el.removeEventListener('scroll', this.scroll); document.removeEventListener('click', this.click); }
  };
  const storageKey = 'vega.bots.notifications.v1';
  Hooks.BotsNotifications = {
    mounted() {
      this.permission = () => {
        const status = this.el.querySelector('#notification-permission');
        if (status) status.textContent = !('Notification' in window) ? 'Browser notifications are unavailable.' : Notification.permission === 'denied' ? 'Notifications blocked. Enable them in browser settings.' : Notification.permission === 'granted' ? 'Browser notifications enabled.' : 'Click Enable to allow browser notifications.';
      };
      this.click = async e => {
        if (!e.target.closest('#enable-notifications') || !('Notification' in window)) return;
        try { await Notification.requestPermission(); } catch (_) { /* Permission remains visibly unchanged. */ }
        this.permission();
      };
      this.el.addEventListener('click', this.click);
      this.permission();
      this.handleEvent('bots-notification', payload => this.notify(payload));
    },
    updated() { this.permission(); },
    destroyed() { this.el.removeEventListener('click', this.click); },
    notify(payload) {
      // Serialize the shared ledger across same-origin tabs when Web Locks exists.
      if (navigator.locks) navigator.locks.request(storageKey, () => this.notifyLocked(payload));
      else this.notifyLocked(payload);
    },
    notifyLocked({event, settings, session_title, text}) {
      if (!event || !settings || (settings.notifications_enabled ?? settings.enabled) !== true || !document.hidden || !('Notification' in window) || Notification.permission !== 'granted') return;
      const request = ['request', 'human_request', 'request_human'].includes(event.type || event.kind);
      if (!request && ((event.type || event.kind) !== 'message' || event.author_id === 'person')) return;
      const requestsOnly = settings.notification_requests_only ?? settings.request_only ?? settings.requests_only ?? true;
      if (requestsOnly !== false && !request) return;
      const interval = Number(settings.notification_interval_seconds ?? settings.min_interval_seconds ?? settings.min_interval ?? 60);
      const max = Number(settings.notification_max_per_hour ?? settings.max_per_hour ?? 6);
      if (!Number.isFinite(interval) || interval < 0 || !Number.isInteger(max) || max < 1) return;
      const id = event.id || event.event_id || event.request_id || event.message_id;
      if (typeof id !== 'string' || !id) return;
      // Fail closed without durable storage: reloads must not reset rate limits.
      let state;
      try { state = JSON.parse(localStorage.getItem(storageKey) || '{"seen":{},"times":[]}'); } catch (_) { return; }
      if (!state || typeof state.seen !== 'object' || !state.seen || !Array.isArray(state.times)) return;
      const now = Date.now();
      state.times = state.times.filter(t => Number.isFinite(t) && t > now - 3600000);
      if (state.seen[id] || state.times.length >= max || (state.times.length && now - Math.max(...state.times) < interval * 1000)) return;
      state.seen[id] = now; state.times.push(now);
      // Keep the ledger bounded while retaining a week of deduplication.
      for (const key of Object.keys(state.seen)) if (state.seen[key] < now - 604800000) delete state.seen[key];
      try { localStorage.setItem(storageKey, JSON.stringify(state)); } catch (_) { return; }
      const preview = settings.notification_preview === true || settings.show_preview === true || settings.preview_content === true;
      const notification = new Notification(preview ? String(session_title || 'Bots') : 'Bots', {
        body: preview ? String(text || '').slice(0, 240) : request ? 'A bot needs your response.' : 'You have a new message.', tag: id
      });
      notification.onclick = () => { window.focus(); notification.close(); const id = event.session_id; if (id) this.pushEvent('open-session', {id}); };
    }
  };
  window.BotsHooks = Hooks;
  const boot = () => {
    const LiveSocket = (window.LiveView && window.LiveView.LiveSocket) || window.LiveSocket;
    const Socket = window.Phoenix && window.Phoenix.Socket;
    if (!LiveSocket || !Socket) return;
    const csrf = document.querySelector('meta[name="csrf-token"]');
    const socket = new LiveSocket('/live', Socket, {params: {_csrf_token: csrf && csrf.content}, hooks: Hooks});
    socket.connect(); window.botsLiveSocket = socket;
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot, {once:true}); else boot();
})();
