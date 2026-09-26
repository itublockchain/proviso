#!/usr/bin/env bash
# End-to-end check of "the user's own wallet" on a LOCAL Sepolia fork (no live transactions):
# sign-in (session fixture) -> /api/wallet/start -> /w/<t>/connect (permit typed data) -> the user's ONE signature (cast, fresh
# key with 0 ETH) -> /w/<t>/permit -> Hero sends everything -> ready -> request -> auto-band buy pulls MockUSDC from the user's
# wallet -> merchant order -> role and isolation checks. The user never sends a transaction.
#   ./e2e-wallet.sh      starts anvil :8551 (if not running) and a fresh backend :8791 (state in $STATE); leaves both running
# Stop: kill $(lsof -tiTCP:8791 -sTCP:LISTEN) $(lsof -tiTCP:8551 -sTCP:LISTEN)
set -euo pipefail
cd "$(dirname "$0")"
RPC=http://127.0.0.1:8551 API=http://127.0.0.1:8791 STATE=${STATE:-/tmp/hero-e2e}
SPENDER=0x4821452b64d70258c11acc2722c29fE934f0aB45 USDC=0x16f95d91dba7da3aca778ec053df0ff6c6a8aa8e
FACTORY=0x9e726Eb570beb6BCEb495AB8cdA7df517d4e841C REGISTRY=0x9817e00c0ac5478c60D7Bd0A6E55aee939d11aFa
OP=0x73B30b7150D6cFf3EC35EF25a65E4b8625Cf4435 AGENT=0x79bbB630E4Ba04651cF8642697085E7b1f0AD823 MERCHANT=0xB4c42772dAeE7E4251bE9dc4782387C9881e6371
ALL=0x1111111111111111111111111111111111111111111111111111111111111111

fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$(echo "$1" | tr A-F a-f)" = "$(echo "$2" | tr A-F a-f)" ] || fail "$3: got $1, want $2"; echo "ok  $3"; }
c() { cast "$@" --rpc-url $RPC; }
num() { c call "$@" | awk '{print $1}'; }
api() { local tok=$1 method=$2 path=$3; shift 3; curl -sS -X "$method" -H "authorization: Bearer $tok" -H 'content-type: application/json' "$API$path" "$@"; }
code() { local tok=$1 method=$2 path=$3; shift 3; curl -s -o /dev/null -w '%{http_code}' -X "$method" -H "authorization: Bearer $tok" -H 'content-type: application/json' "$API$path" "$@"; }
until_json() { # until_json <url> <jq-bool> <what>
  for _ in $(seq 60); do [ "$(curl -s "$1" | jq -r "$2")" = true ] && { echo "ok  $3"; return; }; sleep 2; done; fail "timeout: $3"; }

# --- fork + operator/agent gas (fork only) ---
if ! lsof -tiTCP:8551 -sTCP:LISTEN >/dev/null; then
  (set -a; . ./.env; exec nohup anvil --fork-url "$SEPOLIA_RPC_URL" --port 8551 --silent) >/tmp/hero-anvil.log 2>&1 &
  for _ in $(seq 30); do c block-number >/dev/null 2>&1 && break; sleep 1; done
fi
eq "$(c chain-id)" 11155111 "fork of Sepolia on :8551"
for a in $OP $AGENT; do c rpc anvil_setBalance $a 0x56BC75E2D63100000 >/dev/null; done

# --- backend :8791 on the fork, isolated state dir, two signed-in World IDs (session fixture: only sha256(token) on disk) ---
kill $(lsof -tiTCP:8791 -sTCP:LISTEN) 2>/dev/null || true
rm -rf "$STATE" && mkdir -p "$STATE"
read -r TA TB SUBB < <(node -e '
  const { createHash, randomBytes } = require("node:crypto"), now = Date.now(), out = {}, toks = [];
  for (const who of ["a", "b"]) {
    const t = randomBytes(32).toString("base64url"); toks.push(t);
    out[createHash("sha256").update(t).digest("hex")] = { iss: "https://sandbox.auth.world.org", sub: `e2e-${who}-${now}`, createdAt: now, authTime: Math.floor(now / 1000) };
  }
  require("node:fs").writeFileSync(process.argv[1] + "/.sessions.json", JSON.stringify(out));
  console.log(toks.join(" "), `e2e-b-${now}`);' "$STATE")
SEPOLIA_RPC_URL=$RPC PORT=8791 POLICY_SPENDER=$SPENDER HERO_STATE_DIR=$STATE HERO_REQUIRE_LOGIN=1 nohup node --env-file=.env --import tsx server.ts >/tmp/hero-e2e-8791.log 2>&1 &
for _ in $(seq 30); do curl -s $API/api/me >/dev/null && break; sleep 1; done

# --- the user: a fresh key, onboarding budgets before the wallet exists ---
USER_JSON=$(cast wallet new --json) UK=$(echo "$USER_JSON" | jq -r '.[0].private_key') U=$(echo "$USER_JSON" | jq -r '.[0].address')
echo "user wallet $U (fresh, fork only)"
eq "$(api $TA GET /api/me | jq -r .walletStatus)" none "new account starts with walletStatus none"
eq "$(code $TA PUT /api/budgets/Hobby -d '{"limitUsd":1500}')" 200 "onboarding budget stored before the resolver exists"
HANDLE=e2e$(openssl rand -hex 3)
START=$(api $TA POST /api/wallet/start -d "{\"handle\":\"$HANDLE\"}")
T=$(echo "$START" | jq -r .pageUrl | sed 's#.*/w/##')
echo "$START" | jq -r .url | grep -q "^https://link.metamask.io/dapp/.*/w/$T$" || fail "metamask deeplink"
eq "$(curl -s -o /dev/null -w '%{content_type}' $API/w/$T)" "text/html; charset=utf-8" "GET /w/<t> serves the page"

CONNECT=$(curl -sS -X POST -H 'content-type: application/json' $API/w/$T/connect -d "{\"address\":\"$U\"}")
ROOT=$(echo "$CONNECT" | jq -r .ensName)
eq "$ROOT" "$HANDLE.herodemo.eth" "connect -> ensName"
eq "$(echo "$CONNECT" | jq -r .mode)" permit "connect -> one permit to sign"
eq "$(echo "$CONNECT" | jq -r .chainId)" 0xaa36a7 "connect -> chainId"
TD=$(echo "$CONNECT" | jq -c .typedData)
eq "$(echo "$TD" | jq -r '[.primaryType, .domain.name, .domain.version, .domain.chainId, .message.owner, .message.value, .message.nonce] | join(",")' | tr A-F a-f)" \
  "$(echo "Permit,USDC,1,11155111,$U,4500000000,0" | tr A-F a-f)" "permit: MockUSDC domain, owner, value = sum of limits (1500 + 3000), nonce 0"
eq "$(echo "$TD" | jq -r .message.spender)" "$SPENDER" "permit spender = PolicySpender"
eq "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' $API/w/$T/connect -d '{"address":"0x000000000000000000000000000000000000dEaD"}')" 409 "connect with another address -> 409"

# the user's only action: one EIP-712 signature (what eth_signTypedData_v4 returns in MetaMask)
OTHER=$(cast wallet new --json | jq -r '.[0].private_key')
eq "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' $API/w/$T/permit -d "{\"signature\":\"$(cast wallet sign --private-key $OTHER --data "$TD")\"}")" 400 "permit signed by another key -> 400"
SIG=$(cast wallet sign --private-key $UK --data "$TD")
T0=$(date +%s)
eq "$(curl -sS -X POST -H 'content-type: application/json' $API/w/$T/permit -d "{\"signature\":\"$SIG\"}" | jq -r .ok)" true "POST /w/<t>/permit accepted (verified locally)"
eq "$(curl -s $API/w/$T/status | jq -r .signed)" true "status signed"
until_json $API/w/$T/status '.ready and .done.resolver and .done.name and .done.account' "status ready (resolver, name, setupWithPermit)"
echo "    ready after $(( $(date +%s) - T0 ))s; Hero's txs: $(curl -s $API/w/$T/status | jq -r '.txs | join(" ")')"
eq "$(c nonce $U)" 0 "the user sent no transaction"
eq "$(c balance $U)" 0 "the user needed no ETH"
eq "$(num $USDC 'nonces(address)(uint256)' $U)" 1 "permit nonce consumed"
STATUS=$(curl -s $API/w/$T/status)
RES=$(c call $SPENDER "accounts(address)(bytes32,address,address,uint256)" $U | sed -n 2p)
eq "$(api $TA GET /api/me | jq -r .walletStatus)" ready "/api/me walletStatus ready"
eq "$(api $TA GET /api/me | jq -r .wallet)" "$U" "/api/me wallet = user"
eq "$(c call $USDC 'allowance(address,address)(uint256)' $U $SPENDER | awk '{print $1}')" 4500000000 "permit allowance = sum of limits (1500 + 3000)"
for _ in $(seq 30); do [ "$(c call $REGISTRY 'getResolver(string)(address)' $HANDLE | tr A-F a-f)" = "$(echo $RES | tr A-F a-f)" ] && break; sleep 2; done
eq "$(c call $REGISTRY 'getResolver(string)(address)' $HANDLE)" "$RES" "$HANDLE.herodemo.eth -> user's resolver"
eq "$(num $RES 'roles(uint256,address)(uint256)' 0 $FACTORY)" 0 "factory holds no root roles"
eq "$(num $RES 'roles(uint256,address)(uint256)' 0 $OP)" 0 "operator holds no root roles"
eq "$(c call $RES 'roles(uint256,address)(uint256)' 0 $U | awk '{print $1}' | xargs cast to-hex)" 0x1111111111111111111111111111111111111111111111111111111111111111 "user holds all root roles"
HOBBY=$(node -e 'const n=process.argv[1];console.log("0x"+Buffer.concat([...n.split(".").map(l=>Buffer.concat([Buffer.from([l.length]),Buffer.from(l)])),Buffer.from([0])]).toString("hex"))' "hobby.$ROOT")
eq "$(num $SPENDER 'remaining(bytes,address)(uint256)' $HOBBY $U)" 1500000000 "hobby limit 1500 from onboarding is in the user's resolver"
eq "$(code $TA PUT /api/budgets/Hobby -d '{"limitUsd":900}')" 409 "PUT budgets after deploy -> 409 wallet_required"

# --- a request for this account, priced into the auto band: buy() pulls from the user's wallet ---
U0=$(num $USDC 'balanceOf(address)(uint256)' $U) M0=$(num $USDC 'balanceOf(address)(uint256)' $MERCHANT)
DEADLINE=$(node -e 'console.log(new Date(Date.now()+30*864e5).toISOString())')
REQ=$(api $TA POST /api/requests -d "{\"title\":\"E2E zzqx widget\",\"query\":\"zzqx e2e widget\",\"category\":\"Hobby\",\"autoUsd\":100,\"maxUsd\":200,\"deadline\":\"$DEADLINE\"}")
ID=$(echo "$REQ" | jq -r .id)
eq "$(echo "$REQ" | jq -r .ensName)" "$(echo "$REQ" | jq -r .ensName | cut -d. -f1).hobby.$ROOT" "request name under the user's root"
echo "    policy tx $(echo "$REQ" | jq -r '.activity[0].txHash')"
[ "$(echo "$REQ" | jq -r .status)" = bought ] || REQ=$(api $TA POST /api/requests/$ID/price -d '{"price":80}')
eq "$(echo "$REQ" | jq -r .status)" bought "auto-band buy"
P=$(echo "$REQ" | jq -r '.activity[] | select(.text|startswith("Bought")) | .text' | sed -E 's/Bought for \$([0-9]+).*/\1/')
BUY=$(echo "$REQ" | jq -r '.activity[] | select(.text|startswith("Bought")) | .txHash')
echo "    buy tx $BUY (\$$P): user MockUSDC $U0 -> $((U0 - P * 1000000)), merchant $M0 -> $((M0 + P * 1000000))"
eq "$(num $USDC 'balanceOf(address)(uint256)' $U)" "$((U0 - P * 1000000))" "user's MockUSDC down by the price"
eq "$(num $USDC 'balanceOf(address)(uint256)' $MERCHANT)" "$((M0 + P * 1000000))" "merchant's MockUSDC up by the price"
eq "$(c tx $BUY from)" "$AGENT" "buy() sent by the agent"
eq "$(curl -s $API/merchant/orders | jq -r --arg h $BUY '[.[] | select(.txHash == $h and .merchantVerified)] | length')" 1 "merchant order for this buy (verified merchant)"

# --- roles on the user's resolver ---
c rpc anvil_impersonateAccount $AGENT >/dev/null; c rpc anvil_impersonateAccount $OP >/dev/null
REQNAME=$(node -e 'const n=process.argv[1];console.log("0x"+Buffer.concat([...n.split(".").map(l=>Buffer.concat([Buffer.from([l.length]),Buffer.from(l)])),Buffer.from([0])]).toString("hex"))' "$(echo "$REQ" | jq -r .ensName)")
eq "$(c send --unlocked --from $AGENT $RES 'setText(bytes,string,string)' $REQNAME status e2e-agent --json | jq -r .status)" 0x1 "agent can set status text"
c send --unlocked --from $AGENT $RES 'setData(bytes,string,bytes)' $HOBBY limit $(cast abi-encode 'f(uint256)' 1) >/dev/null 2>&1 && fail "agent set limit" || echo "ok  agent cannot set limit (revert)"
c send --unlocked --from $OP $RES 'setData(bytes,string,bytes)' $HOBBY limit $(cast abi-encode 'f(uint256)' 9999000000) >/dev/null 2>&1 && fail "operator set limit" || echo "ok  operator cannot set limit (revert)"
c send --unlocked --from $OP $RES 'setText(bytes,string,string)' $REQNAME status x >/dev/null 2>&1 && fail "operator set status" || echo "ok  operator cannot set status (revert)"
c rpc anvil_setBalance $U 0xDE0B6B3A7640000 >/dev/null # a later self-service limit edit is the user's own tx and gas (fork only)
eq "$(c send --private-key $UK $RES 'setData(bytes,string,bytes)' $HOBBY limit $(cast abi-encode 'f(uint256)' 2000000000) --json | jq -r .status)" 0x1 "user can set limit"
eq "$(num $SPENDER 'remaining(bytes,address)(uint256)' $HOBBY $U)" "$((2000000000 - P * 1000000))" "new limit enforced by PolicySpender"

# --- isolation: the second World ID sees none of the first one's requests ---
eq "$(api $TB GET /api/requests | jq --arg id $ID '[.[]|select(.id==$id)]|length')" 0 "second account can't list the first's request"
eq "$(code $TB GET /api/requests/$ID)" 404 "second account can't read the first's request"
eq "$(code $TB POST /api/requests/$ID/price -d '{"price":1}')" 404 "second account can't reprice the first's request"
eq "$(api $TB GET /api/me | jq -r .walletStatus)" none "second account has its own (empty) wallet state"
# --- demo wallet: the second account picks "Use demo wallet" (Hero-held alice key) ---
eq "$(api $TB POST /api/wallet/demo | jq -r .walletStatus)" demo "demo wallet selected"
CB=$(cast keccak "https://sandbox.auth.world.org|$SUBB")
for _ in $(seq 30); do [ "$(c call $SPENDER 'continuity(address)(bytes32)' $OP)" = "$CB" ] && break; sleep 1; done
eq "$(c call $SPENDER 'continuity(address)(bytes32)' $OP)" "$CB" "demo selection sets alice's continuity to this World ID (new contract)"
A0=$(num $USDC 'balanceOf(address)(uint256)' $OP)
REQB=$(api $TB POST /api/requests -d "{\"title\":\"E2E zzqx gadget\",\"query\":\"zzqx e2e gadget\",\"category\":\"Hobby\",\"autoUsd\":100,\"maxUsd\":200,\"deadline\":\"$DEADLINE\"}")
eq "$(echo "$REQB" | jq -r .ensName | cut -d. -f2-)" hobby.herodemo.eth "demo request under herodemo.eth"
[ "$(echo "$REQB" | jq -r .status)" = bought ] || REQB=$(api $TB POST /api/requests/$(echo "$REQB" | jq -r .id)/price -d '{"price":70}')
eq "$(echo "$REQB" | jq -r .status)" bought "demo wallet auto-band buy"
eq "$(num $USDC 'balanceOf(address)(uint256)' $OP)" "$((A0 - 70000000))" "demo buy paid from alice's wallet"
eq "$(api $TA GET /api/requests | jq --arg id "$(echo "$REQB" | jq -r .id)" '[.[]|select(.id==$id)]|length')" 0 "first account can't see the demo account's request"
echo "e2e wallet: ok  (user $U, resolver $RES, root $ROOT)"
