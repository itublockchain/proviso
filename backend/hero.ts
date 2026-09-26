// Hero API for the iOS app: requests -> time-aware strategy -> ENS policy bands -> auto-buy or World-approved buy.
import type { Express, Request } from "express";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import {
  createPublicClient, createWalletClient, encodeAbiParameters, encodeFunctionData, http, keccak256, parseAbi, stringToBytes, toHex, type Hex,
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
type Req = Draft & {
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
  closed?: boolean; // denial/expiry already applied to the request
};

// Local state files (gitignored); HERO_STATE_DIR lets check.ts use a temp dir.
const stateFile = (name: string) => (process.env.HERO_STATE_DIR ? `${process.env.HERO_STATE_DIR}/${name}` : new URL(`./${name}`, import.meta.url));
const load = (f: string | URL) => { try { return JSON.parse(readFileSync(f, "utf8")); } catch { return undefined; } };

// The owner's linked World ID for Agents subject: "the human who authorized this agent". Kept on disk so a restart keeps it.
type Owner = { iss: string; sub: string; continuity: Hex; linkedAt: number };
const OWNER_FILE = stateFile(".world-owner.json");
let owner: Owner | undefined = load(OWNER_FILE);

// Sign in with World ID sessions: opaque bearer tokens, only their sha256 is stored. Single owner: a session is valid only for the owner.
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
  if (s && Date.now() - s.createdAt <= SESSION_TTL && owner && s.iss === owner.iss && s.sub === owner.sub) return s;
}
const links = new Map<string, { device: Device; status: "pending" | "linked" | "denied" | "expired"; error?: string; txHash?: Hex }>();

const requests = new Map<string, Req>();
const approvals = new Map<string, Approval>();
const categories = new Map<string, { limitUsd: number; pct?: number }>([
  ["Hobby", { limitUsd: 1000 }],
  ["Needs", { limitUsd: 3000 }],
]);

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
  ownerKey: isKey(process.env.DEPLOYER_PRIVATE_KEY), // alice owns the policy tree
  resolver: process.env.ALICE_RESOLVER as Hex | undefined,
  registries: { Hobby: process.env.HOBBY_REGISTRY, Needs: process.env.NEEDS_REGISTRY } as Record<string, Hex | undefined>,
};
const ENS_ABI = parseAbi([
  "function register(string label, address owner, address subregistry, address resolver, uint256 roles, uint64 expiry)",
  "function setData(bytes name, string key, bytes value)",
  "function setText(bytes name, string key, string value)",
  "function multicall(bytes[] calls) returns (bytes[])",
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
  "function remaining(bytes categoryName, address owner) view returns (uint256)",
  "error NotAgent()", "error OrderUsed()", "error Expired()", "error NotYourPolicy()", "error OverMax()",
  "error OverBudget()", "error UnverifiedMerchant()", "error NotOwnerHuman()", "error ProofInvalid()", "error StaleApproval()", "error BadApproval()",
]);
const ERC20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function allowance(address,address) view returns (uint256)"]);

function dnsEncode(name: string): Hex {
  const parts = name.split(".").flatMap((l) => [l.length, ...stringToBytes(l)]);
  return toHex(new Uint8Array([...parts, 0]));
}

function makeOrder(r: Req, price: number) {
  return {
    payer: CHAIN.payer ?? "0x0000000000000000000000000000000000000000",
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
  if (!CHAIN.spender || !CHAIN.agentKey || !CHAIN.payer) return;
  const human = proof
    ? { root: BigInt(proof.merkle_root), nullifier: BigInt(proof.nullifier), proof: Array.from({ length: 8 }, (_, i) => BigInt("0x" + proof.proof.slice(2 + i * 64, 66 + i * 64))) }
    : { root: 0n, nullifier: 0n, proof: Array(8).fill(0n) };
  return send(CHAIN.agentKey, CHAIN.spender, SPENDER_ABI, "buy", [order, human]);
}

const attesterKey = isKey(process.env.HERO_ATTESTER_PRIVATE_KEY);

/** Attester signs "the owner's linked World ID freshly approved this exact order"; the agent submits buyApproved(). */
async function sendBuyApproved(order: ReturnType<typeof makeOrder>, authTime: number): Promise<Hex | undefined> {
  if (!CHAIN.spender || !CHAIN.agentKey || !CHAIN.payer) return;
  if (!attesterKey || !owner) throw new Error("attester key or World ID link missing");
  const sig = await privateKeyToAccount(attesterKey).signTypedData(
    approvalTypedData(CHAIN.spender, sepolia.id, orderHash(order), owner.continuity, BigInt(authTime))
  );
  return send(CHAIN.agentKey, CHAIN.spender, SPENDER_ABI, "buyApproved", [order, BigInt(authTime), sig]);
}

async function send(key: Hex, address: Hex, abi: any, functionName: string, args: any[]): Promise<Hex> {
  const wallet = createWalletClient({ account: privateKeyToAccount(key), chain: sepolia, transport: http(CHAIN.rpc) });
  const hash = await wallet.writeContract({ address, abi, functionName, args } as any);
  const rc = await pub.waitForTransactionReceipt({ hash });
  if (rc.status !== "success") throw new Error(`${functionName} reverted: ${hash}`);
  return hash;
}

/** Owner registers <request>.<category>.<root> (ENS expiry = deadline) and writes its band records. */
async function writePolicy(r: Req): Promise<Hex | undefined> {
  const reg = ENS.registries[r.category];
  if (!ENS.ownerKey || !ENS.resolver || !reg) return;
  const deadline = BigInt(Math.floor(Date.parse(r.deadline) / 1000));
  const owner = privateKeyToAccount(ENS.ownerKey).address;
  await send(ENS.ownerKey, reg, ENS_ABI, "register", [r.ensName.split(".")[0], owner, ZERO, ENS.resolver, ALL_ROLES, deadline]);
  const name = dnsEncode(r.ensName);
  const calls = ([["auto", BigInt(Math.round(r.autoUsd * 1e6))], ["max", BigInt(Math.round(r.maxUsd * 1e6))], ["deadline", deadline]] as const)
    .map(([k, v]) => encodeFunctionData({ abi: ENS_ABI, functionName: "setData", args: [name, k, u256(v)] }));
  return send(ENS.ownerKey, ENS.resolver, ENS_ABI, "multicall", [calls]);
}

/** The agent's only ENS write right: the `status` text record. */
async function agentStatus(r: Req, status: string) {
  if (!CHAIN.agentKey || !ENS.resolver) return;
  await send(CHAIN.agentKey, ENS.resolver, ENS_ABI, "setText", [dnsEncode(r.ensName), "status", status]).catch((e) => console.error("status write", e?.shortMessage ?? e));
}

// ---------- agent step ----------

/** What the contract will still let this category spend this period (falls back to the in-memory view). */
async function leftThisPeriod(category: string): Promise<number> {
  const c = categories.get(category)!;
  if (CHAIN.spender && CHAIN.payer) {
    const name = dnsEncode(`${category.toLowerCase()}.${ROOT}`);
    const v = await pub.readContract({ address: CHAIN.spender, abi: SPENDER_ABI, functionName: "remaining", args: [name, CHAIN.payer] }).catch(() => undefined);
    if (v !== undefined) return Number(v) / 1e6;
  }
  return c.limitUsd - spentThisPeriod(category);
}

function spentThisPeriod(category: string) {
  const start = Math.floor(Date.now() / PERIOD) * PERIOD;
  return [...requests.values()].filter((r) => r.category === category && r.boughtAt && r.boughtAt >= start).reduce((s, r) => s + (r.boughtPrice ?? 0), 0);
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
  const left = await leftThisPeriod(r.category);
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

/** World ID for Agents result for an approval: only the owner's linked World ID, freshly proven for this attempt, approves. */
async function advanceAgentWorld(a: Approval) {
  if (a.status !== "pending" || !a.device) return;
  const res = await pollDevice(a.device);
  if (a.status !== "pending" || res.status === "pending") return; // a concurrent refresh already applied the result
  if (res.status === "expired") return void (a.status = "expired");
  a.status = "denied";
  if (res.status !== "ok") a.denyReason = res.status === "denied" ? "You declined in World ID" : `World ID check failed: ${res.error}`;
  else if (!owner) a.denyReason = "Link your World ID first";
  else if (res.iss !== owner.iss || res.sub !== owner.sub) a.denyReason = "Approved by a different World ID";
  else if (Date.now() / 1000 - res.authTime > 300) a.denyReason = "World ID confirmation is older than 5 minutes";
  else {
    a.status = "approved";
    a.authTime = res.authTime;
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
    a.txHash = a.device ? await sendBuyApproved(a.order, a.authTime!) : await sendBuy(a.order, a.proof);
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
  const { offerSku, boughtAt, boughtPrice, ...v } = r;
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

/** Records (iss, sub) as the owner; the owner (= payer) mirrors the continuity onchain, buyApproved() fails closed until it lands. */
function linkOwner(iss: string, sub: string): Promise<Hex | void> {
  owner = { iss, sub, continuity: keccak256(stringToBytes(`${iss}|${sub}`)), linkedAt: Date.now() };
  writeFileSync(OWNER_FILE, JSON.stringify(owner));
  if (!ENS.ownerKey || !CHAIN.spender) return Promise.resolve();
  return send(ENS.ownerKey, CHAIN.spender, SPENDER_ABI, "setContinuity", [owner.continuity]).catch((e) => void console.error("setContinuity", e?.shortMessage ?? e));
}

// ---------- routes ----------

export function mountHero(app: Express, deps: Deps) {
  // Sign in with World ID (authorization code + PKCE). The first World ID to sign in becomes the owner (single-owner demo).
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
    if (!owner) void linkOwner(c.iss, c.sub); // sets owner now; the setContinuity tx lands in the background
    else if (c.iss !== owner.iss || c.sub !== owner.sub) return back({ error: "not_owner" });
    back({ session: newSession(c) });
  });

  // Every /api route needs a session unless HERO_REQUIRE_LOGIN=0 (read per request).
  app.use("/api", (req, res, next) => {
    res.locals.session = sessionOf(req);
    if (!res.locals.session && process.env.HERO_REQUIRE_LOGIN !== "0") return res.status(401).json({ error: "sign_in_required" });
    next();
  });
  app.get("/api/me", (_req, res) => {
    const s: Session | undefined = res.locals.session;
    res.json({
      signedIn: !!s, sub: s ? sha256(s.sub).slice(0, 12) : undefined, authTime: s ? iso(s.authTime * 1000) : undefined, acr: s?.acr,
      worldLinked: !!owner, wallet: CHAIN.payer ?? "", ensRoot: ROOT,
    });
  });
  app.post("/api/logout", (req, res) => {
    const t = bearer(req);
    if (t && sessions.delete(sha256(t))) saveSessions();
    res.json({ ok: true });
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
    const id = randomUUID().slice(0, 8);
    const slug = `${d.title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 20)}-${id.slice(0, 4)}`; // unique ENS label
    const offer = pickOffer(d, await deps.searchCatalog(d.query, Math.round(d.maxUsd * 115)).catch(() => []));
    const current = offer ? offer.priceMinor / 100 : d.maxUsd * 1.05;
    const r: Req = {
      ...d, id, ensName: `${slug}.${d.category.toLowerCase()}.${ROOT}`, status: "watching", currentPrice: current,
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

  app.get("/api/requests", (_req, res) => res.json([...requests.values()].reverse().map(requestView)));
  app.get("/api/requests/:id", (req, res) => {
    const r = requests.get(req.params.id);
    r ? res.json(requestView(r)) : res.status(404).end();
  });

  // Demo lever: the price watcher reports a new price.
  app.post("/api/requests/:id/price", async (req, res) => {
    const r = requests.get(req.params.id);
    if (!r) return res.status(404).end();
    await onPrice(r, Number(req.body?.price), deps);
    await strategize(r);
    res.json(requestView(r));
  });

  app.get("/api/approvals", async (_req, res) => {
    for (const a of approvals.values()) await refreshApproval(a, deps);
    res.json([...approvals.values()].reverse().map(approvalView));
  });
  app.get("/api/approvals/:id", async (req, res) => {
    const a = approvals.get(req.params.id);
    if (!a) return res.status(404).end();
    await refreshApproval(a, deps);
    res.json(approvalView(a));
  });

  // One-time link: the owner proves with World ID (device grant) that they are the human who authorized this agent.
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
        linkOwner(r.iss, r.sub).then((h) => { if (h) l.txHash = h; });
      } else if (r.status === "expired") l.status = "expired";
      else { l.status = "denied"; l.error = r.status === "denied" ? "You declined in World ID" : r.error; }
    }
    res.json({ status: l.status, error: l.error, txHash: l.txHash });
  });

  app.get("/api/budgets", async (_req, res) => {
    let usdcBalance = 0, allowance = 0;
    if (CHAIN.payer) {
      usdcBalance = Number(await pub.readContract({ address: CHAIN.usdc, abi: ERC20, functionName: "balanceOf", args: [CHAIN.payer] }).catch(() => 0n)) / 1e6;
      if (CHAIN.spender) allowance = Number(await pub.readContract({ address: CHAIN.usdc, abi: ERC20, functionName: "allowance", args: [CHAIN.payer, CHAIN.spender] }).catch(() => 0n)) / 1e6;
    }
    const periodEnds = iso((Math.floor(Date.now() / PERIOD) + 1) * PERIOD);
    res.json({
      wallet: {
        address: CHAIN.payer ?? "", ensRoot: ROOT, usdcBalance, allowance, agent: CHAIN.agentKey ? privateKeyToAccount(CHAIN.agentKey).address : "",
        worldLinked: !!owner,
      },
      categories: await Promise.all([...categories].map(async ([name, c]) => ({
        name, ensName: `${name.toLowerCase()}.${ROOT}`, limitUsd: c.limitUsd,
        spentUsd: Math.max(0, c.limitUsd - (await leftThisPeriod(name))), pct: c.pct, periodEnds,
      }))),
    });
  });
  app.put("/api/budgets/:name", async (req, res) => {
    const c = categories.get(req.params.name);
    if (!c) return res.status(404).end();
    c.limitUsd = Number(req.body?.limitUsd ?? c.limitUsd);
    c.pct = req.body?.pct ?? undefined;
    if (ENS.ownerKey && ENS.resolver) {
      // one record update re-caps every request in this category
      const name = dnsEncode(`${req.params.name.toLowerCase()}.${ROOT}`);
      const calls = ([["limit", Math.round(c.limitUsd * 1e6)], ["pct", c.pct ?? 0]] as const)
        .map(([k, v]) => encodeFunctionData({ abi: ENS_ABI, functionName: "setData", args: [name, k, u256(v)] }));
      await send(ENS.ownerKey, ENS.resolver, ENS_ABI, "multicall", [calls]).catch((e) => console.error("limit write", e?.shortMessage ?? e));
    }
    res.json({ name: req.params.name, ensName: `${req.params.name.toLowerCase()}.${ROOT}`, limitUsd: c.limitUsd, spentUsd: spentThisPeriod(req.params.name), pct: c.pct, periodEnds: iso((Math.floor(Date.now() / PERIOD) + 1) * PERIOD) });
  });
}
