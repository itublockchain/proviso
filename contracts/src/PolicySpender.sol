// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
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
/// auto < price <= max    -> also needs a World ID proof whose signal is this exact order
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

    IERC20 public immutable usdc;
    IWorldID public immutable worldId;
    uint256 public immutable externalNullifier;
    IResolver public immutable merchantResolver;
    bytes public merchantRegistry; // DNS-encoded name whose `data` records mark verified merchants

    mapping(address => Account) public accounts;
    // Keyed by payer too: setAccount doesn't prove root ownership, so a shared key would let anyone burn alice's budget.
    mapping(address => mapping(bytes32 => mapping(uint256 => uint256))) public spent; // payer => category node => period => amount
    mapping(bytes32 => bool) public used; // order hash => spent

    event AccountSet(address indexed owner, bytes32 root, address resolver, address agent, uint256 human);
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

    constructor(
        IERC20 _usdc,
        IWorldID _worldId,
        string memory appId,
        string memory action,
        IResolver _merchantResolver,
        bytes memory _merchantRegistry
    ) {
        usdc = _usdc;
        worldId = _worldId;
        externalNullifier = hashToField(abi.encodePacked(hashToField(abi.encodePacked(appId)), action));
        merchantResolver = _merchantResolver;
        merchantRegistry = _merchantRegistry;
    }

    /// One-time setup by the owner, next to a USDC approve(this, cap).
    /// `human` is the owner's own World ID nullifier (stable per person per app+action). No proof is needed here:
    /// only msg.sender's own funds are at stake, and a wrong value just makes mid-band buys impossible.
    function setAccount(bytes32 root, address resolver, address agent, uint256 human) external {
        accounts[msg.sender] = Account(root, resolver, agent, human);
        emit AccountSet(msg.sender, root, resolver, agent, human);
    }

    function orderHash(Order calldata o) public pure returns (bytes32) {
        return keccak256(abi.encode(o));
    }

    function buy(Order calldata o, Human calldata h) external {
        Account memory a = accounts[o.payer];
        if (msg.sender != a.agent) revert NotAgent();
        bytes32 hash = orderHash(o);
        if (used[hash]) revert OrderUsed();
        used[hash] = true;

        // The request must sit two levels under the owner's root: <request>.<category>.<root>
        uint256 catOff = 1 + uint8(o.request[0]);
        uint256 rootOff = catOff + 1 + uint8(o.request[catOff]);
        if (namehash(o.request, rootOff) != a.root) revert NotYourPolicy();

        // Missing records read as 0, so every check fails closed.
        if (block.timestamp > o.expiry || block.timestamp > num(a.resolver, o.request, "deadline")) revert Expired();
        if (o.price > num(a.resolver, o.request, "max")) revert OverMax();

        bool human = o.price > num(a.resolver, o.request, "auto");
        if (human) {
            // only the owner's own World ID may approve (fails closed while a.human == 0)
            if (a.human == 0 || h.nullifier != a.human) revert NotOwnerHuman();
            worldId.verifyProof(h.root, 1, signalOf(hash), h.nullifier, externalNullifier, h.proof);
        } else if (!verifiedMerchant(o.payTo)) {
            revert UnverifiedMerchant();
        }

        // Budget is recomputed at buy time: fills and salary changes need no policy rewrite.
        bytes32 catNode = namehash(o.request, catOff);
        uint256 period = block.timestamp / PERIOD; // new period = fresh counter, no reset tx
        uint256 total = spent[o.payer][catNode][period] + o.price;
        if (total > limit(a.resolver, o.request[catOff:], o.payer)) revert OverBudget();
        spent[o.payer][catNode][period] = total;

        require(usdc.transferFrom(o.payer, o.payTo, o.price), "transfer");
        emit Bought(o.payer, hash, catNode, o.payTo, o.price, human);
    }

    /// World ID signal hash for an order: the IDKit signal is the raw 32-byte orderHash.
    function signalOf(bytes32 hash) public pure returns (uint256) {
        return hashToField(abi.encodePacked(hash));
    }

    function remaining(bytes calldata categoryName, address owner) external view returns (uint256) {
        uint256 l = limit(accounts[owner].resolver, categoryName, owner);
        uint256 s = spent[owner][namehash(categoryName, 0)][block.timestamp / PERIOD];
        return s >= l ? 0 : l - s;
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

    function min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x < y ? x : y;
    }
}
