/// GET /: what's running, and a place to try speaking and listening.
enum StatusPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Super Voice</title>
<style>
  :root { --bg:#f6f6f8; --card:#fff; --text:#1d1d1f; --muted:#6e6e73; --line:#e3e3e8; --accent:#5b5bd6; --ok:#2f9e5b; --off:#c4473a; }
  @media (prefers-color-scheme: dark) { :root { --bg:#151517; --card:#1f1f22; --text:#f2f2f4; --muted:#9a9aa1; --line:#2e2e33; --accent:#8b8bf0; --ok:#4cc27c; --off:#e8705f; } }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
  main { max-width: 760px; margin: 0 auto; padding: 32px 16px 64px; }
  h1 { font-size: 26px; margin: 0 0 4px; letter-spacing: -0.01em; }
  h2 { font-size: 15px; margin: 0 0 12px; }
  p.sub { color: var(--muted); margin: 0 0 24px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 18px; margin-bottom: 16px; }
  .pills { display: flex; flex-wrap: wrap; gap: 8px; }
  .pill { border: 1px solid var(--line); border-radius: 999px; padding: 3px 10px; font-size: 13px; }
  .pill b { font-weight: 600; }
  .on { color: var(--ok); } .off { color: var(--off); }
  textarea { width: 100%; min-height: 80px; resize: vertical; border: 1px solid var(--line); border-radius: 10px; padding: 10px; background: transparent; color: inherit; font: inherit; }
  select, button, input[type=file] { font: inherit; color: inherit; }
  select { border: 1px solid var(--line); border-radius: 8px; padding: 6px 8px; background: transparent; }
  button { border: 0; border-radius: 10px; padding: 8px 16px; background: var(--accent); color: #fff; font-weight: 600; cursor: pointer; }
  button:disabled { opacity: .5; cursor: default; }
  .row { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-top: 10px; }
  pre { white-space: pre-wrap; word-break: break-word; background: var(--bg); border-radius: 10px; padding: 10px; margin: 10px 0 0; min-height: 2.5em; }
  code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
  a { color: var(--accent); }
</style>
</head>
<body>
<main>
  <h1>Super Voice</h1>
  <p class="sub">Speech on this Mac, for every app: <code id="base"></code> · <a href="/api/health">/api/health</a></p>

  <section class="card"><h2>Status</h2><div class="pills" id="status">Checking…</div></section>

  <section class="card">
    <h2>Text to speech</h2>
    <textarea id="text">Hello! This is Super Voice, speaking on your Mac.</textarea>
    <div class="row">
      <select id="voice"></select>
      <button id="speak">Speak</button>
      <button id="say" title="POST /api/say: through this Mac's speakers">Say it on this Mac</button>
      <audio id="player" controls hidden></audio>
    </div>
    <pre id="ttsout" hidden></pre>
  </section>

  <section class="card">
    <h2>Speech to text</h2>
    <input type="file" id="file" accept="audio/*,video/*">
    <div class="row"><button id="listen" disabled>Transcribe</button></div>
    <pre id="sttout"></pre>
  </section>
</main>
<script>
const $ = id => document.getElementById(id);
$("base").textContent = location.origin;
async function status() {
  try {
    const h = await (await fetch("/api/health")).json();
    const eps = ["tts", "stt", "transcribe", "say", "openai"].map(k =>
      `<span class="pill">${k} <b class="${h[k] ? "on" : "off"}">${h[k] ? "on" : "off"}</b></span>`);
    const ms = Object.entries(h.models).map(([k, m]) =>
      `<span class="pill">${m.name} <b>${m.state.replace("_", " ")}${m.progress != null ? " " + Math.round(m.progress * 100) + "%" : ""}</b></span>`);
    const up = h.uptime >= 3600 ? Math.floor(h.uptime / 3600) + " h" : h.uptime >= 60 ? Math.floor(h.uptime / 60) + " min" : h.uptime + " s";
    $("status").innerHTML = eps.concat(ms).join("") + `<span class="pill">v${h.version}</span><span class="pill">up ${up}</span>`;
  } catch (e) { $("status").textContent = "Not answering."; }
}
async function voices() {
  const v = await (await fetch("/api/voices")).json();
  $("voice").innerHTML = v.voices.map(x =>
    `<option value="${x.id}" ${x.id === v.default ? "selected" : ""}>${x.name} (${x.gender}${x.accent === "uk" ? ", UK" : ""})</option>`).join("");
}
$("speak").onclick = async () => {
  $("speak").disabled = true; $("ttsout").hidden = true;
  try {
    const r = await fetch("/api/tts", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: $("text").value, voice: $("voice").value }) });
    if (!r.ok) throw new Error((await r.json()).error);
    $("player").src = URL.createObjectURL(await r.blob()); $("player").hidden = false; $("player").play();
  } catch (e) { $("ttsout").textContent = e.message; $("ttsout").hidden = false; }
  $("speak").disabled = false;
};
$("say").onclick = async () => {
  $("say").disabled = true; $("ttsout").hidden = true;
  try {
    const r = await fetch("/api/say", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: $("text").value, voice: $("voice").value }) });
    if (!r.ok) throw new Error((await r.json()).error);
  } catch (e) { $("ttsout").textContent = e.message; $("ttsout").hidden = false; }
  $("say").disabled = false;
};
$("file").onchange = () => { $("listen").disabled = !$("file").files.length; };
$("listen").onclick = async () => {
  $("listen").disabled = true; $("sttout").textContent = "";
  try {
    const r = await fetch("/api/transcribe", { method: "POST", body: $("file").files[0] });
    if (!r.ok) throw new Error((await r.json()).error);
    const reader = r.body.getReader(), dec = new TextDecoder(); let buf = "", lines = [];
    for (;;) {
      const { done, value } = await reader.read(); if (done) break;
      buf += dec.decode(value, { stream: true });
      let i; while ((i = buf.indexOf("\n")) >= 0) {
        const ev = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
        if (ev.type === "segment") { lines.push(ev.text); $("sttout").textContent = lines.join(" "); }
        if (ev.type === "progress" && ev.total) $("listen").textContent = `Transcribing… ${Math.round(100 * ev.done / ev.total)}%`;
        if (ev.type === "error") throw new Error(ev.message);
      }
    }
    if (!lines.length) $("sttout").textContent = "(no speech)";
  } catch (e) { $("sttout").textContent = e.message; }
  $("listen").textContent = "Transcribe"; $("listen").disabled = false;
};
status(); voices(); setInterval(status, 3000);
</script>
</body>
</html>
"""#
}
