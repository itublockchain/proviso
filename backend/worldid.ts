// World ID for Agents (sandbox OIDC IdP): confidential-client device grant + ID token validation, all server-side.
// Device codes, tokens and the client secret never leave this process and are never logged.
import { createPublicKey, verify } from "node:crypto";
import type { Hex } from "viem";

export const ACR = "https://world.org/oidc/acr/orb-v3";
export const OIDC = {
  issuer: (process.env.WORLD_OIDC_ISSUER || "https://sandbox.auth.world.org").replace(/\/$/, ""),
  clientId: process.env.WORLD_OIDC_CLIENT_ID ?? "",
  secret: process.env.WORLD_OIDC_CLIENT_SECRET ?? "",
  // must match the method registered in the portal (immutable); the portal default is client_secret_basic
  auth: process.env.WORLD_OIDC_TOKEN_AUTH_METHOD === "client_secret_post" ? "client_secret_post" : "client_secret_basic",
};
export const oidcEnabled = () => !!(OIDC.clientId && OIDC.secret);

const getJson = async (url: string) => {
  const r = await fetch(url, { signal: AbortSignal.timeout(10_000) });
  if (!r.ok) throw new Error(`${new URL(url).pathname}: HTTP ${r.status}`);
  return r.json() as Promise<any>;
};

let disco: Promise<any> | undefined;
const discovery = () =>
  (disco ??= getJson(`${OIDC.issuer}/.well-known/openid-configuration`).then((d) => {
    if (d.issuer !== OIDC.issuer) throw new Error("discovery issuer mismatch");
    return d;
  }).catch((e) => { disco = undefined; throw e; }));

let jwks: { keys: any[]; at: number } | undefined;
/** JWKS key by kid; refetches on an unknown kid (key rotation), at most every 30 s. */
async function signingKey(kid: string) {
  const find = () => jwks?.keys.find((k) => k.kid === kid);
  if (!find() && (!jwks || Date.now() - jwks.at > 30_000)) {
    jwks = { keys: (await getJson((await discovery()).jwks_uri)).keys ?? [], at: Date.now() };
  }
  return find();
}

export type Claims = { iss: string; sub: string; aud: string | string[]; exp: number; auth_time: number; acr?: string };

/** Full ID token validation: RS256 signature via JWKS, exact iss, aud, exp, fresh auth_time for this attempt, acr. */
export async function verifyIdToken(jwt: string, o: { notBefore: number; now?: number; keyFor?: (kid: string) => Promise<any> }): Promise<Claims> {
  const now = (o.now ?? Date.now()) / 1000;
  const [h, p, s, extra] = jwt.split(".");
  if (!h || !p || !s || extra !== undefined) throw new Error("malformed id_token");
  const header = JSON.parse(Buffer.from(h, "base64url").toString());
  if (header.alg !== "RS256" || typeof header.kid !== "string") throw new Error("id_token must be RS256 with a kid");
  const jwk = await (o.keyFor ?? signingKey)(header.kid);
  // kty check stops algorithm confusion: an EC/oct key must never be used with this verify call
  if (jwk?.kty !== "RSA" || (jwk.alg && jwk.alg !== "RS256") || (jwk.use && jwk.use !== "sig")) throw new Error("unknown id_token signing key");
  if (!verify("RSA-SHA256", Buffer.from(`${h}.${p}`), createPublicKey({ key: jwk, format: "jwk" }), Buffer.from(s, "base64url"))) {
    throw new Error("bad id_token signature");
  }
  const c = JSON.parse(Buffer.from(p, "base64url").toString());
  const aud = [c.aud].flat();
  if (c.iss !== OIDC.issuer) throw new Error("wrong issuer");
  if (aud.length !== 1 || aud[0] !== OIDC.clientId) throw new Error("wrong audience");
  if (typeof c.exp !== "number" || now >= c.exp) throw new Error("id_token expired");
  if (typeof c.sub !== "string" || !c.sub) throw new Error("missing sub");
  if (typeof c.auth_time !== "number" || c.auth_time < o.notBefore / 1000 - 5) throw new Error("World ID proof is not fresh for this attempt");
  if (c.auth_time > now + 60) throw new Error("auth_time in the future");
  if (c.acr !== undefined && c.acr !== ACR) throw new Error("unexpected acr");
  return c;
}

export type Device = {
  deviceCode: string; // secret: stays in this process
  userCode: string;
  approvalUrl: string; // verification_uri_complete from the server, shown to the human
  startedAt: number;
  expiresAt: number;
  interval: number; // seconds
  nextPoll: number;
  result?: DeviceResult;
  inflight?: Promise<DeviceResult>;
};
export type DeviceResult =
  | { status: "pending" }
  | { status: "ok"; iss: string; sub: string; authTime: number }
  | { status: "denied" | "expired" | "error"; error: string };

const formEnc = (v: string) => encodeURIComponent(v).replace(/%20/g, "+");
/** Token-endpoint style POST with the registered client authentication (never both methods at once). */
const form = (url: string, fields: Record<string, string>) =>
  fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      ...(OIDC.auth === "client_secret_basic"
        ? { authorization: `Basic ${Buffer.from(`${formEnc(OIDC.clientId)}:${formEnc(OIDC.secret)}`).toString("base64")}` }
        : {}),
    },
    body: new URLSearchParams(OIDC.auth === "client_secret_post" ? { client_id: OIDC.clientId, client_secret: OIDC.secret, ...fields } : fields),
    signal: AbortSignal.timeout(10_000),
  });

export async function startDevice(): Promise<Device> {
  const startedAt = Date.now();
  const r = await form((await discovery()).device_authorization_endpoint, { scope: "openid" });
  const j: any = await r.json().catch(() => ({}));
  if (!r.ok || !j.device_code) throw new Error(`World ID device authorization failed: HTTP ${r.status} ${j.error ?? ""}`.trim());
  const interval = Number(j.interval ?? 5);
  return {
    deviceCode: j.device_code, userCode: j.user_code, approvalUrl: j.verification_uri_complete ?? j.verification_uri,
    startedAt, expiresAt: startedAt + Number(j.expires_in) * 1000, interval, nextPoll: startedAt + interval * 1000,
  };
}

/** Lazy poll (call on every status read): respects interval/slow_down, one request in flight, final result cached. */
export function pollDevice(d: Device): Promise<DeviceResult> {
  if (d.result) return Promise.resolve(d.result);
  return (d.inflight ??= pollOnce(d)
    .then((res) => { if (res.status !== "pending") d.result = res; return res; })
    .finally(() => { d.inflight = undefined; }));
}

async function pollOnce(d: Device): Promise<DeviceResult> {
  const now = Date.now();
  if (now >= d.expiresAt) return { status: "expired", error: "expired_token" };
  if (now < d.nextPoll) return { status: "pending" };
  d.nextPoll = now + d.interval * 1000;
  let r: Response;
  try {
    r = await form((await discovery()).token_endpoint, { grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: d.deviceCode });
  } catch {
    d.nextPoll += d.interval * 1000; // connection trouble: back off, keep the attempt
    return { status: "pending" };
  }
  const j: any = await r.json().catch(() => ({}));
  if (r.ok && j.id_token) {
    try {
      const c = await verifyIdToken(j.id_token, { notBefore: d.startedAt });
      return { status: "ok", iss: c.iss, sub: c.sub, authTime: c.auth_time };
    } catch (e: any) {
      return { status: "error", error: e.message };
    }
  }
  if (r.status === 503) return { status: "error", error: "World ID is temporarily unavailable" };
  if (j.error === "authorization_pending") return { status: "pending" };
  if (j.error === "slow_down") {
    d.interval += 5;
    d.nextPoll = Date.now() + d.interval * 1000;
    return { status: "pending" };
  }
  if (j.error === "access_denied") return { status: "denied", error: "access_denied" };
  if (j.error === "expired_token") return { status: "expired", error: "expired_token" };
  return { status: "error", error: j.error ?? `HTTP ${r.status}` }; // invalid_grant, 429, world_id_3_not_available, ...
}

/** EIP-712 HumanApproval that PolicySpender.buyApproved() checks (see approvalDigest in the contract). */
export const approvalTypedData = (verifyingContract: Hex, chainId: number, orderHash: Hex, continuity: Hex, authTime: bigint) => ({
  domain: { name: "PolicySpender", version: "1", chainId, verifyingContract },
  types: { HumanApproval: [{ name: "orderHash", type: "bytes32" }, { name: "continuity", type: "bytes32" }, { name: "authTime", type: "uint64" }] },
  primaryType: "HumanApproval" as const,
  message: { orderHash, continuity, authTime },
});
