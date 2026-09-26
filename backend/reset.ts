// npm run reset -- <wallet address | handle | all>
// Start over with the same wallet and World ID: PolicySpender.resetFor(wallet) + unregister <handle>.proviso.eth from the operator
// key, then the account's requests, approvals, orders, sessions and row are deleted ("all": every account not on the demo wallet).
// While the backend runs this goes through its loopback admin port (the running process owns the state); otherwise it edits the files.
const target = process.argv[2];
if (!target) {
  console.error("usage: npm run reset -- <wallet address | handle | all>");
  process.exit(2);
}
const PORT = Number(process.env.PORT ?? 8787), ADMIN = Number(process.env.PROVISO_ADMIN_PORT ?? PORT + 10);
const up = (url: string, init?: RequestInit) => fetch(url, { ...init, signal: AbortSignal.timeout(300_000) }).catch(() => undefined);

let results: any[];
const r = await up(`http://127.0.0.1:${ADMIN}/reset`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ target }) });
if (r) {
  const body = await r.json();
  if (!r.ok) fail(body.error);
  results = body;
  console.log(`via the running backend (admin :${ADMIN})`);
} else {
  // a backend without the admin port would write its in-memory copy back over the files
  if (await up(`http://127.0.0.1:${PORT}/merchant/orders`)) fail(`a backend is running on :${PORT} without the admin port :${ADMIN}; stop it, re-run, start it`);
  const { resetTarget } = await import("./proviso.js");
  results = await resetTarget(target).catch((e) => fail(e?.shortMessage ?? e?.message ?? e));
  console.log("via the state files (backend not running)");
}
for (const x of results) {
  console.log(`reset ${x.handle}${x.wallet ? ` (${x.wallet})` : ""}: chain ${x.chain ? "resetFor sent" : "skipped (no account row, or demo wallet)"}, ` +
    `ENS ${x.ens ? `${x.ens} unregistered` : "skipped"}, deleted ${x.requests} requests + ${x.orders} orders + sessions + account`);
  for (const h of x.txs) console.log(`  https://sepolia.etherscan.io/tx/${h}`);
}
process.exit(0);

function fail(msg: string): never {
  console.error(`reset failed: ${msg}`);
  process.exit(1);
}
