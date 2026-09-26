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

contract PolicySpenderTest is Test {
    MockUSDC usdc = new MockUSDC();
    MockResolver res = new MockResolver();
    MockWorldID world = new MockWorldID();
    PolicySpender ps;
    uint256 constant ALICE_HUMAN = 42;

    address alice = makeAddr("alice");
    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address scam = makeAddr("scam");

    bytes merchants = dns("verified", "merchants", "eth");
    bytes hobby = dns("hobby", "alice", "eth");
    bytes ps5 = dns4("ps5", "hobby", "alice", "eth");
    bytes lego = dns4("lego", "hobby", "alice", "eth");

    function setUp() public {
        vm.warp(1_790_000_000);
        ps = new PolicySpender(IERC20(address(usdc)), IWorldID(address(world)), "app_x", "buy", IResolver(address(res)), merchants);
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

    // --- helpers ---

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
