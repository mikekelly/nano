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
  document.addEventListener("keydown", event => {
    if (!document.getElementById("bots-product")) return;
    const input = document.getElementById("bot-to");
    const choices = Array.from(document.querySelectorAll("#bot-choices button"));
    if ((event.metaKey || event.ctrlKey) && event.key === "k") { event.preventDefault(); input?.focus(); }
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
