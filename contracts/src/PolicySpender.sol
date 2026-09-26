// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

interface IWorldID {
    function verifyProof(
        uint256 root,
        uint256 groupId,
        uint256 signalHash,
        uint256 nullifierHash,
        uint256 externalNullifierHash,
        uint256[8] calldata proof
    ) external view;
}

/// ENSv2 PermissionedResolver: records are read by DNS-encoded name.
interface IResolver {
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory);
}

interface IDataResolver {
    function data(bytes32 node, string calldata key) external view returns (bytes memory);
}

/// @notice Lets an AI agent spend the owner's USDC straight from the owner's wallet (plain allowance, no deposit),
/// but only as the owner's ENSv2 policy tree allows. Policy tree: <request>.<category>.<root>, e.g. ps5.hobby.alice.eth
///   request  records: auto, max, deadline      (uint256 `data` records)
///   category records: limit (per 30 days), pct (optional cap as % of current balance)
/// price <= auto          -> agent buys alone, merchant must be verified in the merchant registry
/// auto < price <= max    -> also needs the owner's human approval of this exact order, either
///                           buy():         a World ID (IDKit) proof whose signal is the order hash, or
///                           buyApproved(): an EIP-712 HumanApproval from `attester`, the backend that validated a fresh
///                                          World ID for Agents (OIDC) login of the owner's linked World ID
/// price > max            -> never
contract PolicySpender {
    struct Account {
        bytes32 root; // namehash of the owner's policy root, e.g. alice.eth
        address resolver; // owner's PermissionedResolver holding the policy records
        address agent; // the only address allowed to call buy() for this owner
        uint256 human; // owner's World ID nullifier for this app+action; 0 = mid band disabled
    }

    struct Order {
        address payer;
        bytes request; // DNS-encoded request name
        address payTo;
        uint256 price; // USDC base units
        bytes32 sku;
        uint64 expiry;
        bytes32 salt;
    }

    struct Human {
        uint256 root;
        uint256 nullifier;
        uint256[8] proof;
    }

    uint256 public constant PERIOD = 30 days;
    uint256 public constant FRESHNESS = 5 minutes; // max age of the World ID authentication behind a buyApproved()
    bytes32 public constant HUMAN_APPROVAL_TYPEHASH =
        keccak256("HumanApproval(bytes32 orderHash,bytes32 continuity,uint64 authTime)");

    IERC20 public immutable usdc;
    IWorldID public immutable worldId;
    uint256 public immutable externalNullifier;
    IResolver public immutable merchantResolver;
    bytes public merchantRegistry; // DNS-encoded name whose `data` records mark verified merchants
    address public immutable attester; // backend key that signs HumanApproval after validating the owner's World ID
    address public immutable admin; // Proviso operator: may only switch accounts off (resetFor)

    /// owner => keccak256(iss "|" sub) of the owner's linked World ID for Agents subject; 0 = buyApproved mid band off
    mapping(address => bytes32) public continuity;

    mapping(address => Account) public accounts;
    /// owner => reset count; folded into the spend key, so a reset starts every category counter from 0
    mapping(address => uint256) public epoch;
    // Keyed by payer too: setAccount doesn't prove root ownership, so a shared key would let anyone burn alice's budget.
    /// payer => spendKey(epoch[payer], category node) => period => amount (read it with spentOf)
    mapping(address => mapping(bytes32 => mapping(uint256 => uint256))) public spent;
    mapping(bytes32 => bool) public used; // order hash => spent

    event AccountSet(address indexed owner, bytes32 root, address resolver, address agent, uint256 human);
    event ContinuitySet(address indexed owner, bytes32 continuity);
    event AccountReset(address indexed owner, uint256 epoch, address by);
    event Bought(
        address indexed payer, bytes32 indexed orderHash, bytes32 indexed category, address payTo, uint256 price, bool human
    );

    error NotAgent();
    error OrderUsed();
    error Expired();
    error NotYourPolicy();
    error OverMax();
    error OverBudget();
    error UnverifiedMerchant();
    error NotOwnerHuman();
    error StaleApproval();
    error BadApproval();
    error NotAdmin();

    constructor(
        IERC20 _usdc,
        IWorldID _worldId,
        string memory appId,
        string memory action,
        IResolver _merchantResolver,
        bytes memory _merchantRegistry,
        address _attester,
        address _admin
    ) {
        usdc = _usdc;
        worldId = _worldId;
        externalNullifier = hashToField(abi.encodePacked(hashToField(abi.encodePacked(appId)), action));
        merchantResolver = _merchantResolver;
        merchantRegistry = _merchantRegistry;
        attester = _attester;
        admin = _admin;
    }

    /// One-time setup by the owner, next to a USDC approve(this, cap).
    /// `human` is the owner's own World ID nullifier (stable per person per app+action). No proof is needed here:
    /// only msg.sender's own funds are at stake, and a wrong value just makes mid-band buys impossible.
    function setAccount(bytes32 root, address resolver, address agent, uint256 human) external {
        accounts[msg.sender] = Account(root, resolver, agent, human);
        emit AccountSet(msg.sender, root, resolver, agent, human);
    }

    /// Owner links their World ID for Agents subject (computed offchain from the validated ID token's iss and sub).
    function setContinuity(bytes32 c) external {
        continuity[msg.sender] = c;
        emit ContinuitySet(msg.sender, c);
    }

    /// EIP-2612 deadline that commits to a whole account config: top bit set (never expires in practice), low 255 bits
    /// = hash of (chain, this contract, owner, root, resolver, agent, continuity).
    function setupDeadline(address owner, bytes32 root, address resolver, address agent, bytes32 continuity_)
        public
        view
        returns (uint256)
    {
        return (uint256(1) << 255)
            | (uint256(keccak256(abi.encode(block.chainid, address(this), owner, root, resolver, agent, continuity_))) >> 1);
    }

    /// Gasless one-signature onboarding: the owner signs only a USDC permit(this, value); anyone (the Proviso operator)
    /// submits it here. The permit's deadline is setupDeadline(config), so the same signature also authorizes exactly
    /// this account config: change any field and the permit digest no longer recovers the owner. The permit nonce makes
    /// it single-use. Sets accounts[owner] = (root, resolver, agent, human 0) and continuity[owner] = continuity_.
    /// Known limitation: the permit is public once submitted, so a front-runner can call usdc.permit() directly and
    /// consume the nonce. Setup then reverts and the owner signs again; the griefer can neither change the config nor
    /// move funds (the allowance alone is useless without an account row naming the agent).
    function setupWithPermit(
        address owner,
        bytes32 root,
        address resolver,
        address agent,
        bytes32 continuity_,
        uint256 value,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        IERC20Permit(address(usdc)).permit(owner, address(this), value, setupDeadline(owner, root, resolver, agent, continuity_), v, r, s);
        accounts[owner] = Account(root, resolver, agent, 0);
        emit AccountSet(owner, root, resolver, agent, 0);
        continuity[owner] = continuity_;
        emit ContinuitySet(owner, continuity_);
    }

    /// Testnet / offboarding tool: wipes the caller's account row and World ID link and starts a new spend epoch
    /// (every category counter back to 0). Nothing can be spent afterwards until the owner re-authorizes with a fresh
    /// setupWithPermit signature (or setAccount). The USDC allowance is left as is; it is useless without an account row.
    function resetAccount() external {
        reset(msg.sender);
    }

    /// Same as resetAccount(), done by `admin` for `owner` (e.g. "start over" for a user who signed in with World ID).
    /// It can only switch an account off: the admin can never set an account, raise a budget or spend. The fresh epoch
    /// only takes effect once the OWNER signs a new setup, which is also what re-opens a full period budget.
    function resetFor(address owner) external {
        if (msg.sender != admin) revert NotAdmin();
        reset(owner);
    }

    function reset(address owner) internal {
        delete accounts[owner];
        delete continuity[owner];
        emit AccountReset(owner, ++epoch[owner], msg.sender);
    }

    function orderHash(Order calldata o) public pure returns (bytes32) {
        return keccak256(abi.encode(o));
    }

    function buy(Order calldata o, Human calldata h) external {
        (Account memory a, bytes32 hash, bool human) = check(o);
        if (human) {
            // only the owner's own World ID may approve (fails closed while a.human == 0)
            if (a.human == 0 || h.nullifier != a.human) revert NotOwnerHuman();
            worldId.verifyProof(h.root, 1, signalOf(hash), h.nullifier, externalNullifier, h.proof);
        }
        pay(o, a, hash, human);
    }

    /// Mid band approved through World ID for Agents: `attester` signed that the owner's linked World ID
    /// (continuity) freshly authenticated at `authTime` to approve this exact order.
    function buyApproved(Order calldata o, uint64 authTime, bytes calldata sig) external {
        (Account memory a, bytes32 hash, bool human) = check(o);
        if (human) {
            bytes32 c = continuity[o.payer];
            if (c == 0) revert NotOwnerHuman(); // no linked World ID: fail closed
            if (authTime > block.timestamp + 60 || authTime + FRESHNESS < block.timestamp) revert StaleApproval();
            // the signature covers the stored continuity, so an approval by any other World ID does not recover
            address signer = recover(approvalDigest(hash, c, authTime), sig);
            if (signer == address(0) || signer != attester) revert BadApproval();
        }
        pay(o, a, hash, human);
    }

    function approvalDigest(bytes32 hash, bytes32 c, uint64 authTime) public view returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PolicySpender"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(HUMAN_APPROVAL_TYPEHASH, hash, c, authTime))));
    }

    /// Checks shared by buy() and buyApproved(); marks the order used. `human`: price is in the mid band.
    function check(Order calldata o) internal returns (Account memory a, bytes32 hash, bool human) {
        a = accounts[o.payer];
        if (msg.sender != a.agent) revert NotAgent();
        hash = orderHash(o);
        if (used[hash]) revert OrderUsed();
        used[hash] = true;

        // The request must sit two levels under the owner's root: <request>.<category>.<root>
        uint256 catOff = 1 + uint8(o.request[0]);
        uint256 rootOff = catOff + 1 + uint8(o.request[catOff]);
        if (namehash(o.request, rootOff) != a.root) revert NotYourPolicy();

        // Missing records read as 0, so every check fails closed.
        if (block.timestamp > o.expiry || block.timestamp > num(a.resolver, o.request, "deadline")) revert Expired();
        if (o.price > num(a.resolver, o.request, "max")) revert OverMax();

        human = o.price > num(a.resolver, o.request, "auto");
        if (!human && !verifiedMerchant(o.payTo)) revert UnverifiedMerchant();
    }

    /// Category budget + transfer, after the human requirement (if any) is met.
    function pay(Order calldata o, Account memory a, bytes32 hash, bool human) internal {
        // Budget is recomputed at buy time: fills and salary changes need no policy rewrite.
        uint256 catOff = 1 + uint8(o.request[0]);
        bytes32 catNode = namehash(o.request, catOff);
        bytes32 key = spendKey(o.payer, catNode);
        uint256 period = block.timestamp / PERIOD; // new period = fresh counter, no reset tx
        uint256 total = spent[o.payer][key][period] + o.price;
        if (total > limit(a.resolver, o.request[catOff:], o.payer)) revert OverBudget();
        spent[o.payer][key][period] = total;

        require(usdc.transferFrom(o.payer, o.payTo, o.price), "transfer");
        emit Bought(o.payer, hash, catNode, o.payTo, o.price, human);
    }

    /// World ID signal hash for an order: the IDKit signal is the raw 32-byte orderHash.
    function signalOf(bytes32 hash) public pure returns (uint256) {
        return hashToField(abi.encodePacked(hash));
    }

    function remaining(bytes calldata categoryName, address owner) external view returns (uint256) {
        uint256 l = limit(accounts[owner].resolver, categoryName, owner);
        uint256 s = spentOf(owner, categoryName);
        return s >= l ? 0 : l - s;
    }

    /// What `owner` spent in this category (DNS-encoded name, e.g. hobby.alice.eth) this period, since the last reset.
    function spentOf(address owner, bytes calldata categoryName) public view returns (uint256) {
        return spent[owner][spendKey(owner, namehash(categoryName, 0))][block.timestamp / PERIOD];
    }

    function spendKey(address owner, bytes32 categoryNode) internal view returns (bytes32) {
        return keccak256(abi.encode(epoch[owner], categoryNode));
    }

    /// Category limit for this period, optionally capped at pct% of the owner's current balance.
    function limit(address resolver, bytes calldata categoryName, address owner) internal view returns (uint256 l) {
        l = num(resolver, categoryName, "limit");
        uint256 pct = num(resolver, categoryName, "pct");
        if (pct != 0) l = min(l, usdc.balanceOf(owner) * pct / 100);
    }

    function verifiedMerchant(address m) public view returns (bool) {
        return num(address(merchantResolver), merchantRegistry, toHex(m)) != 0;
    }

    function num(address resolver, bytes memory name, string memory key) internal view returns (uint256) {
        bytes memory v = abi.decode(
            IResolver(resolver).resolve(name, abi.encodeCall(IDataResolver.data, (bytes32(0), key))), (bytes)
        );
        return v.length == 0 ? 0 : abi.decode(v, (uint256));
    }

    function namehash(bytes memory name, uint256 off) internal pure returns (bytes32) {
        uint256 len = uint8(name[off]);
        if (len == 0) return 0;
        bytes memory label = new bytes(len);
        for (uint256 i; i < len; i++) label[i] = name[off + 1 + i];
        return keccak256(abi.encodePacked(namehash(name, off + 1 + len), keccak256(label)));
    }

    function hashToField(bytes memory b) internal pure returns (uint256) {
        return uint256(keccak256(b)) >> 8;
    }

    /// Lowercase 0x-hex, the key format used in the merchant registry.
    function toHex(address a) internal pure returns (string memory) {
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        for (uint256 i; i < 20; i++) {
            uint8 b = uint8(uint160(a) >> (8 * (19 - i)));
            s[2 + 2 * i] = bytes1(b >> 4 < 10 ? (b >> 4) + 48 : (b >> 4) + 87);
            s[3 + 2 * i] = bytes1(b & 15 < 10 ? (b & 15) + 48 : (b & 15) + 87);
        }
        return string(s);
    }

    /// ecrecover over a 65-byte (r, s, v) signature; rejects high-s (malleable) signatures and bad lengths.
    function recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(digest, uint8(sig[64]), r, s);
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }
}
