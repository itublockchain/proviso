// Self-check for worldid.ts (no network): `npx tsx check.ts`
// RS256 ID token validation against a local RSA key, the device-grant state machine against a fake IdP,
// and the EIP-712 HumanApproval digest against the constant PolicySpender's forge test asserts.
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { hashTypedData, keccak256, stringToBytes } from "viem";

const ISS = "https://sandbox.auth.world.org";
process.env.WORLD_OIDC_ISSUER = ISS;
process.env.WORLD_OIDC_CLIENT_ID = "client-test";
process.env.WORLD_OIDC_CLIENT_SECRET = "secret-test";
const { verifyIdToken, startDevice, pollDevice, approvalTypedData, ACR } = await import("./worldid.js");

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
const reply = (status: number, body: object) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
globalThis.fetch = (async (input: any, init?: any) => {
  const url = String(input);
  if (url.endsWith("/.well-known/openid-configuration")) {
    return reply(200, { issuer: ISS, jwks_uri: `${ISS}/jwks`, token_endpoint: `${ISS}/token`, device_authorization_endpoint: `${ISS}/device` });
  }
  if (url === `${ISS}/jwks`) return reply(200, { keys: [jwk] });
  const body = new URLSearchParams(init.body);
  assert.equal(body.get("client_secret"), "secret-test"); // client_secret_post
  assert.equal(init.headers.authorization, undefined);
  if (url === `${ISS}/device`) {
    assert.equal(body.get("scope"), "openid");
    return reply(200, { device_code: "dev-secret", user_code: "ABCD-EFGH", verification_uri: `${ISS}/device`, verification_uri_complete: `${ISS}/device?user_code=ABCD-EFGH`, expires_in: 1200, interval: 0 });
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

// --- EIP-712 digest == PolicySpender.approvalDigest (test_approvalDigestMatchesBackend) ---
const cont = keccak256(stringToBytes(`${ISS}|alice-pairwise-sub`));
assert.equal(
  hashTypedData(approvalTypedData("0x000000000000000000000000000000000000bEEF", 31337, keccak256(stringToBytes("order")), cont, 1790000000n)),
  "0xae622ad70332e73a8e692898629dbd94b2fed8db702988a0cfef992aed58da55"
);
console.log("worldid check: ok");
