#!/usr/bin/env bash
# End-to-end check of "the user's own wallet" on a LOCAL Sepolia fork (no live transactions):
# sign-in (session fixture) -> /api/wallet/start -> /w/<t>/connect (permit typed data) -> the user's ONE signature (cast, fresh
# key with 0 ETH) -> /w/<t>/permit -> Hero sends everything -> ready -> request -> auto-band buy pulls MockUSDC from the user's
# wallet -> merchant order -> role and isolation checks -> "Reset & start over" -> the same wallet, World ID and handle onboard
# again (fresh resolver, full budget) and buy -> the reset CLI. The user never sends a transaction.
#   ./e2e-wallet.sh      starts anvil :8551 (if not running) and a fresh backend :8791 (state in $STATE); leaves both running
# Stop: kill $(lsof -tiTCP:8791 -sTCP:LISTEN) $(lsof -tiTCP:8551 -sTCP:LISTEN)
set -euo pipefail
cd "$(dirname "$0")"
RPC=http://127.0.0.1:8551 API=http://127.0.0.1:8791 STATE=${STATE:-/tmp/hero-e2e}
SPENDER=0x1F478b128b388486a20785b107Af7daD769685B8 USDC=0x16f95d91dba7da3aca778ec053df0ff6c6a8aa8e
FACTORY=0x9e726Eb570beb6BCEb495AB8cdA7df517d4e841C REGISTRY=0x7B64a7118017572b38f7c880e13AeBA508cF98c1
OP=0x73B30b7150D6cFf3EC35EF25a65E4b8625Cf4435 AGENT=0x79bbB630E4Ba04651cF8642697085E7b1f0AD823 MERCHANT=0xB4c42772dAeE7E4251bE9dc4782387C9881e6371
ALL=0x1111111111111111111111111111111111111111111111111111111111111111

fail() { echo "FAIL: $*" >&2; exit 1; }
eq() { [ "$(echo "$1" | tr A-F a-f)" = "$(echo "$2" | tr A-F a-f)" ] || fail "$3: got $1, want $2"; echo "ok  $3"; }
c() { cast "$@" --rpc-url $RPC; }
num() { c call "$@" | awk '{print $1}'; }
api() { local tok=$1 method=$2 path=$3; shift 3; curl -sS -X "$method" -H "authorization: Bearer $tok" -H 'content-type: application/json' "$API$path" "$@"; }
code() { local tok=$1 method=$2 path=$3; shift 3; curl -s -o /dev/null -w '%{http_code}' -X "$method" -H "authorization: Bearer $tok" -H 'content-type: application/json' "$API$path" "$@"; }
dns() { node -e 'const n=process.argv[1];console.log("0x"+Buffer.concat([...n.split(".").map(l=>Buffer.concat([Buffer.from([l.length]),Buffer.from(l)])),Buffer.from([0])]).toString("hex"))' "$1"; }
UR=0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe ZERO=0x0000000000000000000000000000000000000000
text() { c call $UR 'resolve(bytes,bytes)(bytes,address)' "$(dns "$1")" "$(cast calldata 'text(bytes32,string)' 0x$(printf '0%.0s' {1..64}) "$2")" 2>/dev/null | head -1 | xargs cast abi-decode 'f()(string)' 2>/dev/null | sed 's/^"//; s/"$//'; }
until_text() { for _ in $(seq 30); do [ -n "$(text "$1" "$2")" ] && break; sleep 1; done; eq "$(text "$1" "$2")" "$3" "UR text $2 of $1"; }
settled() { # settled <token> <request json>: POST /api/requests answers at once; wait for its background setup
  local tok=$1 id; id=$(echo "$2" | jq -r .id)
  for _ in $(seq 120); do local r; r=$(api $tok GET /api/requests/$id); [ -z "$(echo "$r" | jq -r '.preparing // empty')" ] && { echo "$r"; return; }; sleep 1; done
  fail "setup of request $id never finished"; }
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
# session fixture: "signs in" <sub> by adding sha256(token) to $STATE/.sessions.json (backend stopped); prints the token
session() { node -e '
  const { createHash, randomBytes } = require("node:crypto"), fs = require("node:fs"), f = process.argv[1] + "/.sessions.json", now = Date.now();
  const out = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")) : {}, t = randomBytes(32).toString("base64url");
  out[createHash("sha256").update(t).digest("hex")] = { iss: "https://sandbox.auth.world.org", sub: process.argv[2], createdAt: now, authTime: Math.floor(now / 1000) };
  fs.writeFileSync(f, JSON.stringify(out));
  console.log(t);' "$STATE" "$1"; }
backend() {
  SEPOLIA_RPC_URL=$RPC PORT=8791 POLICY_SPENDER=$SPENDER HERO_STATE_DIR=$STATE HERO_REQUIRE_LOGIN=1 nohup node --env-file=.env --import tsx server.ts >>/tmp/hero-e2e-8791.log 2>&1 &
  for _ in $(seq 30); do curl -s $API/api/me >/dev/null && break; sleep 1; done; }
stop_backend() { kill $(lsof -tiTCP:8791 -sTCP:LISTEN) 2>/dev/null || true; while lsof -tiTCP:8791 -sTCP:LISTEN >/dev/null; do sleep 0.2; done; }
SUBA=e2e-a-$(date +%s) SUBB=e2e-b-$(date +%s)
TA=$(session $SUBA) TB=$(session $SUBB)
: >/tmp/hero-e2e-8791.log
backend

# --- the user: a fresh key, onboarding budgets before the wallet exists ---
USER_JSON=$(cast wallet new --json) UK=$(echo "$USER_JSON" | jq -r '.[0].private_key') U=$(echo "$USER_JSON" | jq -r '.[0].address')
echo "user wallet $U (fresh, fork only)"
eq "$(api $TA GET /api/me | jq -r .walletStatus)" none "new account starts with walletStatus none"
eq "$(code $TA PUT /api/budgets/Hobby -d '{"limitUsd":1500}')" 200 "onboarding budget stored before the resolver exists"
HANDLE=e2e$(openssl rand -hex 3)
eq "$(code $TA POST /api/wallet/start -d '{"handle":"alice"}')" 400 "the demo username alice is reserved"
START=$(api $TA POST /api/wallet/start -d "{\"handle\":\"$HANDLE\"}")
T=$(echo "$START" | jq -r .pageUrl | sed 's#.*/w/##')
echo "$START" | jq -r .url | grep -q "^https://link.metamask.io/dapp/.*/w/$T$" || fail "metamask deeplink"
eq "$(curl -s -o /dev/null -w '%{content_type}' $API/w/$T)" "text/html; charset=utf-8" "GET /w/<t> serves the page"

CONNECT=$(curl -sS -X POST -H 'content-type: application/json' $API/w/$T/connect -d "{\"address\":\"$U\"}")
ROOT=$(echo "$CONNECT" | jq -r .ensName)
eq "$ROOT" "$HANDLE.proviso.eth" "connect -> ensName"
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
echo "    ready after $(( $(date +%s) - T0 ))s; Proviso's txs: $(curl -s $API/w/$T/status | jq -r '.txs | join(" ")')"
eq "$(c nonce $U)" 0 "the user sent no transaction"
eq "$(c balance $U)" 0 "the user needed no ETH"
eq "$(num $USDC 'nonces(address)(uint256)' $U)" 1 "permit nonce consumed"
STATUS=$(curl -s $API/w/$T/status)
RES=$(c call $SPENDER "accounts(address)(bytes32,address,address,uint256)" $U | sed -n 2p)
eq "$(api $TA GET /api/me | jq -r .walletStatus)" ready "/api/me walletStatus ready"
eq "$(api $TA GET /api/me | jq -r .wallet)" "$U" "/api/me wallet = user"
eq "$(c call $USDC 'allowance(address,address)(uint256)' $U $SPENDER | awk '{print $1}')" 4500000000 "permit allowance = sum of limits (1500 + 3000)"
for _ in $(seq 30); do [ "$(c call $REGISTRY 'getResolver(string)(address)' $HANDLE | tr A-F a-f)" = "$(echo $RES | tr A-F a-f)" ] && break; sleep 2; done
eq "$(c call $REGISTRY 'getResolver(string)(address)' $HANDLE)" "$RES" "$HANDLE.proviso.eth -> user's resolver"
eq "$(num $RES 'roles(uint256,address)(uint256)' 0 $FACTORY)" 0 "factory holds no root roles"
eq "$(num $RES 'roles(uint256,address)(uint256)' 0 $OP)" 0 "operator holds no root roles"
eq "$(c call $RES 'roles(uint256,address)(uint256)' 0 $U | awk '{print $1}' | xargs cast to-hex)" 0x1111111111111111111111111111111111111111111111111111111111111111 "user holds all root roles"
HOBBY=$(node -e 'const n=process.argv[1];console.log("0x"+Buffer.concat([...n.split(".").map(l=>Buffer.concat([Buffer.from([l.length]),Buffer.from(l)])),Buffer.from([0])]).toString("hex"))' "hobby.$ROOT")
eq "$(num $SPENDER 'remaining(bytes,address)(uint256)' $HOBBY $U)" 1500000000 "hobby limit 1500 from onboarding is in the user's resolver"
eq "$(code $TA PUT /api/budgets/Hobby -d '{"limitUsd":900}')" 409 "PUT budgets after deploy -> 409 wallet_required"

# --- a request for this account, priced into the auto band: buy() pulls from the user's wallet ---
U0=$(num $USDC 'balanceOf(address)(uint256)' $U) M0=$(num $USDC 'balanceOf(address)(uint256)' $MERCHANT)
DEADLINE=$(node -e 'console.log(new Date(Date.now()+30*864e5).toISOString())')
eq "$(api $TA POST /api/requests -d "{\"title\":\"x\",\"query\":\"x\",\"category\":\"Hobby\",\"autoUsd\":300,\"maxUsd\":200,\"deadline\":\"$DEADLINE\"}" | jq -r .message)" '"Buys on its own" ($300) can'"'"'t be above "asks you up to" ($200).' "a bad draft is refused with a readable reason"
REQ=$(api $TA POST /api/requests -d "{\"title\":\"E2E zzqx widget\",\"query\":\"zzqx e2e widget\",\"category\":\"Hobby\",\"autoUsd\":100,\"maxUsd\":200,\"deadline\":\"$DEADLINE\"}")
eq "$(echo "$REQ" | jq -r .preparing)" "Comparing stores" "POST /api/requests answers before the slow setup"
REQ=$(settled $TA "$REQ")
eq "$(echo "$REQ" | jq -r '.setupError // "none"')" none "setup finished without errors"
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

# --- the request name is registered in the user's own tree (expiry = deadline) and mirrors the policy as text records ---
NAME=$(echo "$REQ" | jq -r .ensName) LABEL=$(echo "$REQ" | jq -r .ensName | cut -d. -f1)
TOP=$(c call $REGISTRY 'getSubregistry(string)(address)' $HANDLE)
CAT=$(c call $TOP 'getSubregistry(string)(address)' hobby 2>/dev/null || echo $ZERO)
[ "$TOP" != $ZERO ] && [ "$CAT" != $ZERO ] && echo "ok  per-user tree: $HANDLE -> $TOP, hobby -> $CAT" || fail "per-user tree"
eq "$(c call $CAT 'findOwner(string)(address)' $LABEL)" "$U" "request name registered, owned by the user"
eq "$(c call $CAT 'getResolver(string)(address)' $LABEL)" "$RES" "request name resolver = the user's"
eq "$(num $CAT 'findExpiry(string)(uint64)' $LABEL)" "$(node -e 'console.log(Math.floor(Date.parse(process.argv[1])/1000))' "$DEADLINE")" "request name expiry = deadline"
for _ in $(seq 40); do [ -n "$(text "$NAME" status)" ] && [ -n "$(text "$NAME" description)" ] && break; sleep 1; done
DESC=$(text "$NAME" description) ST=$(text "$NAME" status)
eq "${DESC%%. Now: *}" "Proviso policy: buys on its own up to \$100, asks the owner up to \$200, until ${DEADLINE:0:10}" "UR text description = the rules"
eq "${DESC#*. Now: }" "$ST" "description ends with the agent's live status ($ST)"
for _ in $(seq 40); do [ -n "$(text "hobby.$ROOT" status)" ] && break; sleep 1; done
CS=$(text "hobby.$ROOT" status); case "$CS" in *"left this period"*) echo "ok  hobby.$ROOT status: $CS";; *) fail "category status: $CS";; esac
eq "$(text "$NAME" max)" "200 USDC" "UR text max"
eq "$(text "hobby.$ROOT" limit)" "1500 USDC" "UR text limit on the category (resolver initializer)"

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
eq "$(echo "$REQB" | jq -r .ensName | cut -d. -f2-)" hobby.alice.proviso.eth "demo request under the demo username: <item>.hobby.alice.proviso.eth"
REQB=$(settled $TB "$REQB")
[ "$(echo "$REQB" | jq -r .status)" = bought ] || REQB=$(api $TB POST /api/requests/$(echo "$REQB" | jq -r .id)/price -d '{"price":70}')
eq "$(echo "$REQB" | jq -r .status)" bought "demo wallet auto-band buy"
eq "$(num $USDC 'balanceOf(address)(uint256)' $OP)" "$((A0 - 70000000))" "demo buy paid from alice's wallet"
eq "$(api $TA GET /api/requests | jq --arg id "$(echo "$REQB" | jq -r .id)" '[.[]|select(.id==$id)]|length')" 0 "first account can't see the demo account's request"
LB=$(echo "$REQB" | jq -r .ensName | cut -d. -f1) HOBBYREG=$(c call $(c call $REGISTRY 'getSubregistry(string)(address)' alice) 'getSubregistry(string)(address)' hobby)
eq "$(num $HOBBYREG 'findExpiry(string)(uint64)' $LB)" "$(node -e 'console.log(Math.floor(Date.parse(process.argv[1])/1000))' "$DEADLINE")" "demo request name registered under hobby.alice.proviso.eth, expiry = deadline"
until_text "$(echo "$REQB" | jq -r .ensName)" auto "100 USDC"

# --- "Reset & start over": the same wallet + World ID + handle from zero ---
RESET=$(api $TA POST /api/dev/reset)
eq "$(echo "$RESET" | jq -r '[.ok, .reset.chain, .reset.ens, .reset.requests, .reset.orders] | join(",")')" "true,true,$ROOT,1,1" "POST /api/dev/reset: resetFor + ENS name + 1 request + 1 order"
echo "    reset txs: $(echo "$RESET" | jq -r '.reset.txs | join(" ")')"
eq "$(code $TA GET /api/me)" 401 "the session ends with the reset"
eq "$(c call $SPENDER 'accounts(address)(bytes32,address,address,uint256)' $U | sed -n 3p)" 0x0000000000000000000000000000000000000000 "account row wiped on chain (no agent)"
eq "$(num $SPENDER 'epoch(address)(uint256)' $U)" 1 "epoch 1"
eq "$(c call $REGISTRY 'getResolver(string)(address)' $HANDLE)" 0x0000000000000000000000000000000000000000 "$HANDLE.proviso.eth unregistered"
eq "$(c call $REGISTRY 'getSubregistry(string)(address)' $HANDLE)" $ZERO "its request tree is unreachable"
eq "$(text "$NAME" max)" "" "old request name no longer resolves"
eq "$(api $TB GET /api/me | jq -r .walletStatus)" demo "other accounts untouched"

stop_backend && TA=$(session $SUBA) && backend # the same World ID signs in again
eq "$(api $TA GET /api/me | jq -r .walletStatus)" none "same World ID: a fresh account"
eq "$(code $TA PUT /api/budgets/Hobby -d '{"limitUsd":1500}')" 200 "onboarding budget again"
T=$(api $TA POST /api/wallet/start -d "{\"handle\":\"$HANDLE\"}" | jq -r .pageUrl | sed 's#.*/w/##')
CONNECT=$(curl -sS -X POST -H 'content-type: application/json' $API/w/$T/connect -d "{\"address\":\"$U\"}")
eq "$(echo "$CONNECT" | jq -r .ensName)" "$ROOT" "the same handle is free again"
TD=$(echo "$CONNECT" | jq -c .typedData)
eq "$(echo "$TD" | jq -r .message.nonce)" 1 "second permit (nonce 1)"
eq "$(curl -sS -X POST -H 'content-type: application/json' $API/w/$T/permit -d "{\"signature\":\"$(cast wallet sign --private-key $UK --data "$TD")\"}" | jq -r .ok)" true "same wallet signs again"
until_json $API/w/$T/status '.ready and .done.resolver and .done.name and .done.account' "ready again"
RES2=$(c call $SPENDER "accounts(address)(bytes32,address,address,uint256)" $U | sed -n 2p)
[ "$(echo $RES2 | tr A-F a-f)" != "$(echo $RES | tr A-F a-f)" ] && echo "ok  fresh resolver $RES2 (old $RES)" || fail "resolver reused"
for _ in $(seq 30); do [ "$(c call $REGISTRY 'getResolver(string)(address)' $HANDLE | tr A-F a-f)" = "$(echo $RES2 | tr A-F a-f)" ] && break; sleep 2; done
eq "$(c call $REGISTRY 'getResolver(string)(address)' $HANDLE)" "$RES2" "$HANDLE.proviso.eth -> the new resolver"
eq "$(num $SPENDER 'spentOf(address,bytes)(uint256)' $U $HOBBY)" 0 "spend counter back to 0 in the same period"
eq "$(num $SPENDER 'remaining(bytes,address)(uint256)' $HOBBY $U)" 1500000000 "full hobby budget again"
REQ=$(api $TA POST /api/requests -d "{\"title\":\"E2E zzqx widget again\",\"query\":\"zzqx e2e widget\",\"category\":\"Hobby\",\"autoUsd\":100,\"maxUsd\":200,\"deadline\":\"$DEADLINE\"}")
REQ=$(settled $TA "$REQ")
[ "$(echo "$REQ" | jq -r .status)" = bought ] || REQ=$(api $TA POST /api/requests/$(echo "$REQ" | jq -r .id)/price -d '{"price":80}')
eq "$(echo "$REQ" | jq -r .status)" bought "auto-band buy after the reset"
TOP2=$(c call $REGISTRY 'getSubregistry(string)(address)' $HANDLE)
[ "$TOP2" != $ZERO ] && [ "$TOP2" != "$TOP" ] && echo "ok  fresh request tree $TOP2 (old $TOP)" || fail "request tree after reset: $TOP2"
eq "$(c call $(c call $TOP2 'getSubregistry(string)(address)' hobby) 'findOwner(string)(address)' $(echo "$REQ" | jq -r .ensName | cut -d. -f1))" "$U" "request name registered again"
P2=$(echo "$REQ" | jq -r '.activity[] | select(.text|startswith("Bought")) | .text' | sed -E 's/Bought for \$([0-9]+).*/\1/')
echo "    buy tx $(echo "$REQ" | jq -r '.activity[] | select(.text|startswith("Bought")) | .txHash') (\$$P2)"
eq "$(num $SPENDER 'remaining(bytes,address)(uint256)' $HOBBY $U)" "$((1500000000 - P2 * 1000000))" "budget counts only the new buy"

# --- the CLI, while the backend runs (loopback admin port) ---
OUT=$(SEPOLIA_RPC_URL=$RPC PORT=8791 POLICY_SPENDER=$SPENDER HERO_STATE_DIR=$STATE node --env-file=.env --import tsx reset.ts $U)
echo "$OUT" | sed 's/^/    /'
echo "$OUT" | grep -q "via the running backend" && echo "$OUT" | grep -q "resetFor sent" && echo "$OUT" | grep -q "$ROOT unregistered" || fail "npm run reset -- <wallet>"
eq "$(num $SPENDER 'epoch(address)(uint256)' $U)" 2 "CLI reset: epoch 2"
eq "$(code $TA GET /api/me)" 401 "CLI reset ends the session"
echo "e2e wallet: ok  (user $U, resolver $RES -> $RES2, root $ROOT)"
