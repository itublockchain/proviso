# Integration feedback

Notes written during the hackathon, for the World and ENS teams.

## World ID for Agents (sandbox OIDC IdP)

**What we use it for.** Mandatory sign-in (authorization code + PKCE) that binds the app account to a pairwise `sub`, and a fresh device-grant confirmation before the agent may spend above the owner's auto-buy limit. The backend validates the ID token and signs an EIP-712 approval that our contract checks against the owner's `sub` hash.

**Time to first success.** About 25 minutes from reading the guides to a successful device-authorization request and `authorization_pending` polls against the sandbox. Reading the guides through the `/mcp` endpoint (`list_idp_guides`, `get_idp_guide`, no login) was the fastest way in.

**Friction.**
- The portal registers `client_secret_basic` by default. We had built for `client_secret_post` from the guide's examples and got `400 invalid_client` until we switched. Showing the chosen method next to the secret would save the round trip.
- The redirect hostname becomes the immutable sector. For a hackathon that means the tunnel domain you register first is permanent; we almost moved to a different tunnel and would have lost the sector. A warning at registration time would help.
- The approval page is a JavaScript-only app, so it cannot be checked with curl or a headless fetch during development.

**Missing capability.** A transaction-bound approval: today the device grant proves "the owner authenticated just now", and we bind it to an order ourselves (server state + our own EIP-712 signature). An optional `binding_message`/`authorization_details` shown to the user and echoed in the ID token (CIBA-style) would let the human see "Approve $449 at merchant X" in World ID itself and let a contract or downstream service verify that binding without trusting the relying party.

**The one improvement with the greatest impact.** Verifiable-on-chain output. An ES256/EdDSA-signed approval (or a ZK attestation) that a contract can check directly would remove the backend attester from the trust model for agent payments.

## IDKit / World ID 3.0 on-chain

**What we use it for.** An alternative mid-band path: a World ID 3.0 Orb proof (IDKit 4.3, `orbLegacy` preset, signal = order hash) verified by the World ID router on Ethereum Sepolia, with the owner's nullifier pinned in the account.

**Friction.**
- IDKit's WASM loader calls `fetch()` on a `file://` URL, which Node's fetch rejects; we patched `globalThis.fetch` to read the file from disk.
- The v4 verify endpoint answered `403 environment_not_allowed` for staging proofs until we opened a staging window with the Developer Portal MCP (`set_world_id_staging_verification`) and sent `x-staging-verification-token`.
- Staging connector links (`staging.world.org/verify?...`) do not open the public World App, and the public app is not available in every App Store region, so the simulator was the only way to complete staging proofs.
- Staging roots on the Sepolia router expire after an hour, so a proof must be used soon after it is produced.

**Missing documentation.** A single table of which environment (production / staging / sandbox) maps to which World App build, which chain's router, and which verify endpoint.

## ENSv2 (Sepolia)

**What we use it for.** The spending-policy tree (`<request>.<category>.herodemo.eth`), category subregistries, `data` records read on-chain by `PolicySpender`, an EAC setter role that lets the agent write only the `status` text record, and a merchant registry name.

**Friction.**
- The live Sepolia deployment matched a `deploy/sepolia-migration` branch rather than `main`; `authorizeTextRoles` / `setAlias` from `main` revert on Sepolia, while `grantSetterRoles` / `linkToNode` exist.
- `PermissionedResolver` has no direct `text(bytes32,string)`; reads go through `resolve(name, call)`. Easy once known, but it surprised every on-chain reader we wrote.
- Setter roles are scoped per record key across the whole resolver, not per name, so per-request isolation needs a resolver per category or per-request keys.
- An expired subname still resolves through its parent's resolver, so contracts must enforce their own deadlines.
- The UserRegistry implementation address is not in the published address list; we found it from factory `ProxyDeployed` logs.

**Most wanted.** A documented, cheap way for a contract to ask "is this name currently valid (not expired) and who owns it?" in one call.
