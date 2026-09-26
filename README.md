# Hero

**An AI shopping agent that spends from your own wallet — but only inside rules you wrote to ENS, and only with your fresh World ID approval when it matters.**

You tell Hero what you want (“a Sony 55-inch TV, must arrive within a month, never above $500, buy it yourself under $400”). The agent studies the price history and the sale calendar, decides *when* to buy, and buys from your wallet. No deposit into an agent wallet, no blank cheque: a smart contract enforces your policy on every purchase.

| Price the agent finds | What happens |
|---|---|
| ≤ `auto` ($400) | The agent buys on its own — only from a merchant in the ENS verified-merchant registry. |
| `auto` < price ≤ `max` | The agent must get **you**, a verified human, to approve **this exact order** with World ID, right now. |
| > `max` or over the category budget | Impossible. The contract reverts, whatever the agent was told. |

Built at ETHGlobal Tokyo 2026.

## Why

Agentic payments today give an LLM spending power and hope it behaves. Google's AP2 spec says it plainly: *preventing prompt injection is infeasible*, so mandates are signed off-chain and checked by the same stack the agent runs in. A poisoned product page or a swapped `payTo` in a 402 response is enough to move money.

Hero moves the guarantees on-chain:

- **The agent key cannot move funds.** It can only call `PolicySpender.buy*()`. The contract pulls USDC from the owner's wallet with a normal allowance, and only after checking the owner's ENS policy.
- **Policies live in ENSv2, not in our database.** `ps5.hobby.alice.eth` carries `auto`, `max`, `deadline`; `hobby.alice.eth` carries the monthly `limit` (and optional `pct` of balance). Any wallet or agent can read them; only the owner can change them.
- **Human approval is bound to a person and to an order.** A mid-band purchase needs a World ID for Agents confirmation from the owner's own World ID (same pairwise `sub` as at sign-in), no older than 5 minutes, signed over the exact order hash.

## How it works

```
 iPhone (SwiftUI)                   Backend (Node, agent)                     Ethereum Sepolia
 ────────────────                   ─────────────────────                     ────────────────
 Sign in with World ID ──OIDC──▶    World ID for Agents IdP  ── pairwise sub ─▶ setContinuity(owner, H(iss|sub))
 "Buy a TV, ≤$500, auto ≤$400" ──▶  Claude Haiku 4.5 (Bedrock) parses intent
                                    Shopify catalog search, price history,
                                    sale calendar → strategy
                                    writes policy ─────────────────────────────▶ ENSv2: tv-xxxx.hobby.herodemo.eth
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

- **Hierarchy = policy scope.** `herodemo.eth` → category subregistries (`hobby`, `needs`) → one subname per request. The contract derives the category from the request name and applies one shared monthly budget to every request under it.
- **Records = rules.** Numbers are stored as `data` records (`abi.encode(uint256)`) on a `PermissionedResolver` and read on-chain with `resolve(name, data(...))`. Missing record → 0 → the check fails closed.
- **Enhanced Access Control = what the agent may touch.** The agent holds a setter role for the `status` text record only. It can report "bought", it cannot raise `max` or `limit` (tested on a Sepolia fork against the deployed ENSv2 resolver code).
- **Subname expiry = request deadline**, plus a `deadline` record the contract enforces (expired ENSv2 subnames still resolve, so the contract does not rely on expiry alone).
- **Budgets reset without transactions.** Spending is keyed by 30-day period; a new period is a new counter. `pct` caps a category at a share of the current USDC balance, so a salary deposit raises the cap with no policy rewrite.
- **Merchants are an ENS registry too.** `hero-verified.eth` holds `data[<merchant address>] = 1`. Auto-band purchases only go to addresses listed there.

### World ID

- **Sign in with World ID (mandatory).** OIDC authorization code + PKCE against the World ID for Agents IdP. The first World ID to sign in becomes the owner; the pairwise `sub` is committed on-chain as the account's continuity id.
- **Fresh approval for important actions.** Mid-band purchases start an OIDC device authorization grant. The app shows the user code and opens the World ID page in-app. The backend validates the ID token (RS256/JWKS, issuer, audience, `auth_time` newer than the attempt, `acr` orb-v3) and checks `sub` against the owner. Declined, expired, or a different World ID → nothing is bought.
- **On-chain Proof of Human path (IDKit).** `buy()` also accepts a World ID 3.0 Orb proof verified by the World ID router on Sepolia, with the order hash as the signal and the owner's nullifier pinned in the account. This was verified end to end with simulator proofs.

## Live deployment (Ethereum Sepolia)

| | Address |
|---|---|
| PolicySpender | [`0x3dC4501cE0d266925F8de06ee3a8c0515125f197`](https://sepolia.etherscan.io/address/0x3dC4501cE0d266925F8de06ee3a8c0515125f197) |
| Owner (demo) | `0x73B30b7150D6cFf3EC35EF25a65E4b8625Cf4435` — `herodemo.eth` |
| Agent key | `0x79bbB630E4Ba04651cF8642697085E7b1f0AD823` |
| Verified merchant | `0xB4c42772dAeE7E4251bE9dc4782387C9881e6371` in `hero-verified.eth` |
| ENS resolver | `0x6D200830Fc9dfCc4Dd55B6c80CDE55f35Cc90856` |
| Payment token | MockUSDC `0x16f95d91dba7da3aca778ec053df0ff6c6a8aa8e` (6 decimals, open mint) |

Example transactions:
- Policy written for `mechanical-keyboard-d53e.needs.herodemo.eth`: [`0x8810ba18…`](https://sepolia.etherscan.io/tx/0x8810ba18a576d9b49a6ee4fec6b03187abeb907c2b326a2670071f0fb336bd4e)
- Auto-band purchase of a real Keychron listing for $49.99, paid from the owner's wallet: [`0x568f99ec…`](https://sepolia.etherscan.io/tx/0x568f99ec3e0d11682138b864e5aca9e5d184090b197ab22d6ac5f3af6d04993d)

All addresses: [`contracts/deployments/sepolia.json`](contracts/deployments/sepolia.json).

## Repository

```
contracts/   Foundry. PolicySpender + unit tests + Sepolia fork tests (real ENSv2, USDC, World ID router)
             script/SetupEns.s.sol (policy tree, merchant registry, agent role), script/Deploy.s.sol
backend/     Node/TypeScript. Agent API for the app (hero.ts), World ID for Agents OIDC (worldid.ts),
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
```

Backend `.env` (never committed): `SEPOLIA_RPC_URL`, `POLICY_SPENDER`, `USDC`, `WALLET_ADDRESS`, `DEPLOYER_PRIVATE_KEY` (owner, demo only), `AGENT_PRIVATE_KEY`, `MERCHANT_ADDRESS`, `MERCHANT_PRIVATE_KEY` (Hero Demo Merchant, signs receipts), `ALICE_RESOLVER`, `HOBBY_REGISTRY`, `NEEDS_REGISTRY`, `ENS_ROOT`, `WORLD_OIDC_CLIENT_ID`, `WORLD_OIDC_CLIENT_SECRET`, `HERO_ATTESTER_PRIVATE_KEY`, `AWS_BEARER_TOKEN_BEDROCK`, `AWS_REGION`, `BEDROCK_MODEL_ID`, and the IDKit `WORLD_*` values.

iOS: `cd ios && xcodegen generate && open Hero.xcodeproj`. Settings → turn off demo mode and point the backend URL at your server.

## Honest limits

- **The attester is trusted.** World ID for Agents returns an OIDC ID token (RS256), which the backend validates and turns into an EIP-712 approval. The contract checks the attester, the owner's continuity id, freshness and the order, but it cannot re-verify the IdP signature itself. The IDKit path (`buy()`) has no such trust: the proof is verified by the World ID router on-chain.
- **Single owner per deployment of the backend**, and the backend holds the demo owner key to write ENS records. In a real app the owner signs those writes in their wallet.
- **Testnet everything:** Sepolia, MockUSDC, World ID sandbox (mocked proofs), IDKit staging.

**What's real, what's simulated.** Real: the products and their current prices (live Shopify catalog), the ENS policy records, the World ID sign-in and approvals, and the payment itself: `PolicySpender` pulls MockUSDC from the owner's wallet to the merchant address listed in `hero-verified.eth` on Sepolia. Simulated: the price history (synthetic, seeded around the live price with dips on past sale dates) and the merchant. Hero does not check out at the Shopify store. The verified merchant address belongs to **Hero Demo Merchant**, whose key the backend holds. After each buy it reads the transaction receipt and requires a `PolicySpender` `Bought` event for this exact order hash (which binds the Shopify SKU), paying the merchant the exact amount. It then checks `verifiedMerchant` on-chain and signs an EIP-712 `Receipt` (order number, order and tx hashes, payer, payee, amount, item, store, `humanApproved`, paid-at). Every order is public at `GET /merchant/orders/:id` with that signature and its typed data, so anyone can recover the signer and compare it with the registry. The order shows the price paid on-chain next to the Shopify list price; they differ when the demo controls move the watched price. Confirmation, shipping and delivery run on a demo clock that compresses 7 days into 45 seconds (confirmed at 5 s, shipped at 20 s, delivered at 45 s), and every order is labelled `simulated`.
