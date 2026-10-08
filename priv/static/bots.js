// This file contains only trusted application code. Model Markdown never produces scripts.
(() => {
  document.addEventListener("click", event => {
    if (event.target.closest("#bot-permission") && "Notification" in window)
      Notification.requestPermission();
  });
  window.addEventListener("phx:bot-notification", event => {
    if (!("Notification" in window) || Notification.permission !== "granted" || !document.hidden) return;
    const data = event.detail;
    const note = new Notification(data.title || "Your bot", {body: data.body, tag: data.session});
    note.onclick = () => { window.focus(); window.location.assign("/bots?session=" + encodeURIComponent(data.session)); note.close(); };
  });
  window.addEventListener("phx:bot-focus", event => {
    requestAnimationFrame(() => document.getElementById(event.detail.id)?.focus());
  });
  // Follow newly arriving messages only while the person is already near the bottom.
  let thread, added, onScroll, following = true;
  const bindThread = () => {
    const current = document.getElementById("bot-thread");
    if (current === thread) return;
    added?.disconnect();
    if (thread && onScroll) thread.removeEventListener("scroll", onScroll);
    thread = current; following = true;
    if (!thread) return;
    onScroll = () => { following = thread.scrollHeight - thread.scrollTop - thread.clientHeight < 60; };
    thread.addEventListener("scroll", onScroll, {passive: true});
    const bottom = () => requestAnimationFrame(() => { if (following && thread) thread.scrollTop = thread.scrollHeight; });
    added = new MutationObserver(bottom);
    added.observe(thread, {childList: true, subtree: true});
    bottom();
  };
  document.addEventListener("DOMContentLoaded", () => {
    new MutationObserver(bindThread).observe(document.body, {childList: true, subtree: true});
    bindThread();
  });
  document.addEventListener("keydown", event => {

    if (!document.getElementById("bots-product")) return;
    const input = document.getElementById("bot-to");
    const choices = Array.from(document.querySelectorAll("#bot-choices button"));
    if ((event.metaKey || event.ctrlKey) && event.key === "k") { event.preventDefault(); if (input) input.focus(); else document.querySelector(".bots-tools button[phx-click=search]")?.click(); }
    if ((event.metaKey || event.ctrlKey) && /^[1-9]$/.test(event.key)) {
      event.preventDefault(); document.querySelectorAll("#bot-choices button[data-recipient]")[Number(event.key) - 1]?.click();
    }
    if ((document.activeElement === input || choices.includes(document.activeElement)) && ["ArrowDown", "ArrowUp"].includes(event.key)) {
      event.preventDefault(); let index = choices.indexOf(document.activeElement);
      index = event.key === "ArrowDown" ? (index + 1) % choices.length : (index - 1 + choices.length) % choices.length;
      choices[index]?.focus();
    }
    if (document.activeElement === input && event.key === "Enter" && choices.length) { event.preventDefault(); choices[0].click(); }
  });
})();
