// One-time "connect your wallet to Hero" page, served at /w/<token>. Dependency-free, raw EIP-1193.
// The whole document lives in a TS template literal: no backticks, dollar-brace or backslashes below.
export const walletPageHtml: string = /* html */ `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<title>Hero · Connect your wallet</title>
<style>
:root{--bg:#0F0F10;--fg:#F5F5F7;--sec:#8E8E93;--line:#2A2A2E;--blue:#0A84FF;--red:#FF453A}
@media (prefers-color-scheme:light){:root{--bg:#FFFFFF;--fg:#0F0F10;--sec:#6E6E73;--line:#E5E5EA;--blue:#007AFF;--red:#FF3B30}}
*{box-sizing:border-box;margin:0}
html,body{background:var(--bg)}
body{color:var(--fg);font:16px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased;-webkit-text-size-adjust:100%}
main{max-width:440px;margin:0 auto;padding:max(44px,env(safe-area-inset-top)) 24px max(32px,env(safe-area-inset-bottom))}
.brand{font-size:15px;font-weight:600;letter-spacing:.02em;color:var(--sec)}
h1{font-size:32px;line-height:1.15;font-weight:700;letter-spacing:-.02em;margin:6px 0 20px}
.intro p{color:var(--sec);font-size:15px;margin-bottom:4px}
ol{list-style:none;padding:0;margin:32px 0;border-top:1px solid var(--line)}
li{display:flex;gap:14px;padding:14px 0;border-bottom:1px solid var(--line)}
.ic{flex:none;width:22px;height:22px;border-radius:50%;border:1.5px solid var(--line);margin-top:1px;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;color:#fff}
.active .ic{border-top-color:var(--blue);animation:spin .8s linear infinite}
.done .ic{background:var(--blue);border-color:var(--blue)}
.done .ic::after{content:"✓"}
.error .ic{background:var(--red);border-color:var(--red)}
.error .ic::after{content:"!"}
@keyframes spin{to{transform:rotate(360deg)}}
.pending .t{color:var(--sec)}
.s{font-size:13px;color:var(--sec);word-break:break-word}
.s:empty{display:none}
.error .s{color:var(--red)}
.s a{color:var(--blue);text-decoration:none}
button,.btn{display:block;width:100%;border:0;border-radius:14px;padding:16px;font-family:inherit;font-size:17px;font-weight:600;line-height:1.2;text-align:center;text-decoration:none;cursor:pointer;background:var(--blue);color:#fff;-webkit-appearance:none;appearance:none}
button:disabled{opacity:.45}
.ghost{background:transparent;color:var(--blue);font-size:15px;font-weight:500;padding:12px;margin-top:8px}
.note{color:var(--sec);font-size:13px;text-align:center;margin-top:12px}
.note:empty{display:none}
.hidden{display:none}
#noeth p{color:var(--sec);font-size:15px;margin-bottom:16px}
#ok{text-align:center;padding-top:10vh}
.big{width:76px;height:76px;border-radius:50%;background:var(--blue);color:#fff;font-size:40px;line-height:76px;margin:0 auto 28px}
#ok h1{font-size:28px;margin-bottom:10px;word-break:break-word}
#ok .sub{color:var(--sec);margin-bottom:40px}
</style></head><body><main>
<section id="setup">
  <div class="brand">Hero</div>
  <h1>Connect your wallet</h1>
  <div class="intro">
    <p>Hero sends you test ETH for gas and sets up your name.</p>
    <p>Then you sign 3 things in MetaMask:</p>
    <p>let the contract spend within your rules, point it at your rules, and lock bigger buys to your World ID.</p>
  </div>
  <ol id="steps">
    <li data-id="wallet"><span class="ic"></span><div><div class="t">Connect wallet</div><div class="s"></div></div></li>
    <li data-id="chain"><span class="ic"></span><div><div class="t">Switch to Sepolia</div><div class="s"></div></div></li>
    <li data-id="prep"><span class="ic"></span><div><div class="t">Preparing your name &amp; gas</div><div class="s"></div></div></li>
    <li data-id="approve"><span class="ic"></span><div><div class="t">1) Allow spending within your rules</div><div class="s"></div></div></li>
    <li data-id="account"><span class="ic"></span><div><div class="t">2) Point Hero to your rules</div><div class="s"></div></div></li>
    <li data-id="continuity"><span class="ic"></span><div><div class="t">3) Lock big buys to your World ID</div><div class="s"></div></div></li>
    <li data-id="done"><span class="ic"></span><div><div class="t">Done</div><div class="s"></div></div></li>
  </ol>
  <div id="noeth" class="hidden">
    <p>Open this page in MetaMask to continue.</p>
    <a id="mm" class="btn">Open in MetaMask</a>
    <button id="copy" class="ghost">Copy link</button>
  </div>
  <button id="go">Connect &amp; set up</button>
  <p id="hint" class="note"></p>
</section>
<section id="ok" class="hidden">
  <div class="big">✓</div>
  <h1 id="okT"></h1>
  <p class="sub">Hero can now shop from this wallet, only within your rules.</p>
  <button id="back">Return to Hero</button>
  <p class="note">or tap ◀ Hero at the top-left</p>
  <button id="usdc" class="ghost">Add MockUSDC to MetaMask</button>
</section>
</main>
<script>
const CHAIN = "0xaa36a7", USDC = "0x16f95d91dba7da3aca778ec053df0ff6c6a8aa8e", EXP = "https://sepolia.etherscan.io";
const $ = (id) => document.getElementById(id);
const T = encodeURIComponent(location.pathname.split("/").filter(Boolean).pop() || "");
const H = { "content-type": "application/json", "ngrok-skip-browser-warning": "1" };
const BATCH = new URLSearchParams(location.search).get("batch") === "1";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const code = (e) => e?.code ?? e?.data?.originalError?.code;
const rows = {};
document.querySelectorAll("li[data-id]").forEach((el) => { rows[el.dataset.id] = el; el.className = "pending"; });
const go = $("go"), hint = $("hint");

// MetaMask mobile injects window.ethereum late.
const ethReady = new Promise((res) => {
  if (window.ethereum) return res(window.ethereum);
  const t = setTimeout(() => res(window.ethereum), 3000);
  window.addEventListener("ethereum#initialized", () => { clearTimeout(t); res(window.ethereum); }, { once: true });
});

async function api(path, body) {
  const r = await fetch("/w/" + T + path, body
    ? { method: "POST", headers: H, body: JSON.stringify(body) }
    : { headers: H, cache: "no-store" });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) { const e = new Error(j.error || "Server error " + r.status); e.status = r.status; throw e; }
  return j;
}

// Poll /status every 3s until ok(status); network blips keep polling, HTTP errors stop.
async function until(ok, what) {
  for (let i = 0; i < 100; i++) {
    try { const s = await api("/status"); if (ok(s)) return s; }
    catch (e) { if (e.status) throw e; }
    await sleep(3000);
  }
  throw new Error(what + " is taking longer than usual.");
}

let cur = null;
function set(id, state, sub, hash) {
  const el = rows[id]; if (!el) return;
  el.className = state; if (state === "active") cur = id;
  const s = el.querySelector(".s");
  if (sub !== undefined) s.textContent = sub;
  if (typeof hash === "string" && /^0x[0-9a-fA-F]{64}$/.test(hash)) {
    const a = document.createElement("a");
    a.href = EXP + "/tx/" + hash; a.target = "_blank"; a.rel = "noopener";
    a.textContent = (s.textContent ? " · " : "") + "View tx " + hash.slice(0, 10) + "…";
    s.append(a);
  }
}

async function switchChain(eth) {
  if ((await eth.request({ method: "eth_chainId" })) === CHAIN) return;
  try { await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: CHAIN }] }); }
  catch (e) {
    if (code(e) !== 4902) throw e;
    await eth.request({ method: "wallet_addEthereumChain", params: [{
      chainId: CHAIN, chainName: "Sepolia", nativeCurrency: { name: "Sepolia Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: ["https://ethereum-sepolia-rpc.publicnode.com"], blockExplorerUrls: [EXP] }] });
  }
}

async function canBatch(eth, from) {
  try {
    const c = await eth.request({ method: "wallet_getCapabilities", params: [from, [CHAIN]] });
    const st = c?.[CHAIN]?.atomic?.status;
    return st === "supported" || st === "ready";
  } catch { return false; }
}

let busy = false;
async function run() {
  if (busy) return;
  busy = true; go.disabled = true; hint.textContent = "";
  try {
    const eth = await ethReady;
    if (!eth) return noEth();
    set("wallet", "active", "Approve the connection in MetaMask…");
    const [from] = await eth.request({ method: "eth_requestAccounts" });
    if (!from) throw new Error("No account selected in MetaMask.");
    set("wallet", "done", from.slice(0, 6) + "…" + from.slice(-4));
    set("chain", "active", "");
    await switchChain(eth);
    set("chain", "done", "Sepolia test network");
    set("prep", "active", "Reserving your name…");
    let c;
    try { c = await api("/connect", { address: from }); }
    catch (e) {
      if (e.status === 409) e.message = "This sign-in is already linked to another wallet. Switch to that account in MetaMask, then try again.";
      throw e;
    }
    const name = String(c.ensName || "your name");
    set("prep", "active", name + " · Hero is sending you test ETH for gas…");
    let s = await until((x) => x.funded, "Funding");
    set("prep", "done", name + " · gas received");
    const isDone = (st, id) => !!(st.done && st.done[id]);
    const calls = (Array.isArray(c.calls) ? c.calls : []).filter((x) => x && ["approve", "account", "continuity"].includes(x.id));
    calls.forEach((x) => set(x.id, isDone(s, x.id) ? "done" : "pending", String(x.label || "")));
    let todo = calls.filter((x) => !isDone(s, x.id));

    if (BATCH && todo.length > 1 && (await canBatch(eth, from))) {
      todo.forEach((x) => set(x.id, "active", "Confirm in MetaMask…"));
      let sent = false;
      try {
        await eth.request({ method: "wallet_sendCalls", params: [{ version: "2.0.0", chainId: CHAIN, from, atomicRequired: true,
          calls: todo.map((x) => ({ to: x.to, data: x.data })) }] });
        sent = true;
      } catch (e) { if (code(e) === 4001) throw e; } // unsupported: fall back to one-by-one
      if (sent) {
        todo.forEach((x) => set(x.id, "active", "Confirming on Sepolia…"));
        await until((st) => todo.every((x) => isDone(st, x.id)), "Sepolia");
        todo.forEach((x) => set(x.id, "done", String(x.label || "")));
        todo = [];
      } else todo.forEach((x) => set(x.id, "pending", String(x.label || "")));
    }

    // One at a time, waiting for each to land, so nonces can't collide.
    for (const x of todo) {
      set(x.id, "active", "Confirm in MetaMask…");
      const h = await eth.request({ method: "eth_sendTransaction", params: [{ from, to: x.to, data: x.data }] });
      set(x.id, "active", "Confirming on Sepolia", h);
      await until((st) => isDone(st, x.id), "Sepolia");
      set(x.id, "done", String(x.label || ""), h);
    }
    set("done", "active", "Finishing up…");
    s = await until((x) => x.ready, "Finishing");
    set("done", "done", "");
    finish(String(s.ensName || name));
  } catch (e) {
    const k = code(e);
    const m = k === 4001 ? "You cancelled — tap to try again"
      : k === -32002 ? "MetaMask already has a request open — check MetaMask."
      : String(e?.message || "Something went wrong.");
    if (cur) set(cur, "error", m); else hint.textContent = m;
    go.textContent = "Try again";
  } finally { busy = false; go.disabled = false; }
}

function noEth() {
  $("noeth").classList.remove("hidden"); go.classList.add("hidden");
  $("mm").href = "https://link.metamask.io/dapp/" + location.host + location.pathname + location.search;
}

function finish(name) {
  $("setup").classList.add("hidden"); $("ok").classList.remove("hidden");
  $("okT").textContent = "You're set — " + name + " is yours";
  ethReady.then((eth) => { if (!eth) $("usdc").classList.add("hidden"); });
}

go.addEventListener("click", run);
$("back").addEventListener("click", () => { location.href = "hero://wallet?ok=1"; });
$("copy").addEventListener("click", async () => {
  try { await navigator.clipboard.writeText(location.href); $("copy").textContent = "Link copied"; }
  catch { prompt("Copy this link", location.href); }
});
$("usdc").addEventListener("click", async () => {
  const eth = await ethReady; if (!eth) return;
  try {
    await eth.request({ method: "wallet_watchAsset", params: { type: "ERC20", options: { address: USDC, symbol: "USDC", decimals: 6 } } });
    $("usdc").textContent = "MockUSDC added";
  } catch {}
});
ethReady.then((eth) => { if (!eth) noEth(); });
api("/status").then((s) => { if (s.ready) finish(String(s.ensName || "your name")); }).catch(() => {});
</script>
</body></html>`;
