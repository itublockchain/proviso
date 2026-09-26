// Self-check for worldid.ts + Sign in with World ID (no network): `npx tsx check.ts`
// RS256 ID token validation against a local RSA key, the device-grant state machine against a fake IdP,
// the authorization-code + PKCE login and session middleware against the same fake IdP,
// and the EIP-712 HumanApproval digest against the constant PolicySpender's forge test asserts.
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { once } from "node:events";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hashTypedData, keccak256, stringToBytes } from "viem";

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
  if (url.startsWith("http://127.0.0.1:")) return realFetch(input, init); // the Hero API under test
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
const CB = "https://hero.test/auth/world/callback";
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

// --- the same flow over HTTP, plus the session middleware (temp state dir: never touches the real owner/sessions files) ---
process.env.HERO_STATE_DIR = mkdtempSync(join(tmpdir(), "hero-check-"));
process.env.PUBLIC_URL = "https://hero.test/";
delete process.env.HERO_REQUIRE_LOGIN;
const { mountHero } = await import("./hero.js");
const { default: express } = await import("express");
const app = express();
app.use(express.json());
mountHero(app, {} as any);
const srv = app.listen(0, "127.0.0.1");
await once(srv, "listening");
const base = `http://127.0.0.1:${(srv.address() as any).port}`;
const get = (path: string, token?: string, method = "GET") =>
  fetch(base + path, { method, redirect: "manual", headers: token ? { authorization: `Bearer ${token}` } : {} });
const start = async () => {
  const r = await get("/auth/world/start?return=hero");
  assert.equal(r.status, 302);
  return new URL(r.headers.get("location")!).searchParams;
};
const callback = async (q: Record<string, string>) => {
  const r = await get(`/auth/world/callback?${new URLSearchParams(q)}`);
  assert.equal(r.status, 302);
  const to = new URL(r.headers.get("location")!);
  assert.equal(`${to.protocol}//${to.host}`, "hero://auth");
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
const { session } = await callback({ code: "c", state: sp.get("state")! }); // first sign-in links the owner
assert.match(session, /^[A-Za-z0-9_-]{43}$/);
const stateDir = process.env.HERO_STATE_DIR;
assert.equal(JSON.parse(readFileSync(join(stateDir, ".world-owner.json"), "utf8")).sub, "alice-sub");
assert.ok(!readFileSync(join(stateDir, ".sessions.json"), "utf8").includes(session)); // only the hash is stored
sp = await start();
codeClaims = { nonce: sp.get("nonce"), sub: "mallory-sub" };
assert.deepEqual(await callback({ code: "c", state: sp.get("state")! }), { error: "not_owner" });

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
assert.equal((await get("/api/logout", session, "POST")).status, 200);
assert.equal((await get("/api/me", session)).status, 401); // logged out
process.env.HERO_REQUIRE_LOGIN = "0";
r = await get("/api/me");
assert.equal(r.status, 200);
assert.equal((await r.json()).signedIn, false);
srv.close();
srv.closeAllConnections();

// --- EIP-712 digest == PolicySpender.approvalDigest (test_approvalDigestMatchesBackend) ---
const cont = keccak256(stringToBytes(`${ISS}|alice-pairwise-sub`));
assert.equal(
  hashTypedData(approvalTypedData("0x000000000000000000000000000000000000bEEF", 31337, keccak256(stringToBytes("order")), cont, 1790000000n)),
  "0xae622ad70332e73a8e692898629dbd94b2fed8db702988a0cfef992aed58da55"
);
console.log("worldid + sign-in check: ok");
