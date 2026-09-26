# Proviso

**An AI shopping agent that spends from your own wallet — but only inside rules you wrote to ENS, and only with your fresh World ID approval when it matters.**

You tell Proviso what you want (“a Sony 55-inch TV, must arrive within a month, never above $500, buy it yourself under $400”). The agent compares live prices across stores, studies the price history and the sale calendar, decides *when* to buy, and buys from your wallet. No deposit into an agent wallet, no blank cheque: a smart contract enforces your policy on every purchase.

| Price the agent finds | What happens |
|---|---|
| ≤ `auto` ($400) | The agent buys on its own — only from a merchant in the ENS verified-merchant registry. |
| `auto` < price ≤ `max` | The agent must get **you**, a verified human, to approve **this exact order** with World ID, right now. |
| > `max` or over the category budget | Impossible. The contract reverts, whatever the agent was told. |

Built at ETHGlobal Tokyo 2026. Site: [proviso.site](https://proviso.site) (static, `site/`, deployed with Cloudflare Pages).

## Why

Agentic payments today give an LLM spending power and hope it behaves. Google's AP2 spec says it plainly: *preventing prompt injection is infeasible*, so mandates are signed off-chain and checked by the same stack the agent runs in. A poisoned product page or a swapped `payTo` in a 402 response is enough to move money.

Proviso moves the guarantees on-chain:

- **The agent key cannot move funds.** It can only call `PolicySpender.buy*()`. The contract pulls USDC from the owner's wallet with a normal allowance, and only after checking the owner's ENS policy.
- **Policies live in ENSv2, not in our database.** `ps5.hobby.alice.proviso.eth` carries `auto`, `max`, `deadline`; `hobby.alice.proviso.eth` carries the monthly `limit` (and optional `pct` of balance). Any wallet or agent can read them. The owner's wallet controls all of them and is the only one that can change a category `limit`; the Proviso operator key writes a request's `auto`/`max`/`deadline` when the owner saves that request in the app; the AI agent's key can only write `status`.
- **Human approval is bound to a person and to an order.** A mid-band purchase needs a World ID for Agents confirmation from the owner's own World ID (same pairwise `sub` as at sign-in), no older than 5 minutes, signed over the exact order hash.

## How it works

```
 iPhone (SwiftUI)                   Backend (Node, agent)                     Ethereum Sepolia
 ────────────────                   ─────────────────────                     ────────────────
 Sign in with World ID ──OIDC──▶    World ID for Agents IdP  ── pairwise sub ─▶ setContinuity(owner, H(iss|sub))
 "Buy a TV, ≤$500, auto ≤$400" ──▶  Claude Haiku 4.5 (Bedrock) parses intent
                                    live listings via Monid (Google Shopping
                                    + Amazon): every store's price for the
                                    pick; modeled history, sale calendar
                                    → strategy
                                    writes policy ─────────────────────────────▶ ENSv2: tv-xxxx.hobby.alice.proviso.eth
                                                                                   auto / max / deadline (data records)
                                    price drops into auto band ────────────────▶ PolicySpender.buy(order)
                                                                                   reads ENS, checks merchant + budget,
                                                                                   transferFrom(owner → merchant)
                                    price in approval band:
 "Confirm with World ID" ◀────────  device grant (fresh proof, user code)
 approve in World ID page ───────▶  validate ID token: sig, aud, auth_time,
                                    sub == owner → EIP-712 HumanApproval ──────▶ PolicySpender.buyApproved(order, authTime, sig)
                                                                                   checks attester, owner continuity,
                                                                                   freshness, order hash
```

### ENSv2 is the policy layer

- **Hierarchy = policy scope: `[item].[category].[username].proviso.eth`.** `proviso.eth` → one username per user (`<handle>.proviso.eth`, owned by the user's wallet, with the user's own resolver) → category subregistries (`hobby`, `needs`) → one registered subname per request, e.g. `playstation-5-653a.hobby.alice.proviso.eth`. After onboarding Proviso deploys the username's subregistry and the `hobby`/`needs` subregistries, off the onboarding path, and the user's wallet owns the category and request names. The Proviso-held demo wallet is just one more username, `alice.proviso.eth` (reserved). The contract derives the category from the request name and applies one shared monthly budget to every request under it.
- **Records = rules.** Numbers are stored as `data` records (`abi.encode(uint256)`) on a `PermissionedResolver` and read on-chain with `resolve(name, data(...))`. Missing record → 0 → the check fails closed.
- **Enhanced Access Control = who may write what.** Three keys, three scopes on each user's resolver (tested on a Sepolia fork against the deployed ENSv2 resolver code): the **owner's wallet** holds the root roles (everything, and the only writer of category `limit`); the **operator** may set only `auto`/`max`/`deadline` (data + text) and `description`; the **AI agent** may set only the `status` text record, so it can report what it is doing but cannot raise `max` or `limit`.
- **Live status on ENS.** Every change of a request (watching at $X, needs your World ID, blocked above max, bought with order number, expired) is written by the agent to that request's `status` record, and each category name carries what is left of its monthly budget (`$830 of $1000 left this period, resets …`). `description` repeats the rules plus that status, so explorer.ens.dev shows the whole state of a purchase on its name.
- **Subname expiry = request deadline.** Each request name is registered in its category's subregistry with expiry = deadline (owner = the payer, resolver = the payer's resolver), plus a `deadline` record the contract enforces (the contract reads the resolver directly, so it does not rely on expiry alone).
- **Readable in any ENS tool.** The contract reads only `data` records; Proviso mirrors them as text records so ENS tools show the policy (explorer.ens.dev displays the `description`; every key resolves through the Universal Resolver): `auto`, `max`, `deadline`, `description` on each request, `limit` and `description` on each category, `description`/`url` on `proviso.eth`, `alice.proviso.eth`, `verified.proviso.eth` and `agent.proviso.eth`. User resolvers grant the operator only those four request text keys (resolvers created before this grant keep data records only).
- **Budgets reset without transactions.** Spending is keyed by 30-day period; a new period is a new counter. `pct` caps a category at a share of the current USDC balance, so a salary deposit raises the cap with no policy rewrite.
- **The agent has a name too.** [`agent.proviso.eth`](https://explorer.ens.dev/agent.proviso.eth) resolves to the agent key (`addr`) and says in its `description` what that key may do: call `PolicySpender.buy`/`buyApproved` inside each owner's rules and write `status`, nothing else. On a user's resolver its only role is that `status` setter.
- **Merchants are an ENS registry too.** `verified.proviso.eth` holds `data[<merchant address>] = 1`. Auto-band purchases only go to addresses listed there.

### World ID

- **Sign in with World ID (mandatory).** OIDC authorization code + PKCE against the World ID for Agents IdP. Each World ID gets its own account (`<username>.proviso.eth`, its own wallet and resolver); the pairwise `sub` is committed on-chain as that account's continuity id. The ID token must carry `acr` = Orb (`https://world.org/oidc/acr/orb-v3`).
- **Fresh approval for important actions.** Mid-band purchases start an OIDC device authorization grant. The app shows the user code and opens the World ID page in-app. The backend validates the ID token (RS256/JWKS, issuer, audience, `auth_time` newer than the attempt, `acr` orb-v3) and checks `sub` against the owner. Declined, expired, or a different World ID → nothing is bought.
- **On-chain Proof of Human path (IDKit).** `buy()` also accepts a World ID 3.0 Orb proof verified by the World ID router on Sepolia, with the order hash as the signal and the owner's nullifier pinned in the account. This was verified end to end with simulator proofs.

## Live deployment (Ethereum Sepolia)

| | Address |
|---|---|
| PolicySpender | [`0x610803741c922384bcA07e40be3836E3191A9Fa6`](https://sepolia.etherscan.io/address/0x610803741c922384bcA07e40be3836E3191A9Fa6) (`setupWithPermit`: one gasless owner signature; `resetAccount`/`resetFor`: start over, see below; merchant registry `verified.proviso.eth`) |
| PolicySpender v3 (superseded, merchants in `hero-verified.eth`) | [`0x1F478b128b388486a20785b107Af7daD769685B8`](https://sepolia.etherscan.io/address/0x1F478b128b388486a20785b107Af7daD769685B8) |
| PolicySpender v2 (superseded) | [`0x4821452b64d70258c11acc2722c29fE934f0aB45`](https://sepolia.etherscan.io/address/0x4821452b64d70258c11acc2722c29fE934f0aB45) |
| PolicySpender v1 (superseded) | [`0x3dC4501cE0d266925F8de06ee3a8c0515125f197`](https://sepolia.etherscan.io/address/0x3dC4501cE0d266925F8de06ee3a8c0515125f197) |
| Owner (demo) | `0x73B30b7150D6cFf3EC35EF25a65E4b8625Cf4435` — `alice.proviso.eth` (the operator also owns `proviso.eth`) |
| ENS root | [`proviso.eth`](https://explorer.ens.dev/proviso.eth), registry `0x7B64a7118017572b38f7c880e13AeBA508cF98c1` |
| Agent key | `0x79bbB630E4Ba04651cF8642697085E7b1f0AD823` — [`agent.proviso.eth`](https://explorer.ens.dev/agent.proviso.eth) |
| Verified merchant | `0xB4c42772dAeE7E4251bE9dc4782387C9881e6371` in [`verified.proviso.eth`](https://explorer.ens.dev/verified.proviso.eth) |
| ENS resolver | `0x6D200830Fc9dfCc4Dd55B6c80CDE55f35Cc90856` |
| Payment token | MockUSDC `0x16f95d91dba7da3aca778ec053df0ff6c6a8aa8e` (6 decimals, open mint) |

Example transactions:
- Current contract deployed (merchant registry `verified.proviso.eth`): [`0x1a4b358e…`](https://sepolia.etherscan.io/tx/0x1a4b358e575c636acac6839dcb34b9bcb7c122157429d2a395e8a1e59792e9f5); `verified.proviso.eth` [`0x513458a6…`](https://sepolia.etherscan.io/tx/0x513458a6b4a0bd65151edda545c782c0cc79679b05b5af44c92655cd60923ba3) and `agent.proviso.eth` [`0x2dfff56a…`](https://sepolia.etherscan.io/tx/0x2dfff56a34598e46956e2c4b8e803221bdfa9ad24e7a3f859a3fbf0c9f135cce) registered; demo account on it: setAccount [`0x36f70b2d…`](https://sepolia.etherscan.io/tx/0x36f70b2d5641b0ecb40d453c4589847904b9a221a261c55906b5cbb1e7810f35)
- `proviso.eth` registered: [`0x4ec4d0b8…`](https://sepolia.etherscan.io/tx/0x4ec4d0b88315a571a3a9fadff3b27d66ee6ab36f24f25b3f48626361d45dadc9); demo account re-pointed to `alice.proviso.eth`: setAccount [`0x660b5009…`](https://sepolia.etherscan.io/tx/0x660b500942a27acb9cfb8c30a2e0ac3ef6f9e6d186200ee6f4e8d6c783c4abc9)
- Request name [`playstation-5-653a.hobby.alice.proviso.eth`](https://explorer.ens.dev/playstation-5-653a.hobby.alice.proviso.eth) registered with expiry = deadline: [`0x1e4caf0c…`](https://sepolia.etherscan.io/tx/0x1e4caf0c012e8e6c2fe3ca88e9827db15c440ab8c0403d2f0de338b1cd65bca9); auto-band buy for $279: [`0xfcde5b21…`](https://sepolia.etherscan.io/tx/0xfcde5b210755843ea023d1f0e8d953443599f7ad312e57b82fcdfe9415cb4cdc)
- Current contract deployed: [`0xe3d5ecfe…`](https://sepolia.etherscan.io/tx/0xe3d5ecfec81b69e6a0bee15040526b2c3ecc8ba71610a7425ba112ffa1320f8d); demo owner re-pointed to it: approve [`0x0d0ec841…`](https://sepolia.etherscan.io/tx/0x0d0ec841b80662cba2efaa5f902c8dfca63b5570ade0d3d5d13e437a2052ef2a), setAccount [`0x89485a1c…`](https://sepolia.etherscan.io/tx/0x89485a1c8cf591e133799964901609eda90ca528c64318507c8e9f6105605ab1)
- v2 deployed: [`0x8bd9df89…`](https://sepolia.etherscan.io/tx/0x8bd9df898af83dfb87a25ca691146d53e9163aa85195cd86c9885d1460d98afa)
- v1 (earlier root `herodemo.eth`): Policy written for `mechanical-keyboard-d53e.needs.herodemo.eth`: [`0x8810ba18…`](https://sepolia.etherscan.io/tx/0x8810ba18a576d9b49a6ee4fec6b03187abeb907c2b326a2670071f0fb336bd4e)
- v1: Auto-band purchase of a real Keychron listing for $49.99, paid from the owner's wallet: [`0x568f99ec…`](https://sepolia.etherscan.io/tx/0x568f99ec3e0d11682138b864e5aca9e5d184090b197ab22d6ac5f3af6d04993d)

All addresses: [`contracts/deployments/sepolia.json`](contracts/deployments/sepolia.json).

## Repository

```
contracts/   Foundry. PolicySpender + unit tests + Sepolia fork tests (real ENSv2, USDC, World ID router)
             script/SetupEns.s.sol (policy tree, merchant registry, agent role), script/Deploy.s.sol
backend/     Node/TypeScript. Agent API for the app (proviso.ts), World ID for Agents OIDC (worldid.ts),
             Bedrock LLM calls, chain writes. Also serves an MCP app for ChatGPT (server.ts, widget.ts).
ios/         SwiftUI, iOS 26. Requests, strategy, approvals, budgets. Demo mode works offline.
```

## Run it

```bash
# contracts
cd contracts && forge test                          # unit
FOUNDRY_PROFILE=fork forge test                     # against a Sepolia fork (needs SEPOLIA_RPC_URL)

# backend
cd backend && npm install && npm test
node --env-file=.env --import tsx server.ts          # :8787
npm run prewarm                                      # optional: cache the stage queries' listings (~$0.02 of Monid credit)
```

Backend `.env` (never committed): `SEPOLIA_RPC_URL`, `POLICY_SPENDER`, `USDC`, `WALLET_ADDRESS`, `DEPLOYER_PRIVATE_KEY` (owner, demo only), `AGENT_PRIVATE_KEY`, `MERCHANT_ADDRESS`, `MERCHANT_PRIVATE_KEY` (Proviso Demo Merchant, signs receipts), `ALICE_RESOLVER`, `HOBBY_REGISTRY`, `NEEDS_REGISTRY`, `ENS_ROOT`, `WORLD_OIDC_CLIENT_ID`, `WORLD_OIDC_CLIENT_SECRET`, `PROVISO_ATTESTER_PRIVATE_KEY`, `AWS_BEARER_TOKEN_BEDROCK`, `AWS_REGION`, `BEDROCK_MODEL_ID`, `MONID_API_KEY` (product search), and the IDKit `WORLD_*` values.

### Reset for testing

Run the whole flow again from zero with the **same wallet and the same World ID**:

- **In the app:** Settings → *Reset & start over* (`POST /api/dev/reset`, session required). You are signed out; sign in again and onboard with the same handle.
- **CLI:** `cd backend && npm run reset -- <wallet address | handle | all>` (`all` = every account not on the demo wallet). Works with the backend stopped (edits the state files) or running (goes through its loopback-only admin port, `PORT + 10`, so the running process cannot write the account back). Prints the tx hashes.

What a reset does: the operator key calls `PolicySpender.resetFor(wallet)` (account row + World ID link deleted, spend `epoch` + 1 so every category counter restarts at 0) and unregisters `<handle>.proviso.eth`; then the account's requests, approvals, orders, sessions and account row are deleted. The next onboarding deploys a fresh resolver (new setup nonce in its salt), so onboarding limits land in a clean policy tree. The Proviso-held demo wallet (`alice.proviso.eth`) is never reset on chain. `PROVISO_ALLOW_RESET=0` turns the endpoint off.

What the admin (`resetFor`) can and cannot do: it can only switch an account **off**. It cannot set an account, raise a limit, re-enable an agent or spend: after a reset nothing moves until the **owner** signs a fresh `setupWithPermit` (a new permit nonce, so an old signature cannot be replayed). Owners can do the same themselves with `resetAccount()`. The USDC allowance stays but is useless without an account row.

iOS: `cd ios && xcodegen generate && open Proviso.xcodeproj`. Settings → turn off demo mode and point the backend URL at your server.

## Honest limits

- **The attester is trusted.** World ID for Agents returns an OIDC ID token (RS256), which the backend validates and turns into an EIP-712 approval. The contract checks the attester, the owner's continuity id, freshness and the order, but it cannot re-verify the IdP signature itself. The IDKit path (`buy()`) has no such trust: the proof is verified by the World ID router on-chain.
- **The operator key writes each request's rules.** When you save a request in the app, Proviso's operator key (not the AI agent) writes its `auto`/`max`/`deadline` to your resolver, a setter role your one onboarding signature approved. So Proviso the service, unlike the agent, could set a request's bands up to your category `limit`; it can never change the `limit` itself, which only your wallet can. In a production app the owner would sign each request's record write in their wallet.
- **The merchant registry is Proviso's.** The operator key controls `verified.proviso.eth`, so Proviso decides which merchants the agent may pay on its own (auto band); mid-band payments still need the owner's World ID.
- **The onboarding signature commits to the account config as a hash.** One EIP-2612 permit fixes root, resolver, agent and World ID link through its `deadline` (a hash the contract recomputes); MetaMask shows the permit amount and spender, not those fields in clear.
- **The demo wallet is held by the backend** (`alice.proviso.eth`), so demo-mode buys come from a key Proviso holds; wallet-mode users keep their own keys.
- **Testnet everything:** Sepolia, MockUSDC, World ID sandbox (mocked proofs), IDKit staging.

**What's real, what's simulated.** Real: the products and their current prices (live listings via Monid: Google Shopping + Amazon, then every store's price for the chosen product, with direct listing links; cached for 6 hours and re-checked only on demand), the ENS policy records, the World ID sign-in and approvals, and the payment itself: `PolicySpender` pulls MockUSDC from the owner's wallet to the merchant address listed in `verified.proviso.eth` on Sepolia. Simulated: the price history (synthetic, seeded around the live price with dips on past sale dates; the app labels it "modeled") and the merchant. Proviso does not check out at the store (Best Buy, Walmart, …); the store row only opens its listing. The verified merchant address belongs to **Proviso Demo Merchant**, whose key the backend holds. After each buy it reads the transaction receipt and requires a `PolicySpender` `Bought` event for this exact order hash (which binds the listing's SKU), paying the merchant the exact amount. It then checks `verifiedMerchant` on-chain and signs an EIP-712 `Receipt` (order number, order and tx hashes, payer, payee, amount, item, store, `humanApproved`, paid-at). Every order is public at `GET /merchant/orders/:id` with that signature and its typed data, so anyone can recover the signer and compare it with the registry. The order shows the price paid on-chain next to the store's listed price; they differ when the demo controls move the watched price. Confirmation, shipping and delivery run on a demo clock that compresses 7 days into 45 seconds (confirmed at 5 s, shipped at 20 s, delivered at 45 s), and every order is labelled `simulated`.
