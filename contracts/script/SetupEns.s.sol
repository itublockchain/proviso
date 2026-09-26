// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PolicySpender} from "../src/PolicySpender.sol";

interface IFactory {
    function deployProxy(address impl, uint256 salt, bytes calldata init) external returns (address);
}

interface IRegistrar {
    function makeCommitment(string calldata, address, bytes32, address, address, uint64, bytes32) external view returns (bytes32);
    function commit(bytes32) external;
    function register(string calldata, address, bytes32, address, address, uint64, address, bytes32) external;
}

interface IUserRegistry {
    function register(string calldata, address owner, address subregistry, address resolver, uint256 roles, uint64 expiry) external;
    function setParent(address parent, string calldata label) external;
}

interface IPermissionedResolver {
    function setText(bytes calldata name, string calldata key, string calldata value) external;
    function setData(bytes calldata name, string calldata key, bytes calldata value) external;
    function grantSetterRoles(bytes calldata setterCall, address account) external;
    function multicall(bytes[] calldata) external;
}

interface IToken {
    function mint(address, uint256) external;
    function approve(address, uint256) external returns (bool);
}

/// "a.b.eth" -> DNS wire format.
function dnsEncode(string memory name) pure returns (bytes memory out) {
    bytes memory s = bytes(name);
    uint256 start;
    for (uint256 i; i <= s.length; i++) {
        if (i == s.length || s[i] == ".") {
            bytes memory label = new bytes(i - start);
            for (uint256 j; j < label.length; j++) label[j] = s[start + j];
            out = abi.encodePacked(out, uint8(label.length), label);
            start = i + 1;
        }
    }
    out = abi.encodePacked(out, uint8(0));
}

/// Two phases because the registrar enforces a 60s commit age:
///   forge script script/SetupEns.s.sol --sig "commit()"   --rpc-url sepolia --broadcast
///   (deploy PolicySpender, wait >= 60s)
///   forge script script/SetupEns.s.sol --sig "register()" --rpc-url sepolia --broadcast
/// Env: ALICE_PK, OPERATOR_PK, AGENT, MERCHANT, ROOT_LABEL, MERCHANT_LABEL, POLICY_SPENDER (register only),
///      APPROVE_CAP (opt), OWNER_NULLIFIER (opt: alice's World ID nullifier for app+action; 0 = no mid band)
/// commit() stores proxy addresses + secret in deployments/setup.json for register().
contract SetupEns is Script {
    IFactory constant FACTORY = IFactory(0x9e726Eb570beb6BCEb495AB8cdA7df517d4e841C);
    IRegistrar constant REGISTRAR = IRegistrar(0xAbe76F6C8DFcEd81AA5A2bB8034202A7136b94ca);
    address constant ETH_REGISTRY = 0x657eA849311d3D5823348ddEd7C2AaAFb3EDE09E;
    address constant RESOLVER_IMPL = 0x14F09Fd05d4585759e54844DC9B00147131Cf243;
    address constant USERREG_IMPL = 0xA80338aAA8D23831cEa25E858D1774534aBb0263;
    IToken constant ENS_PAY_TOKEN = IToken(0x16f95D91DBa7dA3Aca778Ec053dF0FF6C6A8aA8e); // MockUSDC, open mint
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    uint256 constant ALL_ROLES = 0x1111111111111111111111111111111111111111111111111111111111111111;
    uint64 constant YEAR = 365 days;
    string constant FILE = "deployments/setup.json";

    struct State {
        address aliceRes;
        address aliceReg;
        address merchantRes;
        bytes32 secret;
    }

    State public st;

    function commit() external {
        uint256 alicePk = vm.envUint("ALICE_PK");
        uint256 opPk = vm.envUint("OPERATOR_PK");
        string memory rootLabel = vm.envString("ROOT_LABEL");
        string memory merchantLabel = vm.envString("MERCHANT_LABEL");
        st.secret = keccak256(abi.encode(rootLabel, merchantLabel, block.timestamp, vm.addr(alicePk)));

        vm.startBroadcast(alicePk);
        address alice = vm.addr(alicePk);
        st.aliceRes = proxy("aliceRes", RESOLVER_IMPL, abi.encodeWithSignature("initialize((address,uint256)[],bytes[])", roles(alice), new bytes[](0)));
        st.aliceReg = proxy("aliceReg", USERREG_IMPL, abi.encodeWithSignature("initialize((address,uint256)[])", roles(alice)));
        REGISTRAR.commit(REGISTRAR.makeCommitment(rootLabel, alice, st.secret, st.aliceReg, st.aliceRes, YEAR, 0));
        vm.stopBroadcast();

        vm.startBroadcast(opPk);
        address op = vm.addr(opPk);
        st.merchantRes = proxy("merchantRes", RESOLVER_IMPL, abi.encodeWithSignature("initialize((address,uint256)[],bytes[])", roles(op), new bytes[](0)));
        REGISTRAR.commit(REGISTRAR.makeCommitment(merchantLabel, op, st.secret, address(0), st.merchantRes, YEAR, 0));
        vm.stopBroadcast();

        vm.serializeAddress("s", "aliceRes", st.aliceRes);
        vm.serializeAddress("s", "aliceReg", st.aliceReg);
        vm.serializeAddress("s", "merchantRes", st.merchantRes);
        vm.writeJson(vm.serializeBytes32("s", "secret", st.secret), FILE);
        console.log("MERCHANT_RESOLVER", st.merchantRes);
    }

    function register() external {
        if (st.aliceRes == address(0)) {
            string memory j = vm.readFile(FILE);
            st = State(vm.parseJsonAddress(j, ".aliceRes"), vm.parseJsonAddress(j, ".aliceReg"), vm.parseJsonAddress(j, ".merchantRes"), vm.parseJsonBytes32(j, ".secret"));
        }
        registerAlice();
        registerMerchant();
    }

    function registerAlice() internal {
        string memory root = string.concat(vm.envString("ROOT_LABEL"), ".eth");
        IPermissionedResolver res = IPermissionedResolver(st.aliceRes);
        IUserRegistry aliceReg = IUserRegistry(st.aliceReg);

        // --- alice: <root>.eth -> hobby -> {ps5, lego}, records, agent grant, allowance, account ---
        uint256 alicePk = vm.envUint("ALICE_PK");
        address alice = vm.addr(alicePk);
        vm.startBroadcast(alicePk);
        pay(alice);
        REGISTRAR.register(vm.envString("ROOT_LABEL"), alice, st.secret, st.aliceReg, st.aliceRes, YEAR, address(ENS_PAY_TOKEN), 0);
        aliceReg.setParent(ETH_REGISTRY, vm.envString("ROOT_LABEL"));
        uint64 exp = uint64(block.timestamp + YEAR);
        address hobbyReg = proxy("hobbyReg", USERREG_IMPL, abi.encodeWithSignature("initialize((address,uint256)[])", roles(alice)));
        aliceReg.register("hobby", alice, hobbyReg, st.aliceRes, ALL_ROLES, exp);
        IUserRegistry(hobbyReg).setParent(st.aliceReg, "hobby");
        IUserRegistry(hobbyReg).register("ps5", alice, address(0), st.aliceRes, ALL_ROLES, exp);
        IUserRegistry(hobbyReg).register("lego", alice, address(0), st.aliceRes, ALL_ROLES, exp);
        address needsReg = proxy("needsReg", USERREG_IMPL, abi.encodeWithSignature("initialize((address,uint256)[])", roles(alice)));
        aliceReg.register("needs", alice, needsReg, st.aliceRes, ALL_ROLES, exp);
        IUserRegistry(needsReg).setParent(st.aliceReg, "needs");
        // the backend registers new requests under these category registries
        vm.serializeAddress("r", "aliceRes", st.aliceRes);
        vm.serializeAddress("r", "hobbyReg", hobbyReg);
        vm.writeJson(vm.serializeAddress("r", "needsReg", needsReg), "deployments/registries.json");

        setRecords(res, root);
        // agent may write "status" text on any name in this resolver, nothing else
        res.grantSetterRoles(abi.encodeCall(IPermissionedResolver.setText, (hex"00", "status", "")), vm.envAddress("AGENT"));

        PolicySpender ps = PolicySpender(vm.envAddress("POLICY_SPENDER"));
        address usdc = vm.envOr("USDC", USDC);
        if (usdc == address(ENS_PAY_TOKEN)) ENS_PAY_TOKEN.mint(alice, 5000e6); // demo spending money
        IToken(usdc).approve(address(ps), vm.envOr("APPROVE_CAP", uint256(5000e6)));
        uint256 human = vm.envOr("OWNER_NULLIFIER", uint256(0));
        if (human == 0) console.log("WARNING: OWNER_NULLIFIER unset -> mid-band (World ID) buys disabled for this account");
        ps.setAccount(vm.ensNamehash(root), st.aliceRes, vm.envAddress("AGENT"), human);
        vm.stopBroadcast();
    }

    function setRecords(IPermissionedResolver res, string memory root) internal {
        bytes memory hobby = dnsEncode(string.concat("hobby.", root));
        bytes memory ps5 = dnsEncode(string.concat("ps5.hobby.", root));
        bytes memory lego = dnsEncode(string.concat("lego.hobby.", root));
        uint256 deadline = block.timestamp + 30 days;
        bytes[] memory calls = new bytes[](8);
        calls[0] = rec(hobby, "limit", 1000e6);
        calls[1] = rec(ps5, "auto", 400e6);
        calls[2] = rec(ps5, "max", 500e6);
        calls[3] = rec(ps5, "deadline", deadline);
        calls[4] = rec(lego, "auto", 700e6);
        calls[5] = rec(lego, "max", 700e6);
        calls[6] = rec(lego, "deadline", deadline);
        calls[7] = rec(dnsEncode(string.concat("needs.", root)), "limit", 3000e6);
        res.multicall(calls);
    }

    function registerMerchant() internal {
        // --- operator: <merchant>.eth with data[lowercase merchant address] = 1 ---
        uint256 opPk = vm.envUint("OPERATOR_PK");
        address op = vm.addr(opPk);
        vm.startBroadcast(opPk);
        pay(op);
        REGISTRAR.register(vm.envString("MERCHANT_LABEL"), op, st.secret, address(0), st.merchantRes, YEAR, address(ENS_PAY_TOKEN), 0);
        IPermissionedResolver(st.merchantRes).setData(
            dnsEncode(string.concat(vm.envString("MERCHANT_LABEL"), ".eth")),
            vm.toLowercase(vm.toString(vm.envAddress("MERCHANT"))),
            abi.encode(uint256(1))
        );
        vm.stopBroadcast();
    }

    function pay(address who) internal {
        ENS_PAY_TOKEN.mint(who, 100e6);
        ENS_PAY_TOKEN.approve(address(REGISTRAR), 100e6);
    }

    function rec(bytes memory name, string memory key, uint256 v) internal pure returns (bytes memory) {
        return abi.encodeCall(IPermissionedResolver.setData, (name, key, abi.encode(v)));
    }

    function proxy(string memory tag, address impl, bytes memory init) internal returns (address) {
        return FACTORY.deployProxy(impl, uint256(keccak256(abi.encode(tag, st.secret))), init);
    }

    function roles(address who) internal pure returns (EacRole[] memory r) {
        r = new EacRole[](1);
        r[0] = EacRole(who, ALL_ROLES);
    }
}

struct EacRole {
    address account;
    uint256 roles;
}
