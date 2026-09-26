// Self-check for worldid.ts + Sign in with World ID (no network): `npx tsx check.ts`
// RS256 ID token validation against a local RSA key, the device-grant state machine against a fake IdP,
// the authorization-code + PKCE login and session middleware against the same fake IdP,
// and the EIP-712 HumanApproval digest against the constant PolicySpender's forge test asserts.
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { once } from "node:events";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hashTypedData, keccak256, recoverTypedDataAddress, stringToBytes, verifyTypedData } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const ISS = "https://sandbox.auth.world.org";
process.env.WORLD_OIDC_ISSUER = ISS;
process.env.WORLD_OIDC_CLIENT_ID = "client-test";
process.env.WORLD_OIDC_CLIENT_SECRET = "secret-test";
const { verifyIdToken, startDevice, pollDevice, approvalTypedData, ACR, pkceChallenge, loginUrl, takeLogin, redeemLogin } = await import("./worldid.js");

const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: "jwk" }), kid: "k1", alg: "RS256", use: "sig" };
const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const good = { iss: ISS, sub: "alice-sub", aud: "client-test", exp: now + 300, iat: now, auth_time: now, acr: ACR, amr: ["pop"] };
const jwt = (claims: object, header: object = { alg: "RS256", kid: "k1" }) => {
  const si = `${b64(header)}.${b64(claims)}`;
  return `${si}.${sign("RSA-SHA256", Buffer.from(si), privateKey).toString("base64url")}`;
};
const keyFor = async (kid: string) => (kid === "k1" ? jwk : undefined);
const opts = { notBefore: (now - 10) * 1000, keyFor };

// --- ID token validation ---
assert.equal((await verifyIdToken(jwt(good), opts)).sub, "alice-sub");
const bad: [string, string][] = [
  [jwt({ ...good, iss: "https://evil.example" }), "wrong issuer"],
  [jwt({ ...good, aud: "other-client" }), "wrong audience"],
  [jwt({ ...good, aud: ["client-test", "other"] }), "wrong audience"],
  [jwt({ ...good, exp: now - 1 }), "expired"],
  [jwt({ ...good, auth_time: now - 60 }), "not fresh"], // proof from before this attempt started
  [jwt({ ...good, auth_time: now + 3600 }), "future"],
  [jwt({ ...good, acr: "urn:weak" }), "acr"],
  [jwt({ ...good, sub: "" }), "sub"],
  [jwt(good, { alg: "RS256", kid: "unknown" }), "signing key"],
  [jwt(good, { alg: "none", kid: "k1" }), "RS256"],
  [jwt(good).replace(/\.[^.]+\./, `.${b64({ ...good, sub: "mallory" })}.`), "signature"], // tampered payload
];
for (const [t, why] of bad) await assert.rejects(verifyIdToken(t, opts), new RegExp(why), why);
const ec = { ...generateKeyPairSync("ec", { namedCurve: "P-256" }).publicKey.export({ format: "jwk" }), kid: "k1" };
await assert.rejects(verifyIdToken(jwt(good), { ...opts, keyFor: async () => ec }), /signing key/); // no alg confusion

// --- device grant against a fake IdP (also exercises discovery + JWKS fetch) ---
let tokenReplies: [number, object][] = [];
let tokenCalls = 0;
let codeGrant: URLSearchParams | undefined; // last authorization_code request
let codeClaims: object = {}; // claims the fake IdP puts in the next code-grant ID token
const reply = (status: number, body: object) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const realFetch = globalThis.fetch;
globalThis.fetch = (async (input: any, init?: any) => {
  const url = String(input);
  if (url.startsWith("http://127.0.0.1:")) return realFetch(input, init); // the Proviso API under test
  if (url.endsWith("/.well-known/openid-configuration")) {
    return reply(200, { issuer: ISS, jwks_uri: `${ISS}/jwks`, authorization_endpoint: `${ISS}/authorize`, token_endpoint: `${ISS}/token`, device_authorization_endpoint: `${ISS}/device` });
  }
  if (url === `${ISS}/jwks`) return reply(200, { keys: [jwk] });
  const body = new URLSearchParams(init.body);
  assert.equal(init.headers.authorization, `Basic ${Buffer.from("client-test:secret-test").toString("base64")}`); // client_secret_basic
  assert.equal(body.get("client_secret"), null); // never mixed with post

  if (url === `${ISS}/device`) {
    assert.equal(body.get("scope"), "openid");
    return reply(200, { device_code: "dev-secret", user_code: "ABCD-EFGH", verification_uri: `${ISS}/device`, verification_uri_complete: `${ISS}/device?user_code=ABCD-EFGH`, expires_in: 1200, interval: 0 });
  }
  if (body.get("grant_type") === "authorization_code") {
    codeGrant = body;
    return reply(200, { id_token: jwt({ ...fresh(), ...codeClaims }), access_token: "x", token_type: "Bearer", expires_in: 300 });
  }
  assert.equal(body.get("device_code"), "dev-secret");
  tokenCalls++;
  const [s, b] = tokenReplies.shift()!;
  return reply(s, b);
}) as typeof fetch;

const fresh = () => ({ ...good, auth_time: Math.floor(Date.now() / 1000) });
let d = await startDevice();
assert.equal(d.approvalUrl, `${ISS}/device?user_code=ABCD-EFGH`);
tokenReplies = [[400, { error: "authorization_pending" }], [400, { error: "slow_down" }]];
assert.equal((await pollDevice(d)).status, "pending");
assert.equal((await pollDevice(d)).status, "pending"); // slow_down: interval 0 -> 5 s
assert.equal(d.interval, 5);
assert.equal((await pollDevice(d)).status, "pending"); // too early: no request sent
assert.equal(tokenCalls, 2);
d.nextPoll = 0;
tokenReplies = [[200, { id_token: jwt(fresh()), access_token: "x", token_type: "Bearer", expires_in: 300 }]];
const [r1, r2] = await Promise.all([pollDevice(d), pollDevice(d)]); // concurrent reads share one redemption
assert.equal(tokenCalls, 3);
assert.deepEqual(r1, r2);
assert.equal(r1.status === "ok" && r1.sub, "alice-sub");
assert.equal((await pollDevice(d)).status, "ok"); // cached, no replay

for (const [status, body, want] of [
  [400, { error: "access_denied" }, "denied"],
  [400, { error: "expired_token" }, "expired"],
  [400, { error: "invalid_grant" }, "error"],
  [503, {}, "error"],
  [200, { id_token: jwt({ ...good, auth_time: now - 3600 }) }, "error"], // stale proof is not an approval
] as const) {
  d = await startDevice();
  d.nextPoll = 0;
  tokenReplies = [[status, body]];
  assert.equal((await pollDevice(d)).status, want, JSON.stringify(body));
}
d = await startDevice();
d.expiresAt = Date.now() - 1;
assert.equal((await pollDevice(d)).status, "expired");

// --- Sign in with World ID: authorization code + S256 PKCE ---
assert.equal(pkceChallenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"); // RFC 7636 App. B
const CB = "https://proviso.test/auth/world/callback";
let u = new URL(await loginUrl(CB));
const p = Object.fromEntries(u.searchParams);
assert.equal(`${u.origin}${u.pathname}`, `${ISS}/authorize`);
assert.deepEqual(
  { ...p, state: undefined, nonce: undefined, code_challenge: undefined },
  { client_id: "client-test", redirect_uri: CB, response_type: "code", scope: "openid", code_challenge_method: "S256", acr_values: ACR, state: undefined, nonce: undefined, code_challenge: undefined },
);
let att = takeLogin(p.state)!;
assert.equal(pkceChallenge(att.verifier), p.code_challenge); // verifier stays server-side, challenge matches it
assert.equal(att.nonce, p.nonce);
assert.equal(takeLogin(p.state), undefined); // state is single-use
codeClaims = { nonce: att.nonce };
assert.equal((await redeemLogin(att, "code-1", CB)).sub, "alice-sub");
assert.equal(codeGrant!.get("code_verifier"), att.verifier);
assert.equal(codeGrant!.get("redirect_uri"), CB);
codeClaims = { nonce: "someone-elses-nonce" };
await assert.rejects(redeemLogin(att, "code-2", CB), /nonce mismatch/);
codeClaims = {}; // nonce missing from the token
await assert.rejects(redeemLogin(att, "code-3", CB), /nonce mismatch/);

// --- the same flow over HTTP, plus the session middleware (temp state dir: never touches the real accounts/sessions files) ---
process.env.PROVISO_STATE_DIR = mkdtempSync(join(tmpdir(), "proviso-check-"));
writeFileSync(join(process.env.PROVISO_STATE_DIR, ".world-owner.json"), JSON.stringify({ iss: ISS, sub: "legacy-sub" })); // pre-accounts single owner
process.env.PUBLIC_URL = "https://proviso.test/";
delete process.env.PROVISO_REQUIRE_LOGIN;
process.env.MERCHANT_PRIVATE_KEY = generatePrivateKey();
const MERCHANT = privateKeyToAccount(process.env.MERCHANT_PRIVATE_KEY as `0x${string}`).address;
process.env.MERCHANT_ADDRESS = MERCHANT;
const { mountProviso, demoPrice, timeline, saveState, loadState } = await import("./proviso.js");
const { default: express } = await import("express");
const app = express();
app.use(express.json());
mountProviso(app, { searchProducts: async () => [] } as any); // offline: no live listings

// --- Monid listings: map both sources, drop used/rental/pawn/foreign-currency/accessory rows, dedupe, rank, one row per store ---
const { fromGoogle, fromAmazon, rank, perStore } = await import("./monid.js");
const g = fromGoogle([
  { title: "Sony PlayStation 5 Console Digital Edition", price: "$455.00", extracted_price: 455, extracted_old_price: 599, source: "King of Hobby Deals",
    product_link: "https://www.google.com/search?ibp=oshop", thumbnail: "https://t/1", rating: 4.5, gpcid: "1", litescrape_product_link: { queryParams: { gpcid: "1", q: "ps5" } } },
  { title: "Sony PlayStation 5 Console Digital Edition", price: "$470.00", extracted_price: 470, source: "King of Hobby Deals", gpcid: "2" }, // same title+store, dearer
  { title: "Certified Refurbished PlayStation 5 Console", price: "$399.00", extracted_price: 399, source: "PlayStation", second_hand_condition: "refurbished" },
  { title: "Sony PlayStation 5 Pro Console - 2TB", price: "$35.99", extracted_price: 35.99, source: "Rent-A-Center" }, // weekly rent-to-own
  { title: "Sony PlayStation 5 Slim Digital Console", price: "$389.99", extracted_price: 389.99, source: "Pawn America" },
  { title: "Sony PS5 PlayStation Console", price: "(£315)", extracted_price: 315, source: "mcgrocer.com" }, // not USD
  { title: "DualSense Controller for PlayStation 5 console", price: "$59.00", extracted_price: 59, source: "Walmart" }, // accessory: under the floor
  { title: "Xbox Series X", price: "$499.00", extracted_price: 499, source: "Best Buy" }, // not the query
]);
const amz = fromAmazon([
  { asin: "B0FRGMYJMG", productDescription: "PlayStation 5 Digital Edition", price: 0 }, // no buy box
  { asin: "B0CL5KNB9M", productDescription: "PlayStation 5 Console Digital Edition Slim", price: 449, retailPrice: 499.99, productRating: "4.7 out of 5 stars", countReview: 5701, imgUrl: "https://i/2" },
]);
const ranked = rank("PlayStation 5 console", [...g, ...amz], 200, 600);
assert.deepEqual(ranked.map((o) => [o.store, o.source, o.priceMinor]), [["King of Hobby Deals", "google_shopping", 45500], ["Amazon", "amazon", 44900]]); // relevance order
assert.deepEqual([ranked[0].listMinor, ranked[0].product?.gpcid, ranked[0].merchant], [59900, "1", "https://www.google.com"]);
assert.deepEqual([ranked[1].url, ranked[1].merchant, ranked[1].listMinor, ranked[1].rating], ["https://www.amazon.com/dp/B0CL5KNB9M", "https://www.amazon.com", 49999, 4.7]);
assert.deepEqual(rank("Sony 55 inch 4K TV", fromGoogle([{ title: 'Samsung 55" Class 4K Smart TV', extracted_price: 400, source: "Best Buy" }, { title: "Sony BRAVIA 2 II 4K HDR LED Google TV", extracted_price: 600, source: "Best Buy" },
  { title: "BRAVIA 2 II 43” Class 4K HDR LED Google TV", extracted_price: 400, source: "Sony" }, { title: 'Sony - 55" Class BRAVIA 2 II 4K TV', extracted_price: 599, source: "Best Buy" }]))
  .map((o) => o.title), ["Sony BRAVIA 2 II 4K HDR LED Google TV", 'Sony - 55" Class BRAVIA 2 II 4K TV']); // brand must match; a size, if named, too
const row = (store: string, priceMinor: number) => ({ ...ranked[0], store, priceMinor });
assert.deepEqual(perStore([row("Walmart", 64900), row("Walmart - The Game Brain", 56999), row("gamestop.com", 54999), row("GameStop", 58999), row("Best Buy", 64999)])
  .map((o) => [o.store, o.priceMinor]), [["gamestop.com", 54999], ["Walmart - The Game Brain", 56999], ["Best Buy", 64999]]);
const srv = app.listen(0, "127.0.0.1");
await once(srv, "listening");
const base = `http://127.0.0.1:${(srv.address() as any).port}`;
const get = (path: string, token?: string, method = "GET") =>
  fetch(base + path, { method, redirect: "manual", headers: token ? { authorization: `Bearer ${token}` } : {} });
const post = (path: string, token: string | undefined, body: object, method = "POST") =>
  fetch(base + path, { method, headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) });
const start = async () => {
  const r = await get("/auth/world/start?return=proviso");
  assert.equal(r.status, 302);
  return new URL(r.headers.get("location")!).searchParams;
};
const callback = async (q: Record<string, string>) => {
  const r = await get(`/auth/world/callback?${new URLSearchParams(q)}`);
  assert.equal(r.status, 302);
  const to = new URL(r.headers.get("location")!);
  assert.equal(`${to.protocol}//${to.host}`, "proviso://auth");
  return Object.fromEntries(to.searchParams);
};

let sp = await start();
assert.equal(sp.get("redirect_uri"), CB);
codeClaims = { nonce: "wrong" };
assert.deepEqual(await callback({ code: "c", state: sp.get("state")! }), { error: "invalid_id_token" }); // nonce mismatch
assert.deepEqual(await callback({ code: "c", state: sp.get("state")! }), { error: "invalid_state" }); // replayed state
sp = await start();
assert.deepEqual(await callback({ error: "access_denied", state: sp.get("state")! }), { error: "access_denied" });
assert.deepEqual(await callback({ code: "c", state: sp.get("state")! }), { error: "invalid_state" }); // consumed by the error
sp = await start();
codeClaims = { nonce: sp.get("nonce") };
const { session } = await callback({ code: "c", state: sp.get("state")! }); // sign-in creates alice's account
assert.match(session, /^[A-Za-z0-9_-]{43}$/);
const stateDir = process.env.PROVISO_STATE_DIR;
const accts = JSON.parse(readFileSync(join(stateDir, ".accounts.json"), "utf8"));
assert.equal(accts[`${ISS}|alice-sub`].mode, "none");
assert.equal(accts[`${ISS}|legacy-sub`].mode, "demo"); // migrated owner keeps the demo wallet
assert.ok(!readFileSync(join(stateDir, ".sessions.json"), "utf8").includes(session)); // only the hash is stored
sp = await start();
codeClaims = { nonce: sp.get("nonce"), sub: "mallory-sub" };
const { session: mallory } = await callback({ code: "c", state: sp.get("state")! }); // any World ID signs in, to its own account
assert.match(mallory, /^[A-Za-z0-9_-]{43}$/);

let r = await get("/api/budgets");
assert.equal(r.status, 401);
assert.deepEqual(await r.json(), { error: "sign_in_required" });
assert.equal((await get("/api/me", "not-a-session")).status, 401);
r = await get("/api/me", session);
assert.equal(r.status, 200);
const me = await r.json();
assert.equal(me.signedIn, true);
assert.equal(me.worldLinked, true);
assert.equal(me.acr, ACR);
assert.match(me.sub, /^[0-9a-f]{12}$/); // short hash, never the raw pairwise sub
assert.equal(me.walletStatus, "none");

// requests are per account: the second World ID sees none of the first one's
const draft = { title: "Lego set", query: "lego", category: "Hobby", autoUsd: 100, maxUsd: 200, deadline: new Date(Date.now() + 30 * 86_400_000).toISOString() };
const req1 = await (await post("/api/requests", session, draft)).json();
assert.equal(req1.acct, undefined); // internal owner/context fields never leave the backend
assert.equal(req1.ctx, undefined);
assert.deepEqual((await (await get("/api/requests", session)).json()).map((x: any) => x.id), [req1.id]);
assert.deepEqual(await (await get("/api/requests", mallory)).json(), []);
assert.equal((await get(`/api/requests/${req1.id}`, mallory)).status, 404);
assert.equal((await post(`/api/requests/${req1.id}/price`, mallory, { price: 1 })).status, 404);
// double taps: an identical draft from the same account (concurrent, or within 60 s) is the same request; another account gets its own
const dup = await Promise.all([session, session, mallory].map(async (t) => (await (await post("/api/requests", t, draft)).json()).id));
assert.deepEqual(dup.slice(0, 2), [req1.id, req1.id]);
assert.notEqual(dup[2], req1.id);
assert.deepEqual((await (await get("/api/requests", session)).json()).map((x: any) => x.id), [req1.id]);

// hidden demo lever: band math lands every scenario in its own band
for (const [cur, auto, max] of [[439, 400, 500], [210, 100, 200], [80, 100, 200], [12, 10, 11], [5, 1, 3], [400.5, 400, 401]]) {
  const a = demoPrice("auto", cur, auto, max)!, ap = demoPrice("approval", cur, auto, max)!, b = demoPrice("blocked", cur, auto, max)!;
  assert.ok(a > 0 && a <= auto && a >= auto / 2 && a <= cur, `auto ${a} for ${cur}/${auto}/${max}`);
  assert.ok(ap > auto && ap <= max, `approval ${ap} for ${auto}/${max}`);
  assert.ok(b > max && b <= max * 1.1 + 1, `blocked ${b} for ${max}`);
  assert.equal(demoPrice("attack", cur, auto, max), a);
}
assert.equal(demoPrice("auto", 439, 400, 500), 379.99);
assert.equal(demoPrice("approval", 439, 400, 500), 449.99);
assert.equal(demoPrice("blocked", 439, 400, 500), 539.99);
assert.equal(demoPrice("approval", 100, 100, 100), undefined); // no approval band
// ... and over HTTP (no chain here): auto buys, attack + blocked keep watching, approval asks World ID, reset reruns
const demo = async (scenario: string, token = session) => {
  const r = await post(`/api/requests/${req1.id}/demo`, token, { scenario });
  return { status: r.status, body: await r.json().catch(() => undefined) };
};
const last = (x: any) => x.activity.at(-1);
assert.equal((await demo("auto", mallory)).status, 404);
assert.equal((await demo("nope")).status, 400);
assert.equal((await demo("recheck")).status, 400); // no live listing to re-check
assert.equal(req1.historyModeled, true);
let dr = await demo("blocked");
assert.deepEqual([dr.body.status, dr.body.currentPrice, last(dr.body).blocked], ["watching", 215.99, true]);
assert.equal(dr.body.priceHistory.at(-1).price, 215.99);
assert.match(dr.body.strategy.bullets.at(-1), /Above your \$200 max/);
dr = await demo("attack");
assert.equal(dr.body.status, "watching");
assert.equal(last(dr.body).text, "Prompt-injected checkout tried to pay 0x…bad1 — blocked by the contract (UnverifiedMerchant) (demo, no chain)");
assert.equal(last(dr.body).blocked, true);
dr = await demo("auto");
assert.equal(dr.body.status, "bought");
assert.ok(dr.body.currentPrice <= 100);
// Proviso Demo Merchant: a simulated order with a real EIP-712 receipt signed by the merchant key
const ord = dr.body.order;
assert.match(ord.id, /^PV-[0-9A-F]{8}$/);
assert.deepEqual([ord.status, ord.simulated, ord.merchantName, ord.registry, ord.merchantVerified, ord.humanApproved, ord.priceUsd, ord.txHash],
  ["paid", true, "Proviso Demo Merchant", "verified.proviso.eth", false, false, dr.body.currentPrice, undefined]); // no chain: nothing verified, no tx
assert.equal(ord.merchantAddress, MERCHANT);
assert.equal(ord.id, `PV-${ord.orderHash.slice(2, 10).toUpperCase()}`);
assert.match(ord.paidAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/); // iso, no millis
assert.deepEqual(ord.timeline.map((t: any) => [t.status, t.done]), [["paid", true], ["confirmed", false], ["shipped", false], ["delivered", false]]);
const td = ord.typedData;
assert.deepEqual(td.domain, { name: "Proviso Demo Merchant", version: "1", chainId: 11155111 });
assert.equal(td.message.amount, String(Math.round(ord.priceUsd * 1e6))); // bigints travel as strings
const signed = { ...td, message: { ...td.message, amount: BigInt(td.message.amount), paidAt: BigInt(td.message.paidAt) }, signature: ord.signature };
assert.ok(await verifyTypedData({ address: MERCHANT, ...signed }));
assert.equal(await recoverTypedDataAddress(signed), MERCHANT);
assert.equal(await verifyTypedData({ address: MERCHANT, ...signed, message: { ...signed.message, amount: 1n } }), false); // tampered amount
assert.equal(last(dr.body).text, `Order ${ord.id} confirmed by Proviso Demo Merchant (simulated fulfilment)`);
assert.equal(dr.body.activity.filter((a: any) => a.text.startsWith("Bought")).length, 1); // e2e-wallet.sh parses this line
assert.deepEqual(await (await get(`/merchant/orders/${ord.id}`)).json(), ord); // public, no session
assert.equal((await (await get("/merchant/orders")).json())[0].id, ord.id);
assert.equal((await get("/merchant/orders/PV-00000000")).status, 404);
// demo clock: paid 0 s, confirmed 5 s, shipped 20 s, delivered 45 s
const t0 = Date.UTC(2026, 8, 27, 0, 0, 0);
const at = (ms: number) => timeline(t0, t0 + ms).filter((t) => t.done).at(-1)!.status;
assert.deepEqual([at(0), at(4999), at(5000), at(19_999), at(20_000), at(44_999), at(45_000), at(9e9)], ["paid", "paid", "confirmed", "confirmed", "shipped", "shipped", "delivered", "delivered"]);
assert.deepEqual(timeline(t0, t0).map((t) => t.at), ["2026-09-27T00:00:00Z", "2026-09-27T00:00:05Z", "2026-09-27T00:00:20Z", "2026-09-27T00:00:45Z"]);
assert.deepEqual(await demo("approval"), { status: 409, body: { error: "not_watching" } });
dr = await demo("reset");
assert.deepEqual([dr.body.status, dr.body.currentPrice], ["watching", 210]); // back to the pre-demo price
dr = await demo("approval");
assert.deepEqual([dr.body.status, dr.body.currentPrice], ["needsApproval", 149.99]);
assert.match(last(dr.body).text, /code ABCD-EFGH/);
tokenReplies = [[400, { error: "authorization_pending" }]];
assert.equal((await (await get("/api/approvals", session)).json()).filter((a: any) => a.requestId === req1.id && a.status === "pending").length, 1);
// persistence round-trip (a backend restart): requests + orders come back, a pending World ID approval comes back expired, no device code on disk
saveState();
const onDisk = readFileSync(join(stateDir, ".state.json"), "utf8");
assert.ok(onDisk.includes(ord.id) && !onDisk.includes("dev-secret"));
loadState();
const strip = (o: any) => ({ ...o, status: undefined, timeline: undefined });
assert.deepEqual(strip(await (await get(`/merchant/orders/${ord.id}`)).json()), strip(ord));
const reloaded = await (await get(`/api/requests/${req1.id}`, session)).json();
assert.deepEqual([reloaded.status, reloaded.currentPrice, reloaded.ensName], ["watching", 149.99, req1.ensName]);
assert.match(last(reloaded).text, /backend restarted/);
assert.deepEqual((await (await get("/api/approvals", session)).json()).map((a: any) => a.status), ["expired"]);
dr = await demo("reset");
assert.equal(dr.body.status, "watching");
assert.equal((await (await get("/api/approvals", session)).json()).filter((a: any) => a.status === "pending").length, 0);

// wallet onboarding: budgets stay editable until the user's resolver exists; handle rules; token-gated page API
assert.equal((await post("/api/budgets/Hobby", mallory, { limitUsd: 1500 }, "PUT")).status, 200);
assert.equal((await post("/api/budgets/Hobby", mallory, { limitUsd: -1 }, "PUT")).status, 400);
assert.equal((await post("/api/budgets/constructor", mallory, { limitUsd: 5 }, "PUT")).status, 404);
assert.deepEqual((await (await get("/api/budgets", mallory)).json()).categories.map((c: any) => [c.name, c.limitUsd]), [["Hobby", 1500], ["Needs", 3000]]);
assert.deepEqual((await (await get("/api/budgets", session)).json()).categories.map((c: any) => c.limitUsd), [1000, 3000]); // alice unaffected
for (const handle of ["Bad Handle", "hobby", "ab", 7]) assert.equal((await post("/api/wallet/start", mallory, { handle })).status, 400);
assert.equal((await post("/api/wallet/start", mallory, { limits: { toString: 5 } })).status, 400);
const ws = await (await post("/api/wallet/start", mallory, { handle: "mallory" })).json();
const tok = new URL(ws.pageUrl).pathname.split("/").pop();
assert.deepEqual(ws, { url: `https://link.metamask.io/dapp/proviso.test/w/${tok}`, pageUrl: `https://proviso.test/w/${tok}`, ensName: "mallory.proviso.eth" });
assert.match((await get(`/w/${tok}`)).headers.get("content-type")!, /^text\/html/);
assert.deepEqual(await (await get(`/w/${tok}/status`)).json(),
  { signed: false, done: { resolver: false, name: false, account: false }, ready: false, ensName: "mallory.proviso.eth", address: "", txs: [] });
assert.equal((await get("/w/not-a-token/status")).status, 404);
assert.equal((await post(`/w/${tok}/connect`, undefined, { address: "0x0000000000000000000000000000000000000001" })).status, 503); // no chain here
assert.equal((await post(`/w/${tok}/permit`, undefined, { signature: "0x" + "11".repeat(65) })).status, 503);
assert.equal((await (await post("/api/wallet/demo", mallory, {})).json()).walletStatus, "demo");
// "Reset & start over": own account only, files only here (no chain); the session ends with it
process.env.PROVISO_ALLOW_RESET = "0";
assert.equal((await post("/api/dev/reset", mallory, {})).status, 403);
delete process.env.PROVISO_ALLOW_RESET;
assert.equal((await post("/api/dev/reset", undefined, {})).status, 401);
assert.deepEqual(await (await post("/api/dev/reset", mallory, {})).json(), { ok: true, reset: { chain: false, ens: null, requests: 1, orders: 0, txs: [] } });
assert.equal((await get("/api/me", mallory)).status, 401);
assert.equal(JSON.parse(readFileSync(join(stateDir, ".accounts.json"), "utf8"))[`${ISS}|mallory-sub`], undefined);
assert.ok(!readFileSync(join(stateDir, ".state.json"), "utf8").includes(dup[2]));
assert.deepEqual((await (await get("/api/requests", session)).json()).map((x: any) => x.id), [req1.id]); // other accounts untouched
const { mergeDraft, statusLine, draftProblem } = await import("./proviso.js");
const okDraft = { title: "TV", category: "Hobby", autoUsd: 400, maxUsd: 500, deadline: new Date(Date.now() + 86_400_000).toISOString() };
assert.equal(draftProblem(okDraft), undefined);
assert.match(draftProblem({ ...okDraft, autoUsd: 600 })!, /can't be above/);
assert.match(draftProblem({ ...okDraft, deadline: "2020-01-01T00:00:00Z" })!, /future/);
assert.match(draftProblem({ ...okDraft, category: "Toys" })!, /Hobby or Needs/);
const sr = { status: "watching", currentPrice: 170, autoUsd: 150, activity: [] as any[] } as any;
assert.equal(statusLine(sr), "watching: $170 now, buys on its own at $150 or less");
assert.equal(statusLine({ ...sr, activity: [{ text: "Above your $300 max at $320 — not bought", blocked: true }] }), "watching; last attempt blocked: Above your $300 max at $320 — not bought");
assert.equal(statusLine({ ...sr, status: "needsApproval", currentPrice: 199 }), "needs approval: $199 is above auto $150, waiting for the owner's World ID");
assert.equal(statusLine({ ...sr, status: "bought", boughtPrice: 149, orderId: "PV-1A2B3C4D" }), "bought for $149, order PV-1A2B3C4D");
const h0 = { title: "Tv", query: "tv", category: "Hobby", autoUsd: 400, maxUsd: 500, deadline: "2026-10-27T00:00:00Z" };
const m0 = mergeDraft(h0, { title: "Sony TV", autoUsd: null, maxUsd: "600", category: "needs", deadlineDays: null });
assert.deepEqual([m0.title, m0.autoUsd, m0.maxUsd, m0.category, m0.deadline], ["Sony TV", 480, 600, "Needs", h0.deadline]);
assert.equal(mergeDraft(h0, { autoUsd: 900, maxUsd: 500 }).autoUsd, 500); // auto never above max
assert.deepEqual(mergeDraft(h0, undefined), h0);
const { resetTarget } = await import("./proviso.js");
await assert.rejects(resetTarget("nobody"), /no account matches/);
assert.equal((await get("/api/logout", session, "POST")).status, 200);
assert.equal((await get("/api/me", session)).status, 401); // logged out
process.env.PROVISO_REQUIRE_LOGIN = "0";
r = await get("/api/me");
assert.equal(r.status, 200);
const anon = await r.json();
assert.equal(anon.signedIn, false);
assert.equal(anon.walletStatus, "demo");
srv.close();
srv.closeAllConnections();

// --- EIP-712 digest == PolicySpender.approvalDigest (test_approvalDigestMatchesBackend) ---
const cont = keccak256(stringToBytes(`${ISS}|alice-pairwise-sub`));
assert.equal(
  hashTypedData(approvalTypedData("0x000000000000000000000000000000000000bEEF", 31337, keccak256(stringToBytes("order")), cont, 1790000000n)),
  "0xae622ad70332e73a8e692898629dbd94b2fed8db702988a0cfef992aed58da55"
);
console.log("worldid + sign-in check: ok");
