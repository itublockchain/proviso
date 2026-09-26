// Product search and store comparison through Monid (api.monid.ai): Google Shopping (litescrape) + Amazon (axesso on Apify).
//
// Confirmed with live calls on 2026-09-27. Every call is POST https://api.monid.ai/v1/run, `Authorization: Bearer $MONID_API_KEY`,
// body {provider, endpoint, input: {queryParams?, body?}}.
//
// 1. litescrape /google/shopping: $0.00015/call, sync (~3 s, p95 18 s).
//    input {queryParams: {q, gl: "us", hl: "en", num: 40}}
//    -> 200 {runId, status: "COMPLETED", providerResponse: {httpStatus: 200}, billing: {reportedCost: {value: 150, unit: "MICRO_DOLLAR"}},
//       output: {shopping_results: [{position, title, price: "$549.99", extracted_price: 549.99, extracted_old_price?: 599,
//         source: "Walmart" (the store), rating?: 4.4, reviews?: 3800, thumbnail, second_hand_condition?: "refurbished",
//         gpcid, product_link (a google.com page), litescrape_product_link: {endpoint, queryParams}}]}}
// 2. litescrape /google/shopping-product: $0.00015/call, sync (~5 s, p95 9 s). Every store's offer for ONE product, with direct listing links.
//    input {queryParams: litescrape_product_link.queryParams from (1)}
//    -> {output: {product_result: {title, thumbnail}, offers: [{merchant: "Best Buy", title, price: "$649.99", extracted_price: 649.99,
//         link: "https://www.bestbuy.com/product/…", merchant_rating?: 4.6, availability?, delivery?}]}}
// 3. apify /axesso_data/amazon-search-scraper: $0.00015 per result (~16 results, so ~$0.0024/call), async (~19 s).
//    input {body: {input: [{keyword, domainCode: "com", maxPages: 1, sortBy: "relevanceblender", category: "aps"}]}}
//    -> 202 {runId, status: "RUNNING"}; poll GET /v1/runs/:runId until COMPLETED -> {cost: {value: 0.0024}, billedUnits: 16, output: [
//         {asin, productDescription (the title), price (0 = no buy box), retailPrice (0 = none), productRating: "4.6 out of 5 stars",
//          countReview, imgUrl, dpUrl (relative, tracking)}]}
// Traps seen in live data: rent-to-own rows ("$35.99" at Rent-A-Center), refurbished and pawn-shop listings, Amazon rows with price 0.
import { readFileSync, writeFileSync } from "node:fs";

export type Source = "google_shopping" | "amazon";
export type Offer = {
  sku: string; title: string; merchant: string; // merchant = the listing's origin (never a checkout URL)
  priceMinor: number; image?: string; source: Source; store: string; url: string;
  rating?: number; reviews?: number; listMinor?: number; // listMinor: the store's "usually"/retail price
  product?: Record<string, string>; // Google Shopping only: opens every store's offer for this product
};
type Opts = { minPriceUsd?: number; maxPriceUsd?: number; country?: "US"; fresh?: boolean };

const API = "https://api.monid.ai/v1";
const WAIT = 12_000; // how long a request waits per source; a slower run still finishes and fills the cache
const AMAZON_WAIT = 6_000; // Amazon (async, ~19 s) only gets this long once Google Shopping has offers
const TTL = 6 * 3600_000;
const MAX_CALLS = 200; // spend guard per process (worst case ~$1.5)
const DONE = ["COMPLETED", "FAILED", "BLOCKED", "STOPPED", "TIMED_OUT"];
let calls = 0, spent = 0;

async function run(provider: string, endpoint: string, input: object): Promise<any> {
  const key = process.env.MONID_API_KEY;
  if (!key) throw new Error("MONID_API_KEY is not set");
  if (++calls > MAX_CALLS) throw new Error(`spend guard: ${MAX_CALLS} calls this process`);
  const h = { authorization: `Bearer ${key}`, "content-type": "application/json" }, t0 = Date.now();
  let r = await (await fetch(`${API}/run`, { method: "POST", headers: h, body: JSON.stringify({ provider, endpoint, input }), signal: AbortSignal.timeout(60_000) })).json();
  while (!DONE.includes(r.status)) { // async providers (Apify): poll
    if (!r.runId || Date.now() - t0 > 120_000) throw new Error(`${endpoint}: ${r.error?.message ?? r.message ?? r.status ?? "no run"}`); // 402 low balance has no runId
    await new Promise((s) => setTimeout(s, 2000));
    r = await (await fetch(`${API}/runs/${r.runId}`, { headers: h, signal: AbortSignal.timeout(10_000) })).json();
  }
  spent += r.cost?.value ?? (r.billing?.reportedCost?.value ?? 0) / 1e6;
  console.log(`monid ${endpoint} ${r.status} ${Date.now() - t0}ms (total $${spent.toFixed(4)}, ${calls} calls)`);
  if (r.status !== "COMPLETED" || (r.providerResponse?.httpStatus ?? 200) >= 400) throw new Error(`${endpoint}: ${r.status} ${r.providerResponse?.httpStatus ?? ""}`);
  return r.output;
}

// Disk cache so pre-warmed stage queries are instant and survive restarts; in-flight runs are shared, never paid twice.
// ponytail: whole-file JSON rewrite per miss, fine for a few dozen queries.
const FILE = new URL("./.monid-cache.json", import.meta.url);
const cache: Record<string, { at: number; v: any }> = (() => { try { return JSON.parse(readFileSync(FILE, "utf8")); } catch { return {}; } })();
const inflight = new Map<string, Promise<any>>();
function cached<T>(key: string, fresh: boolean, f: () => Promise<T>): Promise<T> {
  const hit = cache[key];
  if (hit && !fresh && Date.now() - hit.at < TTL) return Promise.resolve(hit.v);
  if (inflight.has(key)) return inflight.get(key)!;
  const p = f().then((v) => { cache[key] = { at: Date.now(), v }; writeFileSync(FILE, JSON.stringify(cache)); return v; }).finally(() => inflight.delete(key));
  inflight.set(key, p);
  return p;
}
/** Resolves to undefined after `ms` (the run keeps going and still fills the cache) or on error. */
function within<T>(p: Promise<T>, ms = WAIT): Promise<T | undefined> {
  let t: any;
  return Promise.race([p.catch((e) => void console.error("monid", e.message)), new Promise<undefined>((s) => (t = setTimeout(s, ms)))]).finally(() => clearTimeout(t));
}

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
const origin = (u: string) => { try { return new URL(u).origin; } catch { return "https://shopping.google.com"; } };
const cents = (usd: number) => Math.round(usd * 100);
const dollars = (p: unknown) => !p || String(p).trim().startsWith("$"); // drops other currencies shown as "(£315)"
/** "Walmart - The Game Brain" and "gamestop.com" count as the same store as "Walmart" and "GameStop". */
const storeKey = (s: string) => norm(s.replace(/\s+-\s+.*$/, "").replace(/\.com$/i, ""));

export const fromGoogle = (rows: any[] = []): Offer[] => rows.flatMap((x): Offer[] => {
  const p = x.extracted_price;
  if (!(p > 0) || !x.title || !x.source || x.second_hand_condition || !dollars(x.price)) return [];
  return [{
    sku: `gshop:${x.gpcid ?? x.product_id ?? norm(`${x.source} ${x.title}`)}`, title: x.title, store: x.source, source: "google_shopping",
    priceMinor: cents(p), listMinor: x.extracted_old_price > p ? cents(x.extracted_old_price) : undefined,
    url: x.product_link, merchant: origin(x.product_link), image: x.thumbnail, rating: x.rating, reviews: x.reviews,
    product: x.litescrape_product_link?.queryParams,
  }];
});

export const fromAmazon = (rows: any[] = []): Offer[] => rows.flatMap((x): Offer[] => {
  if (!(x.price > 0) || !x.asin || !x.productDescription) return [];
  const url = `https://www.amazon.com/dp/${x.asin}`;
  return [{
    sku: `amazon:${x.asin}`, title: x.productDescription, store: "Amazon", source: "amazon", priceMinor: cents(x.price),
    listMinor: x.retailPrice > x.price ? cents(x.retailPrice) : undefined, url, merchant: origin(url), image: x.imgUrl,
    rating: parseFloat(x.productRating) || undefined, reviews: x.countReview || undefined,
  }];
});

const BAD = /refurb|renewed|\bused\b|open[ -]box|pre-?owned|rental|rent[ -]to[ -]own|without retail box|for parts/i;
const BAD_STORE = /rent-a-center|aaron'?s|acima|pawn|paymore|reperch|mercari|vip ?outlet|back ?market|swappa|decluttr/i; // rent-to-own, second-hand
const words = (q: string) => q.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 1);
/** Share of the query's words in the title; 0 without the first one (the brand or product name: a Samsung is not a Sony).
 *  Sizes are not required: Google Shopping titles usually leave them to the variant. */
const score = (query: string, title: string) => {
  const w = words(query), t = title.toLowerCase();
  return (w.length && !t.includes(w[0])) || otherSize(query, title) ? 0 : w.filter((x) => t.includes(x)).length / Math.max(1, w.length);
};
/** The title names a screen size ("43”", "43-inch") and it is not the query's ("55"). */
function otherSize(query: string, title: string) {
  const want = words(query).filter((w) => /^\d{2,3}$/.test(w));
  const got = [...title.matchAll(/\b(\d{2,3})\s*(?:"|”|''|-?\s?inch|-in\b)/gi)].map((m) => m[1]);
  return want.length > 0 && got.length > 0 && !got.some((g) => want.includes(g));
}

/** Relevant listings only (half the query's words, not an accessory-cheap price, not used/rental), the cheapest per title+store,
 *  in the sources' own relevance order (Google Shopping first): it beats word counting, which favors keyword-stuffed titles. */
export function rank(query: string, offers: Offer[], minPriceUsd = 0, maxPriceUsd = Infinity): Offer[] {
  const best = new Map<string, Offer>();
  for (const o of offers) {
    const usd = o.priceMinor / 100;
    if (usd < minPriceUsd || usd > maxPriceUsd || score(query, o.title) < 0.5 || BAD.test(o.title) || BAD_STORE.test(o.store)) continue;
    const k = `${norm(o.title)}|${storeKey(o.store)}`;
    if (!best.has(k) || best.get(k)!.priceMinor > o.priceMinor) best.set(k, o);
  }
  return [...best.values()];
}

/** Cheapest listing per store, cheapest store first. */
export function perStore(offers: Offer[]): Offer[] {
  const m = new Map<string, Offer>();
  for (const o of offers) if (!m.has(storeKey(o.store)) || m.get(storeKey(o.store))!.priceMinor > o.priceMinor) m.set(storeKey(o.store), o);
  return [...m.values()].sort((a, b) => a.priceMinor - b.priceMinor);
}

type StoreRow = { store: string; title: string; price: number; url: string; rating?: number };
const storeRows = (params: Record<string, string>, fresh = false) =>
  cached<StoreRow[]>(`product:${params.gpcid}`, fresh, () => run("litescrape", "/google/shopping-product", { queryParams: params }).then((o) =>
    (o?.offers ?? []).filter((x: any) => x.extracted_price > 0 && x.merchant && x.link && dollars(x.price))
      .map((x: any) => ({ store: x.merchant, title: x.title ?? "", price: x.extracted_price, url: x.link, rating: x.merchant_rating }))));

const google = (q: string, country: string, fresh: boolean) => cached<Offer[]>(`google_shopping:${country}:${norm(q)}`, fresh, () =>
  run("litescrape", "/google/shopping", { queryParams: { q, gl: country.toLowerCase(), hl: "en", num: 40 } }).then((o) => fromGoogle(o?.shopping_results)));
const amazon = (q: string, country: string, fresh: boolean) => cached<Offer[]>(`amazon:${country}:${norm(q)}`, fresh, () =>
  run("apify", "/axesso_data/amazon-search-scraper", { body: { input: [{ keyword: q, domainCode: "com", maxPages: 1, sortBy: "relevanceblender", category: "aps" }] } }).then(fromAmazon));

/** Live listings for a query from Google Shopping (many stores) and Amazon, merged, filtered and ranked (see `rank`). */
export async function searchProducts(query: string, { minPriceUsd = 0, maxPriceUsd = Infinity, country = "US", fresh = false }: Opts = {}): Promise<Offer[]> {
  const q = query.trim(), t0 = Date.now(), am = amazon(q, country, fresh);
  const [g, early] = await Promise.all([
    within(google(q, country, fresh).then((g) => { // open the likely pick's stores now, while Amazon still runs (compareStores finds it in flight)
      const top = rank(q, g, minPriceUsd, maxPriceUsd).find((o) => o.product);
      if (top) storeRows(top.product!, fresh).catch(() => {});
      return g;
    })),
    within(am, AMAZON_WAIT),
  ]);
  // with Google offers: take Amazon only if it is already done; without: Amazon gets the full wait
  const a = early ?? (await within(am, g?.length ? 0 : Math.max(0, WAIT - (Date.now() - t0))));
  return rank(q, [...(g ?? []), ...(a ?? [])], minPriceUsd, maxPriceUsd);
}

/** The best match's price at every store (same product, direct listing links) plus Amazon's matching listing,
 *  cheapest store first; falls back to the ranked search results. `fresh` re-checks prices (on demand only). */
export async function compareStores(query: string, found: Offer[], { minPriceUsd = 0, fresh = false }: Opts = {}): Promise<Offer[]> {
  const top = found.find((o) => o.product);
  const rows = top && (await within(storeRows(top.product!, fresh)));
  if (!top) return perStore(found);
  const like = (o: Offer) => o === top || score(top.title, o.title) >= 0.6;
  if (!rows?.length) return perStore(found.filter(like)); // stores not reachable in time: the search rows for this product
  const floor = Math.max(minPriceUsd, top.priceMinor / 200); // half the search price: not an accessory or a mislabeled row
  const same = rows.filter((x) => x.price >= floor && !otherSize(query, x.title) && !BAD.test(x.title) && !BAD_STORE.test(x.store)).map((x): Offer => ({
    ...top, sku: `${top.sku}:${storeKey(x.store).replace(/ /g, "-")}`, title: x.title || top.title, store: x.store,
    priceMinor: cents(x.price), url: x.url, merchant: origin(x.url), rating: x.rating, reviews: undefined,
  }));
  const amazon = found.filter((o) => o.source === "amazon" && o.priceMinor / 100 >= floor && like(o));
  return perStore([...same, ...amazon]);
}

/** `npm run prewarm`: refresh the cache for the stage queries, including every store for the likely picks at any budget. */
export async function prewarm(queries = ["Sony 55 inch 4K TV", "PlayStation 5 console", "mechanical keyboard", "LEGO Star Wars Millennium Falcon"]) {
  for (const q of queries) {
    const [g, a] = await Promise.all([google(q, "US", true).catch(() => []), amazon(q, "US", true).catch(() => [])]); // no timeout here
    const picks = rank(q, g).filter((o) => o.product).slice(0, 8); // the pick is the first of these inside the budget
    await Promise.all(picks.map((o) => storeRows(o.product!, true).catch(() => {})));
    console.log(`prewarmed "${q}": ${g.length} Google Shopping + ${a.length} Amazon listings, ${picks.length} products opened`);
  }
}
