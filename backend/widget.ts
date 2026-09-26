// Single-file MCP Apps widget: option cards -> Buy -> approval QR -> live status.
export const widgetHtml = /* html */ `<meta charset="utf-8">
<div id="root" style="font-family:system-ui;padding:8px;color:#111"></div>
<style>
  .card{display:flex;gap:10px;align-items:center;border:1px solid #ddd;border-radius:10px;padding:8px;margin:6px 0}
  .card img{width:56px;height:56px;object-fit:contain}
  .grow{flex:1}.muted{color:#666;font-size:12px}
  button{border:0;border-radius:8px;padding:8px 14px;background:#111;color:#fff;cursor:pointer}
  .st{font-weight:600}
  @media (prefers-color-scheme:dark){#root{color:#eee}.card{border-color:#444}.muted{color:#aaa}button{background:#eee;color:#111}}
</style>
<script>
  const root = document.getElementById("root");
  const pending = new Map(); let nextId = 1; let pollTimer;
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

  const oa = window.openai;
  function rpc(method, params) {
    const id = nextId++;
    window.parent.postMessage({ jsonrpc: "2.0", id, method, params }, "*");
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  }
  function call(name, args) {
    if (oa?.callTool) return oa.callTool(name, args);
    const id = nextId++;
    window.parent.postMessage({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } }, "*");
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  }
  function followUp(text) {
    if (oa?.sendFollowUpMessage) return oa.sendFollowUpMessage({ prompt: text });
    window.parent.postMessage({ jsonrpc: "2.0", id: nextId++, method: "ui/message", params: { role: "user", content: [{ type: "text", text }] } }, "*");
  }

  function render(data) {
    if (!data) return;
    if (data.view === "options") {
      root.innerHTML = data.offers.length ? data.offers.map((o) => \`
        <div class="card">
          \${o.image ? \`<img src="\${esc(o.image)}" alt="">\` : ""}
          <div class="grow"><div>\${esc(o.title)}</div>
            <div class="muted">\${esc(new URL(o.merchant).host)} · $\${(o.priceMinor/100).toFixed(2)}</div></div>
          <button data-sku="\${esc(o.sku)}">Buy</button>
        </div>\`).join("") : "No results.";
      root.querySelectorAll("button[data-sku]").forEach((b) => b.onclick = async () => {
        b.disabled = true; b.textContent = "…";
        const r = await call("request_approval", { sku: b.dataset.sku });
        render(r?.structuredContent);
      });
    }
    if (data.view === "approval") {
      const o = data.order;
      root.innerHTML = \`
        <div class="card"><div class="grow"><div>\${esc(o.title)}</div>
          <div class="muted">\${esc(new URL(o.merchant).host)} · $\${o.price.toFixed(2)} · cart \${esc(o.cartHash.slice(0,10))}…</div></div></div>
        <div class="st">Status: \${esc(o.status)}</div>
        \${o.status === "pending" ? \`<div style="margin-top:6px">\${o.qrSvg ?? ""}</div>
          <div class="muted">Approve this exact cart with World ID: scan in World App, or paste the <a href="\${esc(o.approvalUrl)}" target="_blank">request link</a> into the <a href="https://simulator.worldcoin.org" target="_blank">World ID simulator</a>.</div>\` : ""}
        \${o.denyReason ? \`<div class="muted">\${esc(o.denyReason)}</div>\` : ""}
        \${o.txHash ? \`<div class="muted">tx \${esc(o.txHash)}</div>\` : ""}\`;
      clearTimeout(pollTimer);
      if (o.status === "pending") {
        pollTimer = setTimeout(async () => render((await call("get_order", { orderId: o.orderId }))?.structuredContent), 2000);
      } else if (o.status === "approved" && !render.told) {
        render.told = true;
        followUp("The human approved order " + o.orderId + " with World ID. Complete the purchase.");
      }
    }
  }

  window.addEventListener("message", (e) => {
    if (e.source !== window.parent) return;
    const m = e.data; if (!m || m.jsonrpc !== "2.0") return;
    if (m.id !== undefined && pending.has(m.id)) {
      const p = pending.get(m.id); pending.delete(m.id);
      m.error ? p.reject(m.error) : p.resolve(m.result); return;
    }
    if (m.method === "ui/notifications/tool-result") render(m.params?.structuredContent);
  }, { passive: true });

  // MCP Apps handshake: the host only pushes tool results after ui/initialize.
  rpc("ui/initialize", { protocolVersion: "2026-01-26", appInfo: { name: "cartlock", version: "0.1.0" }, appCapabilities: {} })
    .then(() => window.parent.postMessage({ jsonrpc: "2.0", method: "ui/notifications/initialized", params: {} }, "*"))
    .catch(() => {});
  // ChatGPT globals path (window.openai) as a fallback.
  if (oa?.toolOutput) render(oa.toolOutput);
  window.addEventListener("openai:set_globals", (e) => { const t = e.detail?.globals?.toolOutput; if (t) render(t); });
  // Tell the host our height so the iframe is not collapsed.
  new ResizeObserver(() => window.parent.postMessage({ jsonrpc: "2.0", method: "ui/notifications/size-changed",
    params: { width: document.body.scrollWidth, height: document.body.scrollHeight } }, "*")).observe(document.body);
</script>`;
