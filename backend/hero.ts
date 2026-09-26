// Hero API for the iOS app: requests -> time-aware strategy -> ENS policy bands -> auto-buy or World-approved buy.
import type { Express, Request, Response } from "express";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import {
  createPublicClient, createWalletClient, encodeAbiParameters, encodeFunctionData, getAddress, http, keccak256, namehash, nonceManager, parseAbi,
  parseEther, stringToBytes, toHex, type Hex, type PrivateKeyAccount, type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { sepolia } from "viem/chains";
import { approvalTypedData, loginUrl, oidcEnabled, pollDevice, redeemLogin, startDevice, takeLogin, type Claims, type Device } from "./worldid.js";

type Offer = { sku: string; title: string; merchant: string; priceMinor: number; image?: string };
type Deps = {
  searchCatalog: (q: string, maxMinor?: number) => Promise<Offer[]>;
  startWorldApproval: (o: any) => Promise<void>;
  advanceWorld: (o: any) => Promise<void>;
};

const DAY = 86_400_000;
const PERIOD = 30 * DAY; // matches PolicySpender.PERIOD
const SHIPPING_DAYS = 7;
const ROOT = process.env.ENS_ROOT ?? "alice.eth";
const iso = (t: number) => new Date(t).toISOString().replace(/\.\d{3}Z$/, "Z"); // iOS .iso8601 rejects millis
const usd = (n: number) => `$${n.toFixed(0)}`;

// Sale calendar used by the strategy and the chart.
const EVENTS = [
  { date: Date.UTC(2026, 6, 15), name: "Summer sale" },
  { date: Date.UTC(2026, 8, 7), name: "Labor Day" },
  { date: Date.UTC(2026, 10, 11), name: "11.11" },
  { date: Date.UTC(2026, 10, 27), name: "Black Friday" },
  { date: Date.UTC(2026, 10, 30), name: "Cyber Monday" },
  { date: Date.UTC(2026, 11, 12), name: "12.12" },
];

type Draft = { title: string; query: string; category: string; autoUsd: number; maxUsd: number; deadline: string };
/** Whose money and policy tree a request uses: the account's own wallet + resolver, or the Hero-held demo wallet (alice). */
type Ctx = { acct?: string; demo: boolean; payer?: Hex; root: string; resolver?: Hex; continuity?: Hex };
type Req = Draft & {
  acct?: string; ctx: Ctx; // owner account key (undefined = no session) and its context when the request was made
  id: string; imageUrl?: string; ensName: string; status: "watching" | "readyToBuy" | "needsApproval" | "bought" | "expired";
  currentPrice: number; targetPrice?: number; merchant?: string; offerSku?: string; boughtAt?: number; boughtPrice?: number;
  strategy?: { summary: string; bullets: string[]; buyBy: string; confidence: number };
  priceHistory: { date: string; price: number }[]; events: { date: string; name: string }[];
  activity: { date: string; text: string; txHash?: string }[];
};
type Approval = {
  id: string; requestId: string; cartHash: Hex; order: any; price: number; status: "pending" | "approved" | "denied" | "expired" | "paid";
  expiresAt: number; txHash?: string; world?: any; connectorURI?: string; proof?: any; denyReason?: string; returnTo?: string; buying?: boolean;
  device?: Device; userCode?: string; authTime?: number; // World ID for Agents (OIDC device grant) approvals
  continuity?: Hex; // the World ID link the approval was checked against (signed into buyApproved)
  closed?: boolean; // denial/expiry already applied to the request
};

// Local state files (gitignored); HERO_STATE_DIR lets check.ts use a temp dir.
const stateFile = (name: string) => (process.env.HERO_STATE_DIR ? `${process.env.HERO_STATE_DIR}/${name}` : new URL(`./${name}`, import.meta.url));
const load = (f: string | URL) => { try { return JSON.parse(readFileSync(f, "utf8")); } catch { return undefined; } };

// One account per World ID (key `${iss}|${sub}`): "wallet" = the user's own MetaMask wallet + resolver, "demo" = the Hero-held alice wallet.
type Mode = "none" | "wallet" | "demo";
type Account = {
  key: string; iss: string; sub: string; continuity: Hex; mode: Mode;
  handle: string; root: string; wallet?: Hex; resolver?: Hex; limits: Record<string, number>;
  tokenHash?: string; tokenExp?: number; provisioned?: boolean; ready?: boolean;
};
const DEFAULT_LIMITS = { Hobby: 1000, Needs: 3000 };
const ACCOUNTS_FILE = stateFile(".accounts.json");
const accounts = new Map<string, Account>(Object.entries(load(ACCOUNTS_FILE) ?? {}));
const saveAccounts = () => writeFileSync(ACCOUNTS_FILE, JSON.stringify(Object.fromEntries(accounts)), { mode: 0o600 });

// Sign in with World ID sessions: opaque bearer tokens, only their sha256 is stored. Any World ID may sign in.
type Session = { iss: string; sub: string; createdAt: number; authTime: number; acr?: string };
const SESSIONS_FILE = stateFile(".sessions.json");
const SESSION_TTL = 7 * 86_400_000;
const sessions = new Map<string, Session>(Object.entries(load(SESSIONS_FILE) ?? {}));
const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");
const saveSessions = () => writeFileSync(SESSIONS_FILE, JSON.stringify(Object.fromEntries(sessions)), { mode: 0o600 });
const bearer = (req: Request) => /^Bearer\s+(\S+)$/i.exec(req.get("authorization") ?? "")?.[1];

function newSession(c: Claims): string {
  for (const [k, v] of sessions) if (Date.now() - v.createdAt > SESSION_TTL) sessions.delete(k);
  const token = randomBytes(32).toString("base64url");
  sessions.set(sha256(token), { iss: c.iss, sub: c.sub, createdAt: Date.now(), authTime: c.auth_time, acr: c.acr });
  saveSessions();
  return token;
}

function sessionOf(req: Request): Session | undefined {
  const t = bearer(req);
  const s = t ? sessions.get(sha256(t)) : undefined;
  if (s && Date.now() - s.createdAt <= SESSION_TTL) return s;
}

function accountFor(iss: string, sub: string, mode: Mode = "none"): Account {
  const key = `${iss}|${sub}`;
  let a = accounts.get(key);
  if (!a) {
    const handle = `u${sha256(sub).slice(0, 6)}`;
    a = { key, iss, sub, continuity: keccak256(stringToBytes(key)), mode, handle, root: `${handle}.${ROOT}`, limits: { ...DEFAULT_LIMITS } };
    accounts.set(key, a);
    saveAccounts();
  }
  return a;
}
{ // the pre-multi-account single owner keeps using the demo wallet
  const o = load(stateFile(".world-owner.json"));
  if (o?.iss && o?.sub) accountFor(o.iss, o.sub, "demo");
}
const links = new Map<string, { device: Device; status: "pending" | "linked" | "denied" | "expired"; error?: string; txHash?: Hex }>();

const requests = new Map<string, Req>();
const approvals = new Map<string, Approval>();
// the demo wallet's categories (alice's resolver, shared by every demo account); wallet accounts use Account.limits
const categories = new Map<string, { limitUsd: number; pct?: number }>(Object.entries(DEFAULT_LIMITS).map(([k, v]) => [k, { limitUsd: v }]));

// ---------- parsing (Claude if a key is set, else a small heuristic) ----------

/** Claude on Amazon Bedrock (API key auth); returns undefined when not configured so callers fall back to heuristics. */
async function claudeJson<T>(prompt: string): Promise<T | undefined> {
  const key = process.env.AWS_BEARER_TOKEN_BEDROCK;
  if (!key) return;
  const region = process.env.AWS_REGION ?? "eu-central-1";
  const model = process.env.BEDROCK_MODEL_ID ?? "eu.anthropic.claude-haiku-4-5-20251001-v1:0";
  const r = await fetch(`https://bedrock-runtime.${region}.amazonaws.com/model/${encodeURIComponent(model)}/invoke`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
    body: JSON.stringify({ anthropic_version: "bedrock-2023-05-31", max_tokens: 1024, messages: [{ role: "user", content: prompt }] }),
  }).catch((e) => void console.error("bedrock", e));
  if (!r) return;
  if (!r.ok) return void console.error("bedrock", r.status, (await r.text()).slice(0, 200));
  const text: string = (await r.json()).content?.find((c: any) => c.type === "text")?.text ?? "";
  try { return JSON.parse(text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1)); } catch { return; }
}

function heuristicDraft(msg: string): Draft {
  const amounts = [...msg.matchAll(/\$\s?([\d,]+(?:\.\d+)?)|([\d,]+)\s?(?:usd|dollars?)/gi)].map((m) => Number((m[1] ?? m[2]).replace(/,/g, "")));
  const maxUsd = amounts.length ? Math.max(...amounts) : 500;
  const autoUsd = amounts.length > 1 ? Math.min(...amounts) : Math.round(maxUsd * 0.8);
  const span = msg.match(/(\d+|a|one|two)\s*(day|week|month)s?/i);
  const n = span ? ({ a: 1, one: 1, two: 2 } as any)[span[1].toLowerCase()] ?? Number(span[1]) : 1;
  const days = span ? n * ({ day: 1, week: 7, month: 30 } as any)[span[2].toLowerCase()] : 30;
  const title = (msg.split(/[,.;]| must | within | under | never | max/i)[0] ?? msg)
    .replace(/^(i\s+(want|need|would like)|buy|get|find|grab)\s+(me\s+)?(an?|the|some)?\s*/i, "").trim().slice(0, 60) || "Item";
  const needs = /(diaper|detergent|grocer|medicine|toilet|school|baby|food|shampoo)/i.test(msg);
  return { title: title[0].toUpperCase() + title.slice(1), query: title, category: needs ? "Needs" : "Hobby", autoUsd, maxUsd, deadline: iso(Date.now() + days * DAY) };
}

async function parseDraft(msg: string): Promise<Draft> {
  const h = heuristicDraft(msg);
  const ai = await claudeJson<Partial<Draft>>(
    `Extract a purchase request as JSON {title, query (short product search query), category ("Hobby" or "Needs"), autoUsd (price the agent may buy at without asking), maxUsd (hard cap), deadlineDays}. If only a max is given, autoUsd = 80% of max. Message: ${JSON.stringify(msg)}`
  );
  if (!ai) return h;
  const days = Number((ai as any).deadlineDays);
  return { ...h, ...ai, deadline: Number.isFinite(days) && days > 0 ? iso(Date.now() + days * DAY) : h.deadline } as Draft;
}

// ---------- strategy ----------

// ponytail: seeded synthetic 90-day history (no free price-history API); swap for Keepa when there is budget.
function history(seed: string, current: number) {
  let s = parseInt(keccak256(stringToBytes(seed)).slice(2, 10), 16);
  const rand = () => ((s = (s * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
  const base = current / 1.11; // current price sits above its usual level
  const out: { date: string; price: number }[] = [];
  for (let d = 90; d >= 1; d -= 2) {
    const t = Date.now() - d * DAY;
    const dip = Math.max(0, ...EVENTS.map((e) => 1 - Math.abs(t - e.date) / (4 * DAY))) * 0.14;
    const drift = d < 14 ? (14 - d) / 14 * 0.1 : 0; // recent run-up
    out.push({ date: iso(t), price: Math.round(base * (1 - dip + drift + (rand() - 0.5) * 0.03) * 100) / 100 });
  }
  out.push({ date: iso(Date.now()), price: current });
  return out;
}

async function strategize(r: Req) {
  const prices = r.priceHistory.map((p) => p.price).sort((a, b) => a - b);
  const median = prices[Math.floor(prices.length / 2)];
  const cur = r.currentPrice;
  const buyBy = Date.parse(r.deadline) - SHIPPING_DAYS * DAY;
  const daysLeft = Math.max(0, Math.round((buyBy - Date.now()) / DAY));
  const sale = EVENTS.find((e) => e.date > Date.now() && e.date <= buyBy);
  const missed = EVENTS.find((e) => e.date > buyBy);
  const inflation = cur / median - 1;
  const target = Math.round(Math.min(r.autoUsd, sale ? median * 0.9 : median));
  const bullets = [
    `Now ${usd(cur)} vs 90-day median ${usd(median)} (${inflation >= 0 ? "+" : ""}${(inflation * 100).toFixed(0)}%).`,
    sale
      ? `${sale.name} falls before your buy-by date; past sales cut this price ~14%.`
      : missed ? `${missed.name} is after your deadline, so waiting for it is not an option.` : `No major sale before your deadline.`,
    `Must order by ${new Date(buyBy).toDateString()} (${daysLeft} days) to arrive in time (${SHIPPING_DAYS}-day shipping).`,
    cur <= r.autoUsd ? `Under your ${usd(r.autoUsd)} auto limit: buying now.`
      : cur <= r.maxUsd ? `Between auto ${usd(r.autoUsd)} and max ${usd(r.maxUsd)}: buying here needs your World ID approval.`
      : `Above your ${usd(r.maxUsd)} max: the contract will not let me buy.`,
  ];
  let summary = cur <= r.autoUsd ? "Price is inside your auto band. Buying now."
    : inflation > 0.05 ? `Price is ${(inflation * 100).toFixed(0)}% inflated. Waiting for ~${usd(target)}${sale ? ` around ${sale.name}` : ""}.`
    : "Price is fair. I will buy the first dip into your auto band, or ask you if it only reaches the approval band.";
  const ai = await claudeJson<{ summary: string }>(
    `You are a shopping agent. In one short sentence, state the buying strategy for "${r.title}" given: ${bullets.join(" ")} Target ${usd(target)}. JSON {summary}.`
  );
  if (ai?.summary) summary = ai.summary;
  r.targetPrice = target;
  r.strategy = { summary, bullets, buyBy: iso(buyBy), confidence: sale || inflation > 0.05 ? 0.8 : 0.6 };
}

// ---------- chain (PolicySpender on Sepolia; off unless configured) ----------

const isKey = (k?: string) => (/^0x[0-9a-fA-F]{64}$/.test(k ?? "") ? (k as Hex) : undefined);
const CHAIN = {
  rpc: process.env.SEPOLIA_RPC_URL,
  spender: process.env.POLICY_SPENDER as Hex | undefined,
  usdc: (process.env.USDC ?? "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238") as Hex,
  payer: process.env.WALLET_ADDRESS as Hex | undefined,
  merchant: (process.env.MERCHANT_ADDRESS ?? "0x000000000000000000000000000000000000dEaD") as Hex,
  agentKey: isKey(process.env.AGENT_PRIVATE_KEY),
};
const ENS = {
  ownerKey: isKey(process.env.DEPLOYER_PRIVATE_KEY), // Hero operator = alice: owns herodemo.eth and the demo wallet's policy tree
  resolver: process.env.ALICE_RESOLVER as Hex | undefined,
};
// ENSv2 on Sepolia: VerifiableFactory, PermissionedResolver implementation, herodemo.eth's registry (owned by the operator).
const FACTORY = "0x9e726Eb570beb6BCEb495AB8cdA7df517d4e841C" as Hex;
const RES_IMPL = "0x14F09Fd05d4585759e54844DC9B00147131Cf243" as Hex;
const HERODEMO_REGISTRY = "0x9817e00c0ac5478c60D7Bd0A6E55aee939d11aFa" as Hex;
const ENS_ABI = parseAbi([
  "function register(string label, address owner, address subregistry, address resolver, uint256 roles, uint64 expiry) returns (uint256)",
  "function getResolver(string label) view returns (address)",
  "function setData(bytes name, string key, bytes value)",
  "function setText(bytes name, string key, string value)",
  "function setAddress(bytes name, uint256 coinType, bytes value)",
  "function multicall(bytes[] calls) returns (bytes[])",
  "function initialize((address account, uint256 roleBitmap)[] roles, bytes[] calls)",
  "function grantSetterRoles(bytes setterCall, address account) returns (bool)",
  "function revokeRootRoles(uint256 roleBitmap, address account) returns (bool)",
  "function roles(uint256 resource, address account) view returns (uint256)",
  "function deployProxy(address impl, uint256 salt, bytes data) returns (address)",
]);
const ALL_ROLES = BigInt("0x" + "1".repeat(64));
const ZERO = "0x0000000000000000000000000000000000000000" as Hex;
const u256 = (n: number | bigint) => encodeAbiParameters([{ type: "uint256" }], [BigInt(n)]);
const pub = createPublicClient({ chain: sepolia, transport: http(CHAIN.rpc) });
const ORDER = [{
  type: "tuple", components: [
    { name: "payer", type: "address" }, { name: "request", type: "bytes" }, { name: "payTo", type: "address" },
    { name: "price", type: "uint256" }, { name: "sku", type: "bytes32" }, { name: "expiry", type: "uint64" }, { name: "salt", type: "bytes32" },
  ],
}] as const;
const SPENDER_ABI = parseAbi([
  "struct Order { address payer; bytes request; address payTo; uint256 price; bytes32 sku; uint64 expiry; bytes32 salt; }",
  "struct Human { uint256 root; uint256 nullifier; uint256[8] proof; }",
  "function buy(Order o, Human h)",
  "function buyApproved(Order o, uint64 authTime, bytes sig)",
  "function setContinuity(bytes32 c)",
  "function setAccount(bytes32 root, address resolver, address agent, uint256 human)",
  "function accounts(address) view returns (bytes32 root, address resolver, address agent, uint256 human)",
  "function continuity(address) view returns (bytes32)",
  "function remaining(bytes categoryName, address owner) view returns (uint256)",
  "error NotAgent()", "error OrderUsed()", "error Expired()", "error NotYourPolicy()", "error OverMax()",
  "error OverBudget()", "error UnverifiedMerchant()", "error NotOwnerHuman()", "error ProofInvalid()", "error StaleApproval()", "error BadApproval()",
]);
const ERC20 = parseAbi([
  "function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)", "function mint(address,uint256)",
]);
const AGENT = CHAIN.agentKey && privateKeyToAccount(CHAIN.agentKey).address;
const OPERATOR = ENS.ownerKey && privateKeyToAccount(ENS.ownerKey).address;

function dnsEncode(name: string): Hex {
  const parts = name.split(".").flatMap((l) => [l.length, ...stringToBytes(l)]);
  return toHex(new Uint8Array([...parts, 0]));
}

/** The request's owner context: a wallet account's own wallet + resolver, else the Hero-held demo wallet. */
function ctxOf(a?: Account): Ctx {
  if (a?.mode === "wallet") return { acct: a.key, demo: false, payer: a.wallet, root: a.root, resolver: a.resolver, continuity: a.continuity };
  return { acct: a?.key, demo: true, payer: CHAIN.payer, root: ROOT, resolver: ENS.resolver, continuity: a?.continuity };
}
const limitOf = (c: Ctx, category: string) => (c.demo ? categories.get(category)?.limitUsd : accounts.get(c.acct!)?.limits[category]) ?? 0;

function makeOrder(r: Req, price: number) {
  return {
    payer: r.ctx.payer ?? ZERO,
    request: dnsEncode(r.ensName),
    payTo: CHAIN.merchant,
    price: BigInt(Math.round(price * 1e6)),
    sku: keccak256(stringToBytes(r.offerSku ?? r.query)),
    expiry: BigInt(Math.floor(Date.now() / 1000) + 600),
    salt: keccak256(stringToBytes(randomUUID())),
  } as const;
}
const orderHash = (o: ReturnType<typeof makeOrder>) => keccak256(encodeAbiParameters(ORDER, [o]));

/** Sends buy() when the chain is configured; otherwise returns undefined (demo mode). */
async function sendBuy(order: ReturnType<typeof makeOrder>, proof?: any): Promise<Hex | undefined> {
  if (!CHAIN.spender || !CHAIN.agentKey || order.payer === ZERO) return;
  const human = proof
    ? { root: BigInt(proof.merkle_root), nullifier: BigInt(proof.nullifier), proof: Array.from({ length: 8 }, (_, i) => BigInt("0x" + proof.proof.slice(2 + i * 64, 66 + i * 64))) }
    : { root: 0n, nullifier: 0n, proof: Array(8).fill(0n) };
  return send(CHAIN.agentKey, CHAIN.spender, SPENDER_ABI, "buy", [order, human]);
}

const attesterKey = isKey(process.env.HERO_ATTESTER_PRIVATE_KEY);

/** Attester signs "the payer's linked World ID freshly approved this exact order"; the agent submits buyApproved(). */
async function sendBuyApproved(order: ReturnType<typeof makeOrder>, authTime: number, continuity?: Hex): Promise<Hex | undefined> {
  if (!CHAIN.spender || !CHAIN.agentKey || order.payer === ZERO) return;
  if (!attesterKey || !continuity) throw new Error("attester key or World ID link missing");
  const sig = await privateKeyToAccount(attesterKey).signTypedData(
    approvalTypedData(CHAIN.spender, sepolia.id, orderHash(order), continuity, BigInt(authTime))
  );
  return send(CHAIN.agentKey, CHAIN.spender, SPENDER_ABI, "buyApproved", [order, BigInt(authTime), sig]);
}

// One account object per key so viem's nonceManager can hand out nonces to concurrent sends (operator provisioning, agent buys).
const signers = new Map<Hex, PrivateKeyAccount>();
const signer = (k: Hex) => signers.get(k) ?? signers.set(k, privateKeyToAccount(k, { nonceManager })).get(k)!;

/** Gas is estimated before the nonce manager hands out a nonce, so a revert never burns a nonce. */
async function send(key: Hex, address: Hex, abi: any, functionName: string, args: any[]): Promise<Hex> {
  const account = signer(key);
  const gas = await pub.estimateContractGas({ account: account.address, address, abi, functionName, args } as any);
  return broadcast(account, functionName, (w) => w.writeContract({ address, abi, functionName, args, gas: (gas * 12n) / 10n } as any));
}
const sendEth = (key: Hex, to: Hex, value: bigint) =>
  broadcast(signer(key), "transfer", (w) => w.sendTransaction({ to, value, gas: 21_000n } as any));

async function broadcast(account: PrivateKeyAccount, what: string, fn: (w: WalletClient) => Promise<Hex>): Promise<Hex> {
  const wallet = createWalletClient({ account, chain: sepolia, transport: http(CHAIN.rpc) });
  let hash: Hex;
  try {
    hash = await fn(wallet);
  } catch (e) {
    account.nonceManager?.reset({ address: account.address, chainId: sepolia.id }); // the consumed nonce was never broadcast
    throw e;
  }
  const rc = await pub.waitForTransactionReceipt({ hash });
  if (rc.status !== "success") throw new Error(`${what} reverted: ${hash}`);
  return hash;
}

/** Operator writes the request's band records on the payer's resolver in one tx (request names resolve via the resolver, not registered). */
async function writePolicy(r: Req): Promise<Hex | undefined> {
  if (!ENS.ownerKey || !r.ctx.resolver) return;
  const deadline = BigInt(Math.floor(Date.parse(r.deadline) / 1000));
  const name = dnsEncode(r.ensName);
  const calls = ([["auto", BigInt(Math.round(r.autoUsd * 1e6))], ["max", BigInt(Math.round(r.maxUsd * 1e6))], ["deadline", deadline]] as const)
    .map(([k, v]) => encodeFunctionData({ abi: ENS_ABI, functionName: "setData", args: [name, k, u256(v)] }));
  return send(ENS.ownerKey, r.ctx.resolver, ENS_ABI, "multicall", [calls]);
}

/** The agent's only ENS write right: the `status` text record. */
async function agentStatus(r: Req, status: string) {
  if (!CHAIN.agentKey || !r.ctx.resolver) return;
  await send(CHAIN.agentKey, r.ctx.resolver, ENS_ABI, "setText", [dnsEncode(r.ensName), "status", status]).catch((e) => console.error("status write", e?.shortMessage ?? e));
}

/** Demo wallet: PolicySpender.continuity(alice) must be this account's World ID for its mid-band approvals (last demo user wins). */
async function syncDemoContinuity(a: Account): Promise<Hex | undefined> {
  if (!ENS.ownerKey || !CHAIN.spender || !CHAIN.payer) return;
  const cur = await pub.readContract({ address: CHAIN.spender, abi: SPENDER_ABI, functionName: "continuity", args: [CHAIN.payer] });
  if (cur !== a.continuity) return send(ENS.ownerKey, CHAIN.spender, SPENDER_ABI, "setContinuity", [a.continuity]);
}

// ---------- the user's own wallet: provisioning + on-chain readiness ----------

/** One-tx user resolver: user (+ factory, temporarily) admin; limits; operator may set only auto/max/deadline, agent only status. */
function resolverInit(user: Hex, root: string, limits: Record<string, number>, operator: Hex, agent: Hex): Hex {
  const e = (functionName: string, args: any[]) => encodeFunctionData({ abi: ENS_ABI, functionName, args } as any);
  const grant = (setter: Hex, who: Hex) => e("grantSetterRoles", [setter, who]);
  return e("initialize", [[{ account: user, roleBitmap: ALL_ROLES }, { account: FACTORY, roleBitmap: ALL_ROLES }], [
    e("setAddress", [dnsEncode(root), 60n, user]),
    ...Object.entries(limits).map(([c, usd]) => e("setData", [dnsEncode(`${c.toLowerCase()}.${root}`), "limit", u256(Math.round(usd * 1e6))])),
    ...["auto", "max", "deadline"].map((k) => grant(e("setData", ["0x00", k, "0x"]), operator)),
    grant(e("setText", ["0x00", "status", ""]), agent),
    e("revokeRootRoles", [ALL_ROLES, FACTORY]),
  ]]);
}
const saltOf = (a: Account) => BigInt(keccak256(stringToBytes(`${a.wallet!.toLowerCase()}|${a.handle}`)));
const hasCode = async (x?: Hex) => !!x && !!(await pub.getCode({ address: x }));
const walletChain = () => !!(CHAIN.rpc && CHAIN.spender && ENS.ownerKey && AGENT);

const provisioning = new Map<string, Promise<void>>();
/** Idempotent (reads chain first): gas drip, demo MockUSDC, the user's resolver, <handle>.herodemo.eth -> user. */
function provision(a: Account): Promise<void> {
  let p = provisioning.get(a.key);
  if (!p) {
    p = doProvision(a).catch((e) => console.error("provision", a.root, e?.shortMessage ?? e?.message ?? e)).finally(() => provisioning.delete(a.key));
    provisioning.set(a.key, p);
  }
  return p;
}
async function doProvision(a: Account) {
  const key = ENS.ownerKey!, w = a.wallet!, res = a.resolver!;
  const [eth, usdc, deployed, resolverOf] = await Promise.all([
    pub.getBalance({ address: w }),
    pub.readContract({ address: CHAIN.usdc, abi: ERC20, functionName: "balanceOf", args: [w] }),
    hasCode(res),
    pub.readContract({ address: HERODEMO_REGISTRY, abi: ENS_ABI, functionName: "getResolver", args: [a.handle] }),
  ]);
  // sent concurrently: the nonce manager orders them, the gas drip first
  const txs: Promise<Hex>[] = [];
  if (eth < parseEther("0.002")) txs.push(sendEth(key, w, parseEther("0.005")));
  if (usdc < 500_000000n) txs.push(send(key, CHAIN.usdc, ERC20, "mint", [w, 5000_000000n]));
  if (!deployed) txs.push(send(key, FACTORY, ENS_ABI, "deployProxy", [RES_IMPL, saltOf(a), resolverInit(w, a.root, a.limits, OPERATOR!, AGENT!)]));
  if (resolverOf.toLowerCase() !== res.toLowerCase()) {
    const exp = BigInt(Math.floor(Date.now() / 1000) + 365 * 86_400);
    txs.push(send(key, HERODEMO_REGISTRY, ENS_ABI, "register", [a.handle, w, ZERO, res, ALL_ROLES, exp]));
  }
  const failed = (await Promise.allSettled(txs)).find((x) => x.status === "rejected");
  if (failed) throw (failed as PromiseRejectedResult).reason;
  // Hero must end up with no admin rights over the user's resolver
  const [f, o] = await Promise.all([FACTORY, OPERATOR!].map((x) => pub.readContract({ address: res, abi: ENS_ABI, functionName: "roles", args: [0n, x] })));
  if (f !== 0n || o !== 0n) throw new Error(`resolver ${res}: Hero holds root roles (factory ${f}, operator ${o})`);
  a.provisioned = true;
  saveAccounts();
}

/** The 3 transactions the user signs in MetaMask. */
function walletCalls(a: Account) {
  const total = Object.values(a.limits).reduce((s, v) => s + v, 0);
  const call = (id: string, label: string, to: Hex, abi: any, functionName: string, args: any[]) => ({ id, label, to, data: encodeFunctionData({ abi, functionName, args }) });
  return [
    call("approve", `Let Hero's contract pull up to $${total.toLocaleString("en-US")} from this wallet, only as your rules allow`,
      CHAIN.usdc, ERC20, "approve", [CHAIN.spender, BigInt(Math.round(total * 1e6))]),
    call("account", `Your rules live at ${a.root}; agent ${AGENT!.slice(0, 6)}…${AGENT!.slice(-4)} may request buys`,
      CHAIN.spender!, SPENDER_ABI, "setAccount", [namehash(a.root), a.resolver, AGENT, 0n]),
    call("continuity", "Only your World ID can approve bigger buys", CHAIN.spender!, SPENDER_ABI, "setContinuity", [a.continuity]),
  ];
}

type WalletState = { funded: boolean; done: { approve: boolean; account: boolean; continuity: boolean }; ready: boolean };
const stateCache = new Map<string, { at: number; p: Promise<WalletState> }>();
/** Read from chain (cached 3 s): gas funded, which of the 3 user txs landed, and ready = all 3 + the resolver exists. */
function walletState(a: Account): Promise<WalletState> {
  const hit = stateCache.get(a.key);
  if (hit && Date.now() - hit.at < 3000) return hit.p;
  const w = a.wallet!, same = (x: string, y?: string) => x.toLowerCase() === y?.toLowerCase();
  const p = Promise.all([
    pub.getBalance({ address: w }),
    pub.readContract({ address: CHAIN.usdc, abi: ERC20, functionName: "allowance", args: [w, CHAIN.spender!] }),
    pub.readContract({ address: CHAIN.spender!, abi: SPENDER_ABI, functionName: "accounts", args: [w] }),
    pub.readContract({ address: CHAIN.spender!, abi: SPENDER_ABI, functionName: "continuity", args: [w] }),
    hasCode(a.resolver),
  ]).then(([eth, allowance, [root, resolver, agent], cont, code]) => {
    const done = { approve: allowance > 0n, account: root === namehash(a.root) && same(resolver, a.resolver) && same(agent, AGENT), continuity: cont === a.continuity };
    const ready = done.approve && done.account && done.continuity && code;
    if (ready && !a.ready) { a.ready = true; saveAccounts(); } // sticky: an RPC blip never sends the user back to setup
    return { funded: eth >= parseEther("0.002"), done, ready };
  });
  stateCache.set(a.key, { at: Date.now(), p });
  p.catch(() => stateCache.delete(a.key));
  return p;
}

async function walletStatus(a?: Account): Promise<"none" | "provisioning" | "ready" | "demo"> {
  if (!a || a.mode === "demo") return "demo";
  if (a.mode === "none") return "none";
  return a.ready || (await walletState(a).then((s) => s.ready, () => false)) ? "ready" : "provisioning";
}

// ---------- agent step ----------

/** What the contract will still let this category spend this period (falls back to the in-memory view). */
async function leftThisPeriod(c: Ctx, category: string): Promise<number> {
  if (CHAIN.spender && c.payer) {
    const name = dnsEncode(`${category.toLowerCase()}.${c.root}`);
    const v = await pub.readContract({ address: CHAIN.spender, abi: SPENDER_ABI, functionName: "remaining", args: [name, c.payer] }).catch(() => undefined);
    if (v !== undefined) return Number(v) / 1e6;
  }
  return limitOf(c, category) - spentThisPeriod(c, category);
}

function spentThisPeriod(c: Ctx, category: string) {
  const start = Math.floor(Date.now() / PERIOD) * PERIOD;
  return [...requests.values()].filter((r) => r.ctx.root === c.root && r.category === category && r.boughtAt && r.boughtAt >= start).reduce((s, r) => s + (r.boughtPrice ?? 0), 0);
}

function markBought(r: Req, price: number, txHash?: string, human = false) {
  r.status = "bought"; r.boughtAt = Date.now(); r.boughtPrice = price;
  r.activity.push({ date: iso(Date.now()), text: `Bought for ${usd(price)}${human ? " with your World ID approval" : " (auto band)"}${txHash ? "" : " (demo, no chain)"}`, txHash });
}

/** Called when the watched price changes: apply the ENS policy bands exactly like the contract does. */
async function onPrice(r: Req, price: number, deps: Deps) {
  if (r.status !== "watching") return; // bought, expired, or already waiting on the human
  r.currentPrice = price;
  r.priceHistory.push({ date: iso(Date.now()), price });
  const left = await leftThisPeriod(r.ctx, r.category);
  if (price > r.maxUsd) return void r.activity.push({ date: iso(Date.now()), text: `Price ${usd(price)} is above max ${usd(r.maxUsd)}: waiting` });
  if (price > left) return void r.activity.push({ date: iso(Date.now()), text: `${r.category} budget has ${usd(left)} left this period: waiting` });
  const order = makeOrder(r, price);
  if (price <= r.autoUsd) {
    try {
      markBought(r, price, await sendBuy(order));
    } catch (e: any) {
      return void r.activity.push({ date: iso(Date.now()), text: `Contract rejected the purchase: ${reason(e)}` });
    }
    return agentStatus(r, "bought");
  }
  const a: Approval = { id: randomUUID(), requestId: r.id, cartHash: orderHash(order), order, price, status: "pending", expiresAt: Date.now() + 10 * 60_000 };
  a.returnTo = `hero://approval/${a.id}`;
  if (oidcEnabled()) {
    // World ID for Agents: a device-grant attempt bound to this order, kept server-side
    try {
      a.device = await startDevice();
    } catch (e: any) {
      return void r.activity.push({ date: iso(Date.now()), text: `Could not reach World ID (${e.message}): waiting` });
    }
    a.userCode = a.device.userCode;
    a.connectorURI = a.device.approvalUrl;
  } else {
    await deps.startWorldApproval(a);
  }
  approvals.set(a.id, a);
  r.status = "needsApproval";
  r.activity.push({ date: iso(Date.now()), text: `${usd(price)} is above auto ${usd(r.autoUsd)}: asked you to confirm with World ID${a.userCode ? ` (code ${a.userCode})` : ""}` });
}

const hhmmss = (sec: number) => `${new Date(sec * 1000).toISOString().slice(11, 19)} UTC`;

/** World ID for Agents result for an approval: only the request owner's World ID, freshly proven for this attempt, approves. */
async function advanceAgentWorld(a: Approval) {
  if (a.status !== "pending" || !a.device) return;
  const c = requests.get(a.requestId)!.ctx;
  // signed-in requests: the account's own World ID; no-session demo requests: whoever is linked to the demo wallet on chain
  const want = c.continuity ?? (CHAIN.spender && c.payer
    ? await pub.readContract({ address: CHAIN.spender, abi: SPENDER_ABI, functionName: "continuity", args: [c.payer] }).catch(() => undefined) : undefined);
  const res = await pollDevice(a.device);
  if (a.status !== "pending" || res.status === "pending") return; // a concurrent refresh already applied the result
  if (res.status === "expired") return void (a.status = "expired");
  a.status = "denied";
  if (res.status !== "ok") a.denyReason = res.status === "denied" ? "You declined in World ID" : `World ID check failed: ${res.error}`;
  else if (!want || BigInt(want) === 0n) a.denyReason = "Link your World ID first";
  else if (keccak256(stringToBytes(`${res.iss}|${res.sub}`)) !== want) a.denyReason = "Approved by a different World ID";
  else if (Date.now() / 1000 - res.authTime > 300) a.denyReason = "World ID confirmation is older than 5 minutes";
  else {
    a.status = "approved";
    a.authTime = res.authTime;
    a.continuity = want;
    requests.get(a.requestId)!.activity.push({ date: iso(Date.now()), text: `World ID confirmed by you at ${hhmmss(res.authTime)}` });
  }
}

/** Contract custom error name (e.g. OverBudget) when viem decoded it, else the short message. */
const reason = (e: any): string => e?.cause?.data?.errorName ?? e?.walk?.((x: any) => x?.data?.errorName)?.data?.errorName ?? String(e?.shortMessage ?? e);

async function refreshApproval(a: Approval, deps: Deps) {
  if (a.status === "pending" && Date.now() > a.expiresAt) a.status = "expired";
  await (a.device ? advanceAgentWorld(a) : deps.advanceWorld(a));
  const r = requests.get(a.requestId)!;
  if ((a.status === "denied" || a.status === "expired") && !a.closed) {
    a.closed = true;
    if (r.status === "needsApproval") r.status = "watching";
    r.activity.push({
      date: iso(Date.now()),
      text: a.status === "expired" ? "World ID confirmation expired — nothing was bought" : `Declined — nothing was bought (${a.denyReason ?? "World ID"})`,
    });
  }
  if (a.status !== "approved") return;
  if (a.buying) return; // a concurrent poll is already sending buy()
  a.buying = true;
  try {
    const acct = accounts.get(r.ctx.acct ?? "");
    if (a.device && r.ctx.demo && acct) await syncDemoContinuity(acct); // shared demo wallet: point it at this approver first
    a.txHash = a.device ? await sendBuyApproved(a.order, a.authTime!, a.continuity) : await sendBuy(a.order, a.proof);
    a.status = "paid";
    markBought(r, a.price, a.txHash, true);
    await agentStatus(r, "bought");
  } catch (e: any) {
    a.status = "denied"; a.denyReason = reason(e); a.closed = true;
    r.status = "watching";
    r.activity.push({ date: iso(Date.now()), text: `Contract rejected the purchase: ${a.denyReason}` });
  }
}

function approvalView(a: Approval) {
  const r = requests.get(a.requestId)!;
  return {
    orderId: a.id, requestId: r.id, title: r.title, imageUrl: r.imageUrl, merchant: r.merchant ?? "", payTo: a.order.payTo,
    price: a.price, autoUsd: r.autoUsd, maxUsd: r.maxUsd, orderHash: a.cartHash, approvalUrl: a.connectorURI ?? "",
    expiresAt: iso(a.expiresAt), status: a.status, txHash: a.txHash, denyReason: a.denyReason, userCode: a.userCode,
  };
}

function requestView(r: Req) {
  if (r.status === "watching" && Date.now() > Date.parse(r.deadline)) r.status = "expired";
  const { offerSku, boughtAt, boughtPrice, acct, ctx, ...v } = r;
  return { ...v, boughtAt: boughtAt ? iso(boughtAt) : undefined };
}

/** Best catalog match: shares the query's words and is not suspiciously cheap (accessories, cables, cases). */
function pickOffer(d: Draft, offers: Offer[]): Offer | undefined {
  const words = d.query.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 1);
  const score = (o: Offer) => words.filter((w) => o.title.toLowerCase().includes(w)).length / Math.max(1, words.length);
  return offers
    .filter((o) => o.priceMinor / 100 >= 0.5 * d.autoUsd && score(o) >= 0.5)
    .sort((a, b) => score(b) - score(a))[0];
}

// ---------- routes ----------

const acctOf = (res: Response): Account | undefined => res.locals.acct;
/** Only the request's own account sees it (no session sees only no-session requests). */
const mine = (res: Response, r?: Req) => (r && r.acct === acctOf(res)?.key ? r : undefined);
const periodEnds = () => iso((Math.floor(Date.now() / PERIOD) + 1) * PERIOD);
const HANDLE = /^[a-z0-9-]{3,24}$/;
const RESERVED = ["hobby", "needs"];
const badLimit = (v: unknown) => !(typeof v === "number" && v > 0 && v <= 1_000_000);
/** Limits may change only until the user's resolver exists: they are written into its initializer. */
const limitsOpen = async (a: Account) => !(a.provisioned || (a.mode === "wallet" && (await hasCode(a.resolver).catch(() => true))));
// ponytail: walletPage.ts is owned by the page agent; variable specifier so a missing file never breaks startup or tsc.
const PAGE = "./walletPage.js";
const walletPage = () => import(PAGE).then((m) => String(m.walletPageHtml), () => "<!doctype html><title>Hero</title><p>Wallet setup page is not deployed yet.</p>");

export function mountHero(app: Express, deps: Deps) {
  // Sign in with World ID (authorization code + PKCE). Every World ID gets its own account.
  const redirectUri = () => `${(process.env.PUBLIC_URL ?? "").replace(/\/$/, "")}/auth/world/callback`; // exact registered callback
  app.get("/auth/world/start", async (_req, res) => {
    if (!oidcEnabled() || !process.env.PUBLIC_URL) return res.status(503).json({ error: "World ID sign-in is not configured" });
    try {
      res.redirect(302, await loginUrl(redirectUri()));
    } catch (e: any) {
      res.status(502).json({ error: `World ID unavailable: ${e.message}` });
    }
  });
  app.get("/auth/world/callback", async (req, res) => {
    const back = (q: Record<string, string>) => res.redirect(302, `hero://auth?${new URLSearchParams(q)}`);
    const q = req.query as Record<string, string | undefined>;
    const a = takeLogin(String(q.state ?? "")); // consumed before anything else: state is single-use
    if (q.error) return back({ error: String(q.error).replace(/[^a-z0-9_]/g, "").slice(0, 64) || "access_denied" });
    if (!a || typeof q.code !== "string") return back({ error: "invalid_state" });
    let c: Claims;
    try {
      c = await redeemLogin(a, q.code, redirectUri());
    } catch (e: any) {
      console.error("world sign-in:", e.message); // validation reason only, never the code or tokens
      return back({ error: /^[a-z_]+$/.test(e.message) ? e.message : "invalid_id_token" });
    }
    const acct = accountFor(c.iss, c.sub);
    // wallet users set their own continuity; only the Hero-held demo wallet's is set by Hero
    if (acct.mode === "demo") void syncDemoContinuity(acct).catch((e) => console.error("setContinuity", e?.shortMessage ?? e));
    back({ session: newSession(c) });
  });

  // ---- the user's own wallet: one-time MetaMask page at /w/<token> (the token is the capability; same origin, no session) ----
  const byToken = (t: string, fresh = false) => {
    const h = sha256(t);
    const a = [...accounts.values()].find((x) => x.tokenHash === h);
    return a && (!fresh || Date.now() <= a.tokenExp!) ? a : undefined;
  };
  app.get("/w/:t", async (_req, res) => {
    res.set("content-type", "text/html; charset=utf-8").set("cache-control", "no-store").send(await walletPage());
  });
  app.post("/w/:t/connect", async (req, res) => {
    const a = byToken(req.params.t, true);
    if (!a) return res.status(404).json({ error: "link_expired" });
    if (!walletChain()) return res.status(503).json({ error: "chain_not_configured" });
    let addr: Hex;
    try {
      addr = getAddress(String(req.body?.address));
    } catch {
      return res.status(400).json({ error: "bad_address" });
    }
    if (a.wallet && a.wallet !== addr) return res.status(409).json({ error: "wallet_mismatch", wallet: a.wallet });
    if (!a.wallet) {
      // free label: not claimed by another account, not registered under herodemo.eth; else a 4-hex suffix
      let h = a.handle;
      for (let i = 0; ; i++) {
        const taken = [...accounts.values()].some((x) => x !== a && x.wallet && x.handle === h)
          || (await pub.readContract({ address: HERODEMO_REGISTRY, abi: ENS_ABI, functionName: "getResolver", args: [h] })) !== ZERO;
        if (!taken) break;
        if (i === 5) return res.status(409).json({ error: "handle_taken" });
        h = `${a.handle.slice(0, 19)}-${randomBytes(2).toString("hex")}`;
      }
      Object.assign(a, { handle: h, root: `${h}.${ROOT}`, wallet: addr });
      // CREATE2 address depends only on (operator, salt): known before the deploy is sent
      const { result } = await pub.simulateContract({
        account: OPERATOR!, address: FACTORY, abi: ENS_ABI, functionName: "deployProxy",
        args: [RES_IMPL, saltOf(a), resolverInit(addr, a.root, a.limits, OPERATOR!, AGENT!)],
      });
      a.resolver = result;
    }
    a.mode = "wallet";
    saveAccounts();
    void provision(a);
    res.json({ calls: walletCalls(a), ensName: a.root, chainId: "0xaa36a7" });
  });
  app.get("/w/:t/status", async (req, res) => {
    const a = byToken(req.params.t);
    if (!a) return res.status(404).json({ error: "link_expired" });
    const none = { funded: false, done: { approve: false, account: false, continuity: false }, ready: false };
    const s = a.wallet && walletChain() ? await walletState(a).catch(() => none) : none;
    res.json({ ...s, ensName: a.root, address: a.wallet ?? "" });
  });

  // Every /api route needs a session unless HERO_REQUIRE_LOGIN=0 (read per request).
  app.use("/api", (req, res, next) => {
    const s = sessionOf(req);
    res.locals.session = s;
    res.locals.acct = s && accountFor(s.iss, s.sub);
    if (!s && process.env.HERO_REQUIRE_LOGIN !== "0") return res.status(401).json({ error: "sign_in_required" });
    next();
  });
  const meView = async (res: Response) => {
    const s: Session | undefined = res.locals.session, a = acctOf(res), c = ctxOf(a);
    return {
      signedIn: !!s, sub: s ? sha256(s.sub).slice(0, 12) : undefined, authTime: s ? iso(s.authTime * 1000) : undefined, acr: s?.acr,
      worldLinked: !!a, wallet: c.payer ?? "", ensRoot: c.root, walletStatus: await walletStatus(a), handle: a?.handle,
    };
  };
  app.get("/api/me", async (_req, res) => res.json(await meView(res)));
  app.post("/api/logout", (req, res) => {
    const t = bearer(req);
    if (t && sessions.delete(sha256(t))) saveSessions();
    res.json({ ok: true });
  });

  // Start (or restart) wallet setup: a 30-minute single-account link for MetaMask's in-app browser.
  app.post("/api/wallet/start", async (req, res) => {
    const a = acctOf(res);
    if (!a) return res.status(401).json({ error: "sign_in_required" });
    const { handle, limits } = req.body ?? {};
    if (handle !== undefined && (typeof handle !== "string" || !HANDLE.test(handle) || RESERVED.includes(handle))) return res.status(400).json({ error: "bad_handle" });
    if (limits !== undefined) {
      if (typeof limits !== "object" || !limits || Object.entries(limits).some(([k, v]) => !Object.hasOwn(a.limits, k) || badLimit(v))) return res.status(400).json({ error: "bad_limits" });
      if (await limitsOpen(a)) Object.assign(a.limits, limits);
    }
    if (handle && !a.wallet) Object.assign(a, { handle, root: `${handle}.${ROOT}` }); // fixed once a wallet is bound
    const t = randomBytes(32).toString("base64url");
    Object.assign(a, { tokenHash: sha256(t), tokenExp: Date.now() + 30 * 60_000 });
    saveAccounts();
    const base = (process.env.PUBLIC_URL || `${req.protocol}://${req.get("host")}`).replace(/\/$/, "");
    res.json({ url: `https://link.metamask.io/dapp/${base.replace(/^https?:\/\//, "")}/w/${t}`, pageUrl: `${base}/w/${t}`, ensName: a.root });
  });
  // "Use demo wallet": the Hero-held alice wallet; its on-chain continuity follows this account.
  app.post("/api/wallet/demo", async (_req, res) => {
    const a = acctOf(res);
    if (!a) return res.status(401).json({ error: "sign_in_required" });
    a.mode = "demo";
    saveAccounts();
    void syncDemoContinuity(a).catch((e) => console.error("setContinuity", e?.shortMessage ?? e));
    res.json(await meView(res));
  });

  app.post("/api/chat", async (req, res) => {
    const draft = await parseDraft(String(req.body?.message ?? ""));
    res.json({
      reply: `Got it: ${draft.title}. I will buy on my own up to ${usd(draft.autoUsd)}, ask you up to ${usd(draft.maxUsd)}, and never above that. Deadline ${new Date(draft.deadline).toDateString()}.`,
      draft,
    });
  });

  app.post("/api/requests", async (req, res) => {
    const d: Draft = req.body;
    const a = acctOf(res), ctx = ctxOf(a);
    const id = randomUUID().slice(0, 8);
    const slug = `${d.title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 20)}-${id.slice(0, 4)}`; // unique ENS label
    const offer = pickOffer(d, await deps.searchCatalog(d.query, Math.round(d.maxUsd * 115)).catch(() => []));
    const current = offer ? offer.priceMinor / 100 : d.maxUsd * 1.05;
    const r: Req = {
      ...d, acct: a?.key, ctx, id, ensName: `${slug}.${d.category.toLowerCase()}.${ctx.root}`, status: "watching", currentPrice: current,
      imageUrl: offer?.image, merchant: offer ? new URL(offer.merchant).host : undefined, offerSku: offer?.sku,
      priceHistory: history(id, current),
      events: EVENTS.map((e) => ({ date: iso(e.date), name: e.name })),
      activity: [],
    };
    const tx = await writePolicy(r).catch((e) => void console.error("writePolicy", e?.shortMessage ?? e));
    r.activity.push({ date: iso(Date.now()), text: `Policy ${tx ? "written to ENS" : "saved (demo, no chain)"}: ${r.ensName} auto ${usd(d.autoUsd)}, max ${usd(d.maxUsd)}`, txHash: tx });
    requests.set(id, r);
    if (current <= d.autoUsd) await onPrice(r, current, deps); // already in the auto band: the agent acts now
    await strategize(r);
    res.json(requestView(r));
  });

  app.get("/api/requests", (_req, res) => res.json([...requests.values()].filter((r) => mine(res, r)).reverse().map(requestView)));
  app.get("/api/requests/:id", (req, res) => {
    const r = mine(res, requests.get(req.params.id));
    r ? res.json(requestView(r)) : res.status(404).end();
  });

  // Demo lever: the price watcher reports a new price.
  app.post("/api/requests/:id/price", async (req, res) => {
    const r = mine(res, requests.get(req.params.id));
    if (!r) return res.status(404).end();
    await onPrice(r, Number(req.body?.price), deps);
    await strategize(r);
    res.json(requestView(r));
  });

  const myApprovals = (res: Response) => [...approvals.values()].filter((a) => mine(res, requests.get(a.requestId)));
  app.get("/api/approvals", async (_req, res) => {
    const list = myApprovals(res);
    for (const a of list) await refreshApproval(a, deps);
    res.json(list.reverse().map(approvalView));
  });
  app.get("/api/approvals/:id", async (req, res) => {
    const a = myApprovals(res).find((x) => x.id === req.params.id);
    if (!a) return res.status(404).end();
    await refreshApproval(a, deps);
    res.json(approvalView(a));
  });

  // Legacy one-time link (device grant): points the Hero-held demo wallet's continuity at this World ID.
  app.post("/api/world/link", async (_req, res) => {
    if (!oidcEnabled()) return res.status(503).json({ error: "World ID for Agents is not configured" });
    try {
      const device = await startDevice();
      const linkId = randomUUID();
      links.set(linkId, { device, status: "pending" });
      res.json({ linkId, userCode: device.userCode, approvalUrl: device.approvalUrl, expiresAt: iso(device.expiresAt) });
    } catch (e: any) {
      res.status(502).json({ error: e.message });
    }
  });
  app.get("/api/world/link/:id", async (req, res) => {
    const l = links.get(req.params.id);
    if (!l) return res.status(404).end();
    const r = l.status === "pending" ? await pollDevice(l.device) : undefined;
    if (l.status === "pending" && r && r.status !== "pending") { // re-checked after await: apply the result once
      if (r.status === "ok") {
        l.status = "linked";
        const a = accountFor(r.iss, r.sub);
        if (a.mode !== "wallet") syncDemoContinuity(a).then((h) => { if (h) l.txHash = h; }, (e) => console.error("setContinuity", e?.shortMessage ?? e));
      } else if (r.status === "expired") l.status = "expired";
      else { l.status = "denied"; l.error = r.status === "denied" ? "You declined in World ID" : r.error; }
    }
    res.json({ status: l.status, error: l.error, txHash: l.txHash });
  });

  app.get("/api/budgets", async (_req, res) => {
    const a = acctOf(res), c = ctxOf(a), own = a && a.mode !== "demo";
    const payer = own ? a.wallet : c.payer, root = own ? a.root : c.root;
    let usdcBalance = 0, allowance = 0;
    if (payer) {
      usdcBalance = Number(await pub.readContract({ address: CHAIN.usdc, abi: ERC20, functionName: "balanceOf", args: [payer] }).catch(() => 0n)) / 1e6;
      if (CHAIN.spender) allowance = Number(await pub.readContract({ address: CHAIN.usdc, abi: ERC20, functionName: "allowance", args: [payer, CHAIN.spender] }).catch(() => 0n)) / 1e6;
    }
    const cats: [string, { limitUsd: number; pct?: number }][] = own ? Object.entries(a.limits).map(([n, v]) => [n, { limitUsd: v }]) : [...categories];
    res.json({
      wallet: { address: payer ?? "", ensRoot: root, usdcBalance, allowance, agent: AGENT ?? "", worldLinked: !!a },
      categories: await Promise.all(cats.map(async ([name, x]) => ({
        name, ensName: `${name.toLowerCase()}.${root}`, limitUsd: x.limitUsd,
        spentUsd: a?.mode === "none" ? 0 : Math.max(0, x.limitUsd - (await leftThisPeriod(c, name))), pct: x.pct, periodEnds: periodEnds(),
      }))),
    });
  });
  app.put("/api/budgets/:name", async (req, res) => {
    const a = acctOf(res), name = req.params.name;
    if (a && a.mode !== "demo") {
      // own wallet: limits go into the resolver initializer; afterwards only the user's wallet can change them
      if (!Object.hasOwn(a.limits, name)) return res.status(404).end();
      if (!(await limitsOpen(a))) return res.status(409).json({ error: "wallet_required" });
      const v = Number(req.body?.limitUsd);
      if (badLimit(v)) return res.status(400).json({ error: "bad_limit" });
      a.limits[name] = v;
      saveAccounts();
      return res.json({ name, ensName: `${name.toLowerCase()}.${a.root}`, limitUsd: v, spentUsd: 0, periodEnds: periodEnds() });
    }
    const c = categories.get(name);
    if (!c) return res.status(404).end();
    c.limitUsd = Number(req.body?.limitUsd ?? c.limitUsd);
    c.pct = req.body?.pct ?? undefined;
    if (ENS.ownerKey && ENS.resolver) {
      // one record update re-caps every request in this category
      const node = dnsEncode(`${name.toLowerCase()}.${ROOT}`);
      const calls = ([["limit", Math.round(c.limitUsd * 1e6)], ["pct", c.pct ?? 0]] as const)
        .map(([k, v]) => encodeFunctionData({ abi: ENS_ABI, functionName: "setData", args: [node, k, u256(v)] }));
      await send(ENS.ownerKey, ENS.resolver, ENS_ABI, "multicall", [calls]).catch((e) => console.error("limit write", e?.shortMessage ?? e));
    }
    res.json({ name, ensName: `${name.toLowerCase()}.${ROOT}`, limitUsd: c.limitUsd, spentUsd: spentThisPeriod(ctxOf(a), name), pct: c.pct, periodEnds: periodEnds() });
  });

  // restart mid-provisioning: finish what was persisted (every step reads chain first)
  if (walletChain()) for (const a of accounts.values()) if (a.mode === "wallet" && a.resolver && !a.provisioned) void provision(a);
}
