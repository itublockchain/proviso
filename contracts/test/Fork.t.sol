// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PolicySpender, IERC20, IWorldID, IResolver} from "../src/PolicySpender.sol";
import {SetupEns, IPermissionedResolver, dnsEncode} from "../script/SetupEns.s.sol";
import {Deploy} from "../script/Deploy.s.sol";

// Pinned: the saved World ID staging proof's root is still valid here (superseded 1790420328, +1h grace).
uint256 constant FORK_BLOCK = 11786006;
address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
address constant ROUTER = 0x469449f251692E0779667583026b5A1E99512157;
string constant APP_ID = "app_66474f5a3098af8819339dae971694bc";
// saved IDKit staging proof (signal 0xabab..ab); its nullifier is "alice's human" for app+action
uint256 constant HUMAN = 0x0ca422d63a2306b4823546eaa490274158fb92b79a4d84975b7ce6c2e0f6249b;
uint256 constant PROOF_ROOT = 0x2fc78b2456b88f436bf04a0c4edea9e4bdfa7d7828087337053315a74517a35e;
bytes constant PROOF = hex"268a2e1e65c6798673f11231a8c8916aa92aa5c7b131569d83803696a8bcd0fe2eac8fa3495405deab8e57e107dbd2881f55351ec86bb7e55aba720d8adb9edb30080a65d72744c3f818a360234837708b1f8b04579bd62c3d1a8f3f14d985fc20b6d3463374b5b8ab2d4cb0465019b2cea39036256a5eb8192987156d710e7c11903f7b59802ba2ac23cc21ea418cc5393a9d34aa6d9b674c6d3dde9913479515feb7f7de6650d76308ad82dc129f207734ab0ea99c38e42d9e9a3bf6975a452ec0cba3040c68795734db2ead19c8d373bb993e346f3bc32c9560390e0899bf22bfdbdaba0fbe1f7d756f4d64268a1e7b84d7f6738915d5d7d35bff1beb5a16";

interface IERC20Approve {
    function approve(address, uint256) external returns (bool);
}

/// forge test --match-path test/Fork.t.sol   (runs both real scripts against a Sepolia fork)
contract ForkTest is Test {
    uint256 alicePk = uint256(keccak256("hero-fork-alice"));
    uint256 opPk = uint256(keccak256("hero-fork-operator"));
    uint256 attesterPk = uint256(keccak256("hero-fork-attester"));
    address alice = vm.addr(alicePk);
    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address scam = makeAddr("scam");

    bytes hobby = dnsEncode("hobby.heroforkalice7.eth");
    bytes ps5 = dnsEncode("ps5.hobby.heroforkalice7.eth");
    bytes lego = dnsEncode("lego.hobby.heroforkalice7.eth");

    PolicySpender ps;
    IPermissionedResolver res;

    function setUp() public {
        vm.createSelectFork("sepolia", FORK_BLOCK);
        // all values deterministic: parallel tests share process env
        vm.setEnv("ALICE_PK", vm.toString(alicePk));
        vm.setEnv("OPERATOR_PK", vm.toString(opPk));
        vm.setEnv("AGENT", vm.toString(agent));
        vm.setEnv("MERCHANT", vm.toString(shop));
        vm.setEnv("ROOT_LABEL", "heroforkalice7");
        vm.setEnv("MERCHANT_LABEL", "heroforkshops7");
        vm.setEnv("MERCHANT_REGISTRY", "heroforkshops7.eth");
        vm.setEnv("WORLD_APP_ID", APP_ID);
        vm.setEnv("OWNER_NULLIFIER", vm.toString(HUMAN));
        vm.setEnv("HERO_ATTESTER", vm.toString(vm.addr(attesterPk)));
        vm.deal(alice, 1 ether);
        vm.deal(vm.addr(opPk), 1 ether);

        SetupEns s = new SetupEns();
        s.commit();
        (address aliceRes,, address merchantRes,) = s.st();
        res = IPermissionedResolver(aliceRes);
        vm.setEnv("MERCHANT_RESOLVER", vm.toString(merchantRes));
        vm.warp(block.timestamp + 61);
        vm.roll(block.number + 5);

        ps = new Deploy().run();
        vm.setEnv("POLICY_SPENDER", vm.toString(address(ps)));
        s.register();

        deal(USDC, alice, 5000e6);
    }

    function test_setupState() public view {
        assertTrue(ps.verifiedMerchant(shop));
        assertEq(ps.admin(), vm.addr(opPk)); // Deploy.s.sol: admin = operator
        assertFalse(ps.verifiedMerchant(scam));
        assertEq(ps.remaining(hobby, alice), 1000e6);
        (bytes32 root, address r, address a, uint256 human) = ps.accounts(alice);
        assertEq(human, HUMAN);
        assertEq(root, vm.ensNamehash("heroforkalice7.eth"));
        assertEq(r, address(res));
        assertEq(a, agent);
    }

    function test_autoBandRealUsdc() public {
        buy(order(ps5, shop, 399e6), noProof());
        assertEq(IERC20(USDC).balanceOf(shop), 399e6);
        assertEq(IERC20(USDC).balanceOf(alice), 5000e6 - 399e6);
    }

    function test_unverifiedMerchant() public {
        expectBuyRevert(order(ps5, scam, 399e6), PolicySpender.UnverifiedMerchant.selector);
    }

    function test_overMax() public {
        expectBuyRevert(order(ps5, shop, 501e6), PolicySpender.OverMax.selector);
    }

    function test_sharedCategoryBudgetAndPeriodReset() public {
        buy(order(lego, shop, 700e6), noProof());
        expectBuyRevert(order(ps5, shop, 399e6), PolicySpender.OverBudget.selector);
        assertEq(ps.remaining(hobby, alice), 300e6);

        vm.warp(block.timestamp + ps.PERIOD() + 1);
        expectBuyRevert(order(ps5, shop, 399e6), PolicySpender.Expired.selector); // deadline record passed
        vm.startPrank(alice);
        res.setData(ps5, "deadline", abi.encode(block.timestamp + 1 days));
        IERC20Approve(USDC).approve(address(ps), 1000e6); // APPROVE_CAP is a lifetime allowance, top it up
        vm.stopPrank();
        buy(order(ps5, shop, 399e6), noProof());
        assertEq(ps.remaining(hobby, alice), 1000e6 - 399e6);
    }

    function test_agentCanWriteStatusButNotLimits() public {
        vm.startPrank(agent);
        res.setText(ps5, "status", "ordered");
        vm.expectRevert();
        res.setData(ps5, "max", abi.encode(uint256(1e12)));
        vm.expectRevert();
        res.setText(ps5, "max", "999999");
        vm.expectRevert();
        res.setData(hobby, "limit", abi.encode(uint256(1e12)));
        vm.stopPrank();
        expectBuyRevert(order(ps5, shop, 501e6), PolicySpender.OverMax.selector);
    }

    function test_midBandRealRouterRejectsBogusProof() public {
        PolicySpender.Order memory o = order(ps5, shop, 450e6);
        vm.expectRevert(); // real World ID router: unknown root
        buy(o, noProof());
    }

    function test_midBandOtherHumanRejected() public {
        PolicySpender.Order memory o = order(ps5, shop, 450e6);
        PolicySpender.Human memory h;
        h.nullifier = HUMAN + 1;
        vm.mockCall(ROUTER, abi.encodeWithSelector(IWorldID.verifyProof.selector), ""); // even a "valid" proof
        vm.expectRevert(PolicySpender.NotOwnerHuman.selector);
        buy(o, h);
    }

    function test_midBandRealProofThroughContract() public {
        // alice's real proof passes the owner gate and reaches the real verifier, which rejects it because
        // it signs 0xabab.. rather than this order (real verifier error 0x7fcdd1f4, not NotOwnerHuman)
        PolicySpender.Human memory h = PolicySpender.Human(PROOF_ROOT, HUMAN, abi.decode(PROOF, (uint256[8])));
        vm.expectRevert(bytes4(0x7fcdd1f4));
        buy(order(ps5, shop, 450e6), h);
    }

    function test_midBandWithProof() public {
        PolicySpender.Order memory o = order(ps5, shop, 450e6);
        PolicySpender.Human memory h;
        h.root = 1;
        h.nullifier = HUMAN;
        vm.mockCall(
            ROUTER,
            abi.encodeCall(IWorldID.verifyProof, (h.root, 1, ps.signalOf(ps.orderHash(o)), h.nullifier, ps.externalNullifier(), h.proof)),
            ""
        );
        buy(o, h);
        assertEq(IERC20(USDC).balanceOf(shop), 450e6);
        // mid band skips the merchant registry: the human approved this exact payTo
    }

    function test_midBandWorldIdForAgents() public {
        assertEq(ps.attester(), vm.addr(attesterPk));
        bytes32 world = keccak256("https://sandbox.auth.world.org|fork-alice");
        PolicySpender.Order memory o = order(ps5, shop, 450e6);
        uint64 t = uint64(block.timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attesterPk, ps.approvalDigest(ps.orderHash(o), world, t));
        vm.prank(agent);
        vm.expectRevert(PolicySpender.NotOwnerHuman.selector); // owner has not linked a World ID yet
        ps.buyApproved(o, t, abi.encodePacked(r, s, v));

        vm.prank(alice);
        ps.setContinuity(world);
        vm.prank(agent);
        ps.buyApproved(o, t, abi.encodePacked(r, s, v));
        assertEq(IERC20(USDC).balanceOf(shop), 450e6);
    }

    // --- helpers ---

    uint256 salt;

    function order(bytes memory req, address to, uint256 price) internal returns (PolicySpender.Order memory) {
        return PolicySpender.Order(alice, req, to, price, keccak256("sku"), uint64(block.timestamp + 5 minutes), bytes32(++salt));
    }

    function noProof() internal pure returns (PolicySpender.Human memory h) {
        h.nullifier = HUMAN;
    }

    function buy(PolicySpender.Order memory o, PolicySpender.Human memory h) internal {
        vm.prank(agent);
        ps.buy(o, h);
    }

    function expectBuyRevert(PolicySpender.Order memory o, bytes4 err) internal {
        vm.expectRevert(err);
        buy(o, noProof());
    }
}

/// A real IDKit staging proof (signal 0xabab..ab, app APP_ID, action "buy") verifies on the real router with the
/// signal hash and external nullifier exactly as PolicySpender derives them.
contract ForkWorldTest is Test {
    function test_realProofMatchesContractHashing() public {
        vm.createSelectFork("sepolia", FORK_BLOCK);
        PolicySpender ps = new PolicySpender(IERC20(USDC), IWorldID(ROUTER), APP_ID, "buy", IResolver(address(0)), "", address(0), address(0));
        bytes32 signal = 0xabababababababababababababababababababababababababababababababab;
        assertEq(ps.signalOf(signal), 0x007d3a608bb850f47c2d77d6be73b8f93c94a80264b7bb3cc5c7d2fb54d07ef6);

        uint256[8] memory proof = abi.decode(PROOF, (uint256[8]));
        uint256 root = PROOF_ROOT;
        uint256 nullifier = HUMAN;

        IWorldID(ROUTER).verifyProof(root, 1, ps.signalOf(signal), nullifier, ps.externalNullifier(), proof);

        uint256 otherSignal = ps.signalOf(bytes32(uint256(1)));
        uint256 en = ps.externalNullifier();
        vm.expectRevert(); // any other order hash -> invalid
        IWorldID(ROUTER).verifyProof(root, 1, otherSignal, nullifier, en, proof);
    }
}
