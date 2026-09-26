// One-time "connect your wallet to Proviso" page, served at /w/<token>. Dependency-free, raw EIP-1193.
// The whole document lives in a TS template literal: no backticks, dollar-brace or backslashes below.
export const walletPageHtml: string = /* html */ `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="dark light">
<title>Proviso · Connect your wallet</title>
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
.explain{font-size:15px;margin:0 0 16px;padding:14px 16px;border:1px solid var(--line);border-radius:14px}
.ph{font-size:15px;font-weight:600;margin-top:-12px}
#prog ol{margin:12px 0 16px}
</style></head><body><main>
<section id="setup">
  <div class="brand">Proviso</div>
  <h1>Connect your wallet</h1>
  <div class="intro">
    <p>Proviso shops from your own wallet, with no deposits.</p>
    <p>You sign once in MetaMask: no gas, no waiting. Proviso does the rest.</p>
  </div>
  <ol id="steps">
    <li data-id="wallet"><span class="ic"></span><div><div class="t">Connect wallet</div><div class="s"></div></div></li>
    <li data-id="chain"><span class="ic"></span><div><div class="t">Switch to Sepolia</div><div class="s"></div></div></li>
    <li data-id="approve"><span class="ic"></span><div><div class="t">Approve Proviso</div><div class="s">One signature, no gas</div></div></li>
  </ol>
  <div id="prog" class="hidden">
    <p class="ph">Proviso is setting up your name and rules…</p>
    <ol>
      <li data-id="resolver"><span class="ic"></span><div><div class="t">Your rules contract</div><div class="s">You are its only admin</div></div></li>
      <li data-id="name"><span class="ic"></span><div><div class="t">Your name</div><div class="s"></div></div></li>
      <li data-id="account"><span class="ic"></span><div><div class="t">Proviso linked to your wallet</div><div class="s">Spending cap and your World ID lock</div></div></li>
    </ol>
    <div id="txs" class="s"></div>
  </div>
  <div id="noeth" class="hidden">
    <p>Open this page in MetaMask to continue.</p>
    <a id="mm" class="btn">Open in MetaMask</a>
    <button id="copy" class="ghost">Copy link</button>
  </div>
  <p id="explain" class="explain hidden"></p>
  <button id="go">Connect MetaMask</button>
  <p id="hint" class="note"></p>
</section>
<section id="ok" class="hidden">
  <div class="big">✓</div>
  <h1 id="okT"></h1>
  <p class="sub">Proviso can now shop from this wallet, only within your rules.</p>
  <button id="back">Return to Proviso</button>
  <p class="note">or tap ◀ Proviso at the top-left</p>
  <button id="usdc" class="ghost">Add MockUSDC to MetaMask</button>
</section>
</main>
<script>
const CHAIN = "0xaa36a7", USDC = "0x16f95d91dba7da3aca778ec053df0ff6c6a8aa8e", EXP = "https://sepolia.etherscan.io";
const $ = (id) => document.getElementById(id);
const T = encodeURIComponent(location.pathname.split("/").filter(Boolean).pop() || "");
const H = { "content-type": "application/json", "ngrok-skip-browser-warning": "1" };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const code = (e) => e?.code ?? e?.data?.originalError?.code;
const short = (a) => a.slice(0, 6) + "…" + a.slice(-4);
const rows = {};
document.querySelectorAll("li[data-id]").forEach((el) => { rows[el.dataset.id] = el; el.className = "pending"; });
const go = $("go"), hint = $("hint"), explain = $("explain");

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

let cur = null;
function set(id, state, sub) {
  const el = rows[id]; if (!el) return;
  el.className = state; if (state === "active") cur = id;
  if (sub !== undefined) el.querySelector(".s").textContent = sub;
}

function showTxs(txs) {
  const box = $("txs"); box.textContent = "";
  (Array.isArray(txs) ? txs : []).filter((h) => /^0x[0-9a-fA-F]{64}$/.test(h)).forEach((h) => {
    const a = document.createElement("a");
    a.href = EXP + "/tx/" + h; a.target = "_blank"; a.rel = "noopener";
    a.textContent = (box.childElementCount ? " · " : "Proviso's transactions: ") + h.slice(0, 10) + "…";
    box.append(a);
  });
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

// stage: "connect" -> "sign" -> "wait"; the button runs the current stage, so a cancel retries only that stage
let stage = "connect", ctx = null, busy = false;

async function connect() {
  const eth = await ethReady;
  if (!eth) return noEth();
  $("prog").classList.add("hidden");
  set("wallet", "active", "Approve the connection in MetaMask…");
  const [from] = await eth.request({ method: "eth_requestAccounts" });
  if (!from) throw new Error("No account selected in MetaMask.");
  set("wallet", "done", short(from));
  set("chain", "active", "");
  await switchChain(eth);
  set("chain", "done", "Sepolia test network");
  set("approve", "active", "Preparing…");
  let c;
  try { c = await api("/connect", { address: from }); }
  catch (e) {
    if (e.status === 409) e.message = "This sign-in is already linked to another wallet. Switch to that account in MetaMask, then try again.";
    throw e;
  }
  if (c.mode !== "permit" || !c.typedData) throw new Error("Unexpected server response.");
  ctx = { eth, from, c };
  const cap = Number(c.typedData.message.value) / 1e6;
  explain.textContent = "One signature, no gas: lets Proviso's contract spend up to $" + cap.toLocaleString("en-US")
    + " from this wallet — only within your rules, which live at " + String(c.ensName) + ", and only with your World ID for bigger buys.";
  explain.classList.remove("hidden");
  set("approve", "pending", "One signature, no gas");
  stage = "sign"; go.textContent = "Approve Proviso";
}

async function sign() {
  const { eth, from, c } = ctx;
  set("approve", "active", "Sign in MetaMask…");
  const signature = await eth.request({ method: "eth_signTypedData_v4", params: [from, JSON.stringify(c.typedData)] });
  set("approve", "active", "Sending to Proviso…");
  try { await api("/permit", { signature }); }
  catch (e) {
    if (e.status === 400) { stage = "connect"; e.message = "That signature didn't match. Tap to sign again."; }
    throw e;
  }
  set("approve", "done", "Signed · no gas");
  stage = "wait";
  await watch();
}

// Poll /status every 2s until Proviso's transactions have landed.
async function watch() {
  explain.classList.add("hidden"); go.classList.add("hidden");
  $("prog").classList.remove("hidden");
  let readyAt = 0;
  for (let i = 0; i < 150; i++) {
    let s = null;
    try { s = await api("/status"); } catch (e) { if (e.status) throw e; }
    if (s) {
      if (!s.signed && !s.ready) { stage = "connect"; throw new Error("Proviso couldn't use that signature. Tap to sign again."); }
      ["resolver", "name", "account"].forEach((id) => set(id, s.done && s.done[id] ? "done" : "active", id === "name" ? String(s.ensName || "") : undefined));
      showTxs(s.txs);
      if (s.ready) {
        readyAt = readyAt || Date.now();
        if ((s.done && s.done.name) || Date.now() - readyAt > 20000) return finish(String(s.ensName || "your name"));
      }
    }
    await sleep(2000);
  }
  throw new Error("Setup is taking longer than usual. Tap to check again.");
}

async function run() {
  if (busy) return;
  busy = true; go.disabled = true; hint.textContent = "";
  try {
    if (stage === "connect") await connect();
    else if (stage === "sign") await sign();
    else await watch();
  } catch (e) {
    const k = code(e);
    const m = k === 4001 ? "You cancelled — tap to try again"
      : k === -32002 ? "MetaMask already has a request open — check MetaMask."
      : String(e?.message || "Something went wrong.");
    if (cur) set(cur, k === 4001 ? "pending" : "error", m); else hint.textContent = m;
    go.classList.remove("hidden");
    go.textContent = stage === "sign" ? "Approve Proviso" : "Try again";
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
$("back").addEventListener("click", () => { location.href = "proviso://wallet?ok=1"; });
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
// reopened page: already done, or Proviso is still setting up after an earlier signature
api("/status").then((s) => {
  if (s.ready) return finish(String(s.ensName || "your name"));
  if (s.signed && !busy) { ["wallet", "chain", "approve"].forEach((id) => set(id, "done")); stage = "wait"; run(); }
}).catch(() => {});
</script>
</body></html>`;
