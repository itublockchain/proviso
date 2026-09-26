// CartLock MCP server: real Shopify catalog search -> pick -> human approval -> cart-bound purchase.
import express from "express";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { keccak256, encodeAbiParameters, parseAbiParameters } from "viem";
import { widgetHtml } from "./widget.js";
import { mountHero } from "./hero.js";
import QRCode from "qrcode";
import { IDKit, orbLegacy, type IDKitRequest } from "@worldcoin/idkit-core";
import { signRequest } from "@worldcoin/idkit-core/signing";
import { hashSignal } from "@worldcoin/idkit-core/hashing";

// ponytail: IDKit's WASM loader fetch()es a file:// URL, which Node's fetch rejects; serve it from disk. Drop when IDKit ships a Node init.
const nodeFetch = globalThis.fetch;
globalThis.fetch = async (input: any, init?: any) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
  if (url.startsWith("file:")) return new Response(await readFile(new URL(url)), { headers: { "content-type": "application/wasm" } });
  return nodeFetch(input, init);
};

const PORT = Number(process.env.PORT ?? 8787);
const CATALOG = "https://catalog.shopify.com/api/ucp/mcp";
const UCP_PROFILE =
  process.env.UCP_PROFILE ??
  "https://shopify.dev/ucp/agent-profiles/examples/2026-08-25/valid-with-capabilities.json";
const WIDGET_URI = "ui://cartlock/shop-v2.html";

type Offer = {
  sku: string; // Shopify variant gid
  title: string;
  merchant: string; // merchant origin, e.g. https://altex.com
  priceMinor: number; // USD cents
  currency: string;
  image?: string;
  checkoutUrl: string;
};
type Order = {
  id: string;
  offer: Offer;
  cartHash: `0x${string}`;
  status: "pending" | "approved" | "denied" | "expired" | "paid";
  expiresAt: number;
  txHash?: string;
  world?: IDKitRequest; // live IDKit bridge request
  connectorURI?: string;
  nullifier?: string;
  proof?: any; // raw World response, forwarded onchain
  returnTo?: string;
  denyReason?: string;
};

const WORLD = {
  appId: process.env.WORLD_APP_ID as `app_${string}`,
  rpId: process.env.WORLD_RP_ID!,
  action: process.env.WORLD_ACTION_PREFIX ?? "approve-cart",
  key: process.env.WORLD_RP_SIGNING_KEY!,
  env: (process.env.WORLD_ENVIRONMENT ?? "staging") as "staging" | "production",
};

const offers = new Map<string, Offer>(); // sku -> last seen offer (server is the source of truth for price)
const orders = new Map<string, Order>();

async function searchCatalog(query: string, maxPriceMinor?: number): Promise<Offer[]> {
  const res = await fetch(CATALOG, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: {
        name: "search_catalog",
        arguments: {
          meta: { "ucp-agent": { profile: UCP_PROFILE } },
          catalog: {
            query,
            filters: { available: true, ...(maxPriceMinor ? { price: { max: maxPriceMinor } } : {}) },
            context: { address_country: "US" },
            pagination: { limit: 8 },
          },
        },
      },
    }),
  });
  const json: any = await res.json();
  const products: any[] = json?.result?.structuredContent?.products ?? [];
  const out: Offer[] = [];
  for (const p of products) {
    const v = p.variants?.[0];
    if (!v?.checkout_url || !v?.price) continue;
    const offer: Offer = {
      sku: v.id,
      title: p.title,
      merchant: new URL(v.checkout_url).origin,
      priceMinor: v.price.amount,
      currency: v.price.currency,
      image: p.media?.[0]?.url ?? v.media?.[0]?.url,
      checkoutUrl: v.checkout_url,
    };
    offers.set(offer.sku, offer);
    out.push(offer);
    if (out.length === 5) break;
  }
  return out;
}

// Cart hash is what the human approves and what the vault contract enforces.
function cartHash(o: Offer, orderId: string, expiresAt: number): `0x${string}` {
  return keccak256(
    encodeAbiParameters(parseAbiParameters("string merchant, string sku, uint256 price, bytes32 orderId, uint64 expiry"), [
      o.merchant,
      o.sku,
      BigInt(o.priceMinor),
      keccak256(new TextEncoder().encode(orderId)),
      BigInt(Math.floor(expiresAt / 1000)),
    ])
  );
}

// World ID request whose signal is the cart hash: the proof only approves this exact cart.
async function startWorldApproval(o: Order) {
  const rp = signRequest({ signingKeyHex: WORLD.key, action: WORLD.action, ttl: 300 });
  o.world = await IDKit.request({
    app_id: WORLD.appId,
    action: WORLD.action,
    rp_context: { rp_id: WORLD.rpId, nonce: rp.nonce, created_at: rp.createdAt, expires_at: rp.expiresAt, signature: rp.sig },
    allow_legacy_proofs: true,
    environment: WORLD.env,
    ...(o.returnTo ? { return_to: o.returnTo } : {}), // World App deep-links back to the app after approving
  }).preset(orbLegacy({ signal: o.cartHash }));
  o.connectorURI = o.world.connectorURI;
}

// Poll the bridge once; on a proof, verify it server-side and check it is bound to this cart.
async function advanceWorld(o: Order) {
  if (o.status !== "pending" || !o.world) return;
  const st = await o.world.pollOnce();
  if (st.type === "failed") {
    o.status = "denied";
    o.denyReason = String(st.error);
  }
  if (st.type !== "confirmed" || !st.result) return;
  const result: any = st.result;
  const resp = result.responses?.[0];
  if (resp?.signal_hash?.toLowerCase() !== hashSignal(o.cartHash).toLowerCase()) {
    o.status = "denied";
    o.denyReason = "proof not bound to this cart";
    return;
  }
  const r = await fetch(`https://developer.world.org/api/v4/verify/${WORLD.rpId}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      ...(process.env.WORLD_STAGING_VERIFICATION_TOKEN ? { "x-staging-verification-token": process.env.WORLD_STAGING_VERIFICATION_TOKEN } : {}),
    },
    body: JSON.stringify(result),
  });
  if (!r.ok) {
    o.status = "denied";
    o.denyReason = `verify failed: ${r.status} ${(await r.text()).slice(0, 200)}`;
    console.error(o.denyReason);
    return;
  }
  o.nullifier = resp.nullifier;
  o.proof = resp;
  o.status = "approved";
}

const approvalUrl = (o: Order) => o.connectorURI ?? "";

async function orderView(o: Order) {
  if (o.status === "pending" && Date.now() > o.expiresAt) o.status = "expired";
  return {
    orderId: o.id,
    status: o.status,
    cartHash: o.cartHash,
    title: o.offer.title,
    merchant: o.offer.merchant,
    price: o.offer.priceMinor / 100,
    currency: o.offer.currency,
    approvalUrl: approvalUrl(o),
    denyReason: o.denyReason,
    qrSvg: o.status === "pending" ? await QRCode.toString(approvalUrl(o), { type: "svg", width: 160, margin: 1 }) : undefined,
    txHash: o.txHash,
  };
}

function buildServer() {
  const server = new McpServer({ name: "cartlock", version: "0.1.0" });

  server.registerResource("cartlock-widget", WIDGET_URI, {}, async () => ({
    contents: [{ uri: WIDGET_URI, mimeType: "text/html;profile=mcp-app", text: widgetHtml, _meta: { ui: { prefersBorder: true, csp: { connectDomains: [], resourceDomains: ["https://cdn.shopify.com"] } }, "openai/widgetCSP": { connect_domains: [], resource_domains: ["https://cdn.shopify.com"] }, "openai/widgetDescription": "Product options with Buy buttons and the World ID approval step." } }],
  }));

  server.registerTool(
    "search_products",
    {
      title: "Search products",
      description:
        "Use this when the user wants to buy a physical product. Searches real Shopify stores and shows 3-5 options with a Buy button. Never buy without the user pressing Buy and approving with World ID.",
      inputSchema: { query: z.string(), maxPriceUsd: z.number().optional() },
      annotations: { readOnlyHint: true, openWorldHint: true, destructiveHint: false },
      _meta: { ui: { resourceUri: WIDGET_URI }, "openai/outputTemplate": WIDGET_URI, "openai/widgetAccessible": true, "openai/toolInvocation/invoking": "Searching stores…" },
    },
    async ({ query, maxPriceUsd }) => {
      const found = await searchCatalog(query, maxPriceUsd ? Math.round(maxPriceUsd * 100) : undefined);
      return {
        structuredContent: { view: "options", query, offers: found },
        content: [{ type: "text", text: found.map((o, i) => `${i + 1}. ${o.title} — $${o.priceMinor / 100} (${o.merchant})`).join("\n") || "No results." }],
      };
    }
  );

  server.registerTool(
    "request_approval",
    {
      title: "Request human approval",
      description: "Called by the widget when the user presses Buy. Creates an order bound to this exact cart and asks the human to approve it.",
      inputSchema: { sku: z.string() },
      _meta: { ui: { visibility: ["app"] } },
    },
    async ({ sku }) => {
      const offer = offers.get(sku);
      if (!offer) throw new Error("Unknown product; search again.");
      const id = randomUUID();
      const expiresAt = Date.now() + 5 * 60_000;
      const order: Order = { id, offer, cartHash: cartHash(offer, id, expiresAt), status: "pending", expiresAt };
      await startWorldApproval(order);
      orders.set(id, order);
      return { structuredContent: { view: "approval", order: await orderView(order) }, content: [{ type: "text", text: `Waiting for approval of order ${id}.` }] };
    }
  );

  server.registerTool(
    "get_order",
    {
      title: "Get order status",
      description: "Polled by the widget while waiting for approval.",
      inputSchema: { orderId: z.string() },
      annotations: { readOnlyHint: true },
      _meta: { ui: { visibility: ["app"] } },
    },
    async ({ orderId }) => {
      const o = orders.get(orderId);
      if (!o) throw new Error("Unknown order");
      await advanceWorld(o);
      return { structuredContent: { view: "approval", order: await orderView(o) }, content: [{ type: "text", text: o.status }] };
    }
  );

  return server;
}

const app = express();
app.use(express.json());

app.post("/mcp", async (req, res) => {
  console.log(new Date().toISOString(), req.body?.method, req.body?.params?.name ?? req.body?.params?.uri ?? "");
  const server = buildServer();
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => {
    transport.close();
    server.close();
  });
  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
});
app.get("/mcp", (_req, res) => res.status(405).end());
mountHero(app, { searchCatalog, startWorldApproval, advanceWorld });

app.listen(PORT, () => console.log(`cartlock mcp on :${PORT}/mcp`));
