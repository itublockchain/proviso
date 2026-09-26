// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PolicySpender, IERC20, IWorldID, IResolver} from "../src/PolicySpender.sol";

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external { balanceOf[to] += v; }
    function approve(address s, uint256 v) external returns (bool) { allowance[msg.sender][s] = v; return true; }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }

    // EIP-2612, same domain as the live MockUSDC (OZ ERC20Permit "USDC", version "1")
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    mapping(address => uint256) public nonces;

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("USDC"), keccak256("1"), block.chainid, address(this)
        ));
    }

    function permitDigest(address o, address s, uint256 v, uint256 n, uint256 d) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), keccak256(abi.encode(PERMIT_TYPEHASH, o, s, v, n, d))));
    }

    function permit(address o, address s, uint256 v, uint256 d, uint8 pv, bytes32 r, bytes32 ps) external {
        require(block.timestamp <= d, "expired");
        address signer = ecrecover(permitDigest(o, s, v, nonces[o]++, d), pv, r, ps);
        require(signer != address(0) && signer == o, "invalid signature");
        allowance[o][s] = v;
    }
}

/// Mimics PermissionedResolver.resolve(name, data(node,key)) over uint256 data records.
contract MockResolver {
    mapping(bytes32 => mapping(string => bytes)) rec;

    function set(bytes memory name, string memory key, uint256 v) external { rec[keccak256(name)][key] = abi.encode(v); }

    function resolve(bytes calldata name, bytes calldata call) external view returns (bytes memory) {
        (, string memory key) = abi.decode(call[4:], (bytes32, string));
        return abi.encode(rec[keccak256(name)][key]);
    }
}

contract MockWorldID {
    bytes32 public accepted; // the only signal hash we accept

    function accept(uint256 signalHash) external { accepted = bytes32(signalHash); }

    function verifyProof(uint256, uint256 g, uint256 s, uint256, uint256, uint256[8] calldata) external view {
        require(g == 1 && bytes32(s) == accepted, "invalid proof");
    }
}

bytes32 constant DIGEST_FROM_VIEM = 0xae622ad70332e73a8e692898629dbd94b2fed8db702988a0cfef992aed58da55;

contract PolicySpenderTest is Test {
    MockUSDC usdc = new MockUSDC();
    MockResolver res = new MockResolver();
    MockWorldID world = new MockWorldID();
    PolicySpender ps;
    uint256 constant ALICE_HUMAN = 42;
    uint256 constant ATTESTER_PK = 0xA77E57;
    bytes32 constant ALICE_WORLD = keccak256("https://sandbox.auth.world.org|alice-pairwise-sub"); // continuity

    address alice = makeAddr("alice");
    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address scam = makeAddr("scam");
    address admin = makeAddr("admin");

    bytes merchants = dns("verified", "merchants", "eth");
    bytes hobby = dns("hobby", "alice", "eth");
    bytes ps5 = dns4("ps5", "hobby", "alice", "eth");
    bytes lego = dns4("lego", "hobby", "alice", "eth");

    function setUp() public {
        vm.warp(1_790_000_000);
        ps = new PolicySpender(IERC20(address(usdc)), IWorldID(address(world)), "app_x", "buy", IResolver(address(res)), merchants, vm.addr(ATTESTER_PK), admin);
        res.set(merchants, vm.toLowercase(vm.toString(shop)), 1);

        res.set(hobby, "limit", 1000e6);
        res.set(ps5, "auto", 400e6);
        res.set(ps5, "max", 500e6);
        res.set(ps5, "deadline", block.timestamp + 30 days);
        res.set(lego, "auto", 700e6);
        res.set(lego, "max", 700e6);
        res.set(lego, "deadline", block.timestamp + 30 days);

        usdc.mint(alice, 5000e6);
        vm.startPrank(alice);
        usdc.approve(address(ps), type(uint256).max);
        ps.setAccount(nh("alice.eth"), address(res), agent, ALICE_HUMAN);
        ps.setContinuity(ALICE_WORLD);
        vm.stopPrank();
    }

    function test_autoBandBuysAlone() public {
        buy(order(ps5, shop, 399e6), noProof());
        assertEq(usdc.balanceOf(shop), 399e6);
    }

    function test_autoBandRejectsUnverifiedMerchant() public {
        // injected 402 swaps payTo: agent alone cannot pay an unknown address
        expectBuyRevert(order(ps5, scam, 399e6), noProof(), PolicySpender.UnverifiedMerchant.selector);
    }

    function test_midBandNeedsProofForThisExactOrder() public {
        PolicySpender.Order memory o = order(ps5, shop, 450e6);
        vm.expectRevert("invalid proof");
        vm.prank(agent);
        ps.buy(o, noProof());

        world.accept(uint256(keccak256(abi.encodePacked(keccak256(abi.encode(o))))) >> 8);
        PolicySpender.Order memory other = order(ps5, scam, 450e6);
        vm.expectRevert("invalid proof"); // approval for `o` does not cover a different order
        vm.prank(agent);
        ps.buy(other, noProof());

        buy(o, noProof());
        assertEq(usdc.balanceOf(shop), 450e6);
    }

    function test_midBandOnlyOwnersHuman() public {
        PolicySpender.Order memory o = order(ps5, shop, 450e6);
        world.accept(ps.signalOf(ps.orderHash(o))); // a valid proof for this exact order...
        PolicySpender.Human memory other;
        other.nullifier = 7; // ...but from someone else's World ID
        expectBuyRevert(o, other, PolicySpender.NotOwnerHuman.selector);

        vm.prank(alice);
        ps.setAccount(nh("alice.eth"), address(res), agent, 0); // no human set -> mid band closed
        expectBuyRevert(o, noProof(), PolicySpender.NotOwnerHuman.selector);
        buy(order(ps5, shop, 399e6), noProof()); // auto band unaffected
    }

    function test_overMaxNever() public {
        expectBuyRevert(order(ps5, shop, 501e6), noProof(), PolicySpender.OverMax.selector);
    }

    function test_categoryLimitIsSharedAndResetsNextPeriod() public {
        buy(order(lego, shop, 700e6), noProof());
        // ps5 fits its own band, but hobby has only 300 left this period
        expectBuyRevert(order(ps5, shop, 399e6), noProof(), PolicySpender.OverBudget.selector);
        assertEq(ps.remaining(hobby, alice), 300e6);

        vm.warp(block.timestamp + ps.PERIOD());
        res.set(ps5, "deadline", block.timestamp + 1 days);
        buy(order(ps5, shop, 399e6), noProof());
    }

    function test_pctCapTracksBalance() public {
        res.set(hobby, "pct", 10); // 10% of 5000 = 500
        expectBuyRevert(order(lego, shop, 700e6), noProof(), PolicySpender.OverBudget.selector);
        usdc.mint(alice, 5000e6); // salary: 10% of 10000 = 1000
        buy(order(lego, shop, 700e6), noProof());
    }

    function test_foreignAccountCannotBurnBudget() public {
        // bob claims alice's root (setAccount doesn't check ownership) and spends through the same category
        address bob = makeAddr("bob");
        address bobAgent = makeAddr("bobAgent");
        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(ps), type(uint256).max);
        ps.setAccount(nh("alice.eth"), address(res), bobAgent, 0);
        vm.stopPrank();
        PolicySpender.Order memory o = order(lego, shop, 700e6);
        o.payer = bob;
        vm.prank(bobAgent);
        ps.buy(o, noProof());
        assertEq(ps.remaining(hobby, alice), 1000e6);
        buy(order(lego, shop, 700e6), noProof());
    }

    function test_guards() public {
        PolicySpender.Order memory o = order(ps5, shop, 100e6);
        vm.expectRevert(PolicySpender.NotAgent.selector);
        ps.buy(o, noProof());

        buy(o, noProof());
        expectBuyRevert(o, noProof(), PolicySpender.OrderUsed.selector);

        bytes memory bob = dns4("ps5", "hobby", "bob", "eth");
        expectBuyRevert(order(bob, shop, 100e6), noProof(), PolicySpender.NotYourPolicy.selector);

        vm.warp(block.timestamp + 31 days);
        expectBuyRevert(order(ps5, shop, 101e6), noProof(), PolicySpender.Expired.selector);
    }

    // --- buyApproved: World ID for Agents approval signed by the backend attester ---

    function test_approvedMidBandBuys() public {
        PolicySpender.Order memory o = order(ps5, shop, 450e6);
        uint64 t = uint64(block.timestamp - 30);
        bytes memory sig = approve(ATTESTER_PK, o, ALICE_WORLD, t);
        PolicySpender.Order memory other = order(ps5, scam, 450e6);
        expectApprovedRevert(other, t, sig, PolicySpender.BadApproval.selector); // bound to this exact order
        buyApproved(o, t, sig);
        assertEq(usdc.balanceOf(shop), 450e6);
        expectApprovedRevert(o, t, sig, PolicySpender.OrderUsed.selector); // no replay
    }

    function test_approvedWrongSigner() public {
        PolicySpender.Order memory o = order(ps5, shop, 450e6);
        uint64 t = uint64(block.timestamp);
        expectApprovedRevert(o, t, approve(0xBAD, o, ALICE_WORLD, t), PolicySpender.BadApproval.selector);
        expectApprovedRevert(o, t, "", PolicySpender.BadApproval.selector);
        // same signature with s flipped to the high half (malleable twin) is rejected
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, ps.approvalDigest(ps.orderHash(o), ALICE_WORLD, t));
        bytes32 highS = bytes32(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - uint256(s));
        expectApprovedRevert(o, t, abi.encodePacked(r, highS, v == 27 ? uint8(28) : uint8(27)), PolicySpender.BadApproval.selector);
        buyApproved(o, t, abi.encodePacked(r, s, v));
    }

    function test_approvedStale() public {
        PolicySpender.Order memory o = order(ps5, shop, 450e6);
        uint64 old = uint64(block.timestamp - ps.FRESHNESS() - 1);
        expectApprovedRevert(o, old, approve(ATTESTER_PK, o, ALICE_WORLD, old), PolicySpender.StaleApproval.selector);
        uint64 future = uint64(block.timestamp + 61);
        expectApprovedRevert(o, future, approve(ATTESTER_PK, o, ALICE_WORLD, future), PolicySpender.StaleApproval.selector);
        uint64 edge = uint64(block.timestamp - ps.FRESHNESS());
        buyApproved(o, edge, approve(ATTESTER_PK, o, ALICE_WORLD, edge));
    }

    function test_approvedOnlyOwnersWorldId() public {
        PolicySpender.Order memory o = order(ps5, shop, 450e6);
        uint64 t = uint64(block.timestamp);
        // attester signed for a different World ID subject: does not match alice's continuity
        bytes32 mallory = keccak256("https://sandbox.auth.world.org|mallory");
        expectApprovedRevert(o, t, approve(ATTESTER_PK, o, mallory, t), PolicySpender.BadApproval.selector);

        vm.prank(alice);
        ps.setContinuity(0); // unlinked -> mid band closed, even with a valid signature over 0
        expectApprovedRevert(o, t, approve(ATTESTER_PK, o, 0, t), PolicySpender.NotOwnerHuman.selector);
        buyApproved(order(ps5, shop, 399e6), t, ""); // auto band unaffected
    }

    function test_approvedAutoBandNeedsNoSig() public {
        buyApproved(order(ps5, shop, 399e6), 0, "");
        assertEq(usdc.balanceOf(shop), 399e6);
        expectApprovedRevert(order(ps5, scam, 399e6), 0, "", PolicySpender.UnverifiedMerchant.selector);
        expectApprovedRevert(order(ps5, shop, 501e6), 0, "", PolicySpender.OverMax.selector);
        vm.expectRevert(PolicySpender.NotAgent.selector);
        ps.buyApproved(order(ps5, shop, 100e6), 0, "");
    }

    /// Same digest as viem hashTypedData in backend/check.ts (chainId 31337, verifyingContract 0x...bEEF).
    function test_approvalDigestMatchesBackend() public {
        vm.etch(address(0xbEEF), address(ps).code);
        bytes32 d = PolicySpender(address(0xbEEF)).approvalDigest(keccak256("order"), ALICE_WORLD, 1_790_000_000);
        assertEq(d, DIGEST_FROM_VIEM);
    }

    // --- setupWithPermit: one gasless owner signature, submitted by anyone ---

    uint256 constant CAROL_PK = 0xCA201;
    bytes32 constant CAROL_WORLD = keccak256("https://sandbox.auth.world.org|carol");

    struct Setup {
        address owner;
        bytes32 root;
        address resolver;
        address agent;
        bytes32 continuity;
        uint256 value;
    }

    function carolSetup() internal returns (Setup memory c) {
        c = Setup(vm.addr(CAROL_PK), nh("carol.eth"), address(res), agent, CAROL_WORLD, 1000e6);
        res.set(dns("hobby", "carol", "eth"), "limit", 1000e6);
        res.set(dns4("ps5", "hobby", "carol", "eth"), "auto", 400e6);
        res.set(dns4("ps5", "hobby", "carol", "eth"), "max", 500e6);
        res.set(dns4("ps5", "hobby", "carol", "eth"), "deadline", block.timestamp + 30 days);
        usdc.mint(c.owner, 5000e6);
    }

    /// The owner signs a plain USDC permit whose deadline is setupDeadline(config).
    function signSetup(Setup memory c) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 d = ps.setupDeadline(c.owner, c.root, c.resolver, c.agent, c.continuity);
        return vm.sign(CAROL_PK, usdc.permitDigest(c.owner, address(ps), c.value, usdc.nonces(c.owner), d));
    }

    function submit(Setup memory c, uint8 v, bytes32 r, bytes32 s) internal {
        vm.prank(makeAddr("operator")); // anyone may submit; the owner sends nothing
        ps.setupWithPermit(c.owner, c.root, c.resolver, c.agent, c.continuity, c.value, v, r, s);
    }

    function test_setupWithPermitThenBuy() public {
        Setup memory c = carolSetup();
        (uint8 v, bytes32 r, bytes32 s) = signSetup(c);
        submit(c, v, r, s);

        (bytes32 root, address resolver, address a, uint256 human) = ps.accounts(c.owner);
        assertEq(root, c.root);
        assertEq(resolver, c.resolver);
        assertEq(a, agent);
        assertEq(human, 0);
        assertEq(ps.continuity(c.owner), CAROL_WORLD);
        assertEq(usdc.allowance(c.owner, address(ps)), 1000e6);
        assertTrue(ps.setupDeadline(c.owner, c.root, c.resolver, c.agent, c.continuity) >= 1 << 255); // never expires

        PolicySpender.Order memory o = order(dns4("ps5", "hobby", "carol", "eth"), shop, 399e6);
        o.payer = c.owner;
        buy(o, noProof()); // auto band from carol's own wallet
        assertEq(usdc.balanceOf(shop), 399e6);
        assertEq(usdc.balanceOf(c.owner), 5000e6 - 399e6);

        o = order(dns4("ps5", "hobby", "carol", "eth"), shop, 450e6);
        o.payer = c.owner;
        uint64 t = uint64(block.timestamp);
        buyApproved(o, t, approve(ATTESTER_PK, o, CAROL_WORLD, t)); // mid band bound to carol's World ID (continuity)
        assertEq(usdc.balanceOf(shop), 849e6);
    }

    function test_setupPermitCommitsToConfig() public {
        Setup memory c = carolSetup();
        (uint8 v, bytes32 r, bytes32 s) = signSetup(c);
        Setup[6] memory bad;
        for (uint256 i; i < 6; i++) bad[i] = Setup(c.owner, c.root, c.resolver, c.agent, c.continuity, c.value);
        bad[0].root = nh("mallory.eth");
        bad[1].resolver = makeAddr("evilResolver");
        bad[2].agent = makeAddr("evilAgent");
        bad[3].continuity = keccak256("https://sandbox.auth.world.org|mallory");
        bad[4].value = type(uint256).max;
        bad[5].owner = alice;
        for (uint256 i; i < 6; i++) {
            vm.expectRevert("invalid signature");
            submit(bad[i], v, r, s);
        }
        (, , address a,) = ps.accounts(c.owner);
        assertEq(a, address(0));
        submit(c, v, r, s); // the untouched config still goes through
    }

    function test_setupPermitReplay() public {
        Setup memory c = carolSetup();
        (uint8 v, bytes32 r, bytes32 s) = signSetup(c);
        submit(c, v, r, s);
        vm.prank(c.owner);
        ps.setAccount(c.root, c.resolver, address(0), 0); // owner later disables the agent...
        vm.expectRevert("invalid signature"); // ...and the old signature cannot re-enable it (nonce consumed)
        submit(c, v, r, s);
    }

    // --- reset: owner or admin switches the account off; only a fresh owner signature switches it back on ---

    function test_resetForClearsAccountAndBudget() public {
        Setup memory c = carolSetup();
        (uint8 v, bytes32 r, bytes32 s) = signSetup(c);
        submit(c, v, r, s);
        bytes memory carolHobby = dns("hobby", "carol", "eth");
        PolicySpender.Order memory o = order(dns4("ps5", "hobby", "carol", "eth"), shop, 399e6);
        o.payer = c.owner;
        buy(o, noProof());
        assertEq(ps.spentOf(c.owner, carolHobby), 399e6);
        assertEq(ps.remaining(carolHobby, c.owner), 1000e6 - 399e6);

        vm.expectRevert(PolicySpender.NotAdmin.selector);
        ps.resetFor(c.owner); // not the admin
        vm.expectRevert(PolicySpender.NotAdmin.selector);
        vm.prank(c.owner);
        ps.resetFor(c.owner); // not even the owner: owners use resetAccount()

        vm.expectEmit(address(ps));
        emit PolicySpender.AccountReset(c.owner, 1, admin);
        vm.prank(admin);
        ps.resetFor(c.owner);
        (bytes32 root, address resolver, address a, uint256 human) = ps.accounts(c.owner);
        assertEq(abi.encode(root, resolver, a, human), abi.encode(bytes32(0), address(0), address(0), uint256(0)));
        assertEq(ps.continuity(c.owner), 0);
        assertEq(ps.epoch(c.owner), 1);
        assertEq(ps.spentOf(c.owner, carolHobby), 0); // new epoch: counters start at 0

        o = order(dns4("ps5", "hobby", "carol", "eth"), shop, 399e6);
        o.payer = c.owner;
        expectBuyRevert(o, noProof(), PolicySpender.NotAgent.selector); // switched off, allowance left alone
        assertEq(usdc.allowance(c.owner, address(ps)), 1000e6 - 399e6);
        vm.expectRevert("invalid signature"); // the admin cannot switch it back on with the old signature
        submit(c, v, r, s);

        (v, r, s) = signSetup(c); // the owner signs again (new permit nonce)
        submit(c, v, r, s);
        assertEq(ps.remaining(carolHobby, c.owner), 1000e6); // full budget again in the same period
        buy(o, noProof());
        assertEq(ps.spentOf(c.owner, carolHobby), 399e6);
        assertEq(usdc.balanceOf(shop), 798e6);
    }

    function test_resetAccountByOwner() public {
        buy(order(lego, shop, 700e6), noProof());
        vm.expectEmit(address(ps));
        emit PolicySpender.AccountReset(alice, 1, alice);
        vm.prank(alice);
        ps.resetAccount();
        (, , address a,) = ps.accounts(alice);
        assertEq(a, address(0));
        assertEq(ps.continuity(alice), 0);
        assertEq(ps.spentOf(alice, hobby), 0);
        expectBuyRevert(order(ps5, shop, 100e6), noProof(), PolicySpender.NotAgent.selector);

        vm.startPrank(alice); // owner re-authorizes directly
        ps.setAccount(nh("alice.eth"), address(res), agent, ALICE_HUMAN);
        ps.resetAccount(); // twice: epoch keeps counting
        ps.setAccount(nh("alice.eth"), address(res), agent, ALICE_HUMAN);
        vm.stopPrank();
        assertEq(ps.epoch(alice), 2);
        buy(order(lego, shop, 700e6), noProof()); // would be OverBudget without the reset (700 + 700 > 1000)
        assertEq(ps.remaining(hobby, alice), 300e6);
    }

    // --- helpers ---

    function approve(uint256 pk, PolicySpender.Order memory o, bytes32 c, uint64 t) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, ps.approvalDigest(ps.orderHash(o), c, t));
        return abi.encodePacked(r, s, v);
    }

    function buyApproved(PolicySpender.Order memory o, uint64 t, bytes memory sig) internal {
        vm.prank(agent);
        ps.buyApproved(o, t, sig);
    }

    function expectApprovedRevert(PolicySpender.Order memory o, uint64 t, bytes memory sig, bytes4 err) internal {
        vm.expectRevert(err);
        buyApproved(o, t, sig);
    }

    uint256 salt;

    function order(bytes memory req, address to, uint256 price) internal returns (PolicySpender.Order memory) {
        return PolicySpender.Order(alice, req, to, price, keccak256("sku"), uint64(block.timestamp + 5 minutes), bytes32(++salt));
    }

    function noProof() internal pure returns (PolicySpender.Human memory h) {
        h.nullifier = ALICE_HUMAN;
    }

    function buy(PolicySpender.Order memory o, PolicySpender.Human memory h) internal {
        vm.prank(agent);
        ps.buy(o, h);
    }

    function expectBuyRevert(PolicySpender.Order memory o, PolicySpender.Human memory h, bytes4 err) internal {
        vm.expectRevert(err);
        buy(o, h);
    }

    function nh(string memory n) internal pure returns (bytes32) {
        return vm.ensNamehash(n);
    }

    function dns(string memory a, string memory b, string memory c) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(bytes(a).length), a, uint8(bytes(b).length), b, uint8(bytes(c).length), c, uint8(0));
    }

    function dns4(string memory a, string memory b, string memory c, string memory d) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(bytes(a).length), a, dns(b, c, d));
    }
}
