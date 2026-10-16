// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArtifactDeployment} from "./ArtifactDeployment.sol";

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../../src/OracleAttestation.sol";
import {Tribunal} from "../../src/Tribunal.sol";
import {PLEA} from "../../src/PLEA.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {Seasons} from "../../src/Seasons.sol";
import {PleaDistributor} from "../../src/PleaDistributor.sol";
import {Letterbox} from "../../src/Letterbox.sol";
import {PleaLaunch} from "../../src/PleaLaunch.sol";
import {PleaHook} from "../../src/PleaHook.sol";
import {MockIMD, MockSIMD, MockStacker, BuyRouter, MockIntake, MockSeat} from "./Mocks.sol";

/// @dev Replays the launch (PLEA, CabalGate, Seasons, PleaDistributor, PleaLaunch in one call
/// context), deploys the Letterbox through PleaLaunch, mines the hook salt, deploys the hook and
/// opens trading.
abstract contract Fixture is Test {
    address constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    /// @dev anvil's second account, used as the test oracle signer.
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant CREDIT_GAS = 300_000;
    uint256 constant T0 = 1_800_000_000;

    uint256 SEASON = 15 days;
    uint256 DEADMAN = 33 hours;

    PoolManager pm;
    MockIMD imd;
    MockIMD oimd;
    MockSIMD simd;
    MockStacker stacker;
    MockIntake intake;
    /// @dev The IMD seat NFT stand-in Seasons reads for the points multiplier (nobody holds one by default).
    MockSeat seat;
    PLEA plea;
    CabalGate gate;
    Seasons seasons;
    PleaDistributor distributor;
    Letterbox letterbox;
    Tribunal tribunal;
    PleaLaunch launch;
    PleaHook hook;
    BuyRouter router;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");
    address[] users;

    function setTimings() internal virtual {}

    /// @dev Objection! is a launch choice: the Tribunal suites opt in; every other suite runs the
    /// launch with a zero Tribunal hash (objections off), today's behaviour.
    function withTribunal() internal pure virtual returns (bool) {
        return false;
    }

    /// @dev With the Tribunal committed: deploy it right after the launch (default), or leave that to
    /// the test.
    function deployTribunalAtLaunch() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev Sepolia: a separate oracle fee token (the Letterbox mints the fee). Mainnet path: return
    /// the pool IMD, so the Letterbox buys the oracle fee with PLEA like the tip.
    function oracleFeeToken() internal view virtual returns (MockIMD) {
        return oimd;
    }

    function creditGasBudget() internal pure virtual returns (uint256) {
        return CREDIT_GAS;
    }

    /// @dev The owner seeds (the hook, the Letterbox and a committed Tribunal exist by now).
    function openTrading() internal virtual {
        vm.prank(OWNER);
        launch.seed();
        afterSeed();
    }

    /// @dev Default: past the 90-minute launch window (no extra fee, no buy cap).
    function afterSeed() internal virtual {
        skip(91 minutes);
    }

    function setUp() public virtual {
        vm.chainId(11155111);
        vm.warp(T0);
        vm.roll(1000);
        setTimings();
        pm = PoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        deployImd();
        oimd = MockIMD(ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes("")));
        simd = MockSIMD(ArtifactDeployment.deploy("Mocks.sol:MockSIMD", bytes("")));
        stacker = MockStacker(ArtifactDeployment.deploy("Mocks.sol:MockStacker", abi.encode(imd, simd)));
        intake = MockIntake(ArtifactDeployment.deploy("Mocks.sol:MockIntake", abi.encode(oracleFeeToken())));
        deployLaunch();
        deployHook();
        openTrading();
        router = BuyRouter(
            ArtifactDeployment.deploy("Mocks.sol:BuyRouter", abi.encode(IPoolManager(address(pm)), hook, imd, plea))
        );
        users.push(alice);
        users.push(bob);
        users.push(carol);
        for (uint256 i; i < users.length; ++i) {
            fund(users[i]);
        }
    }

    function fund(address who) internal {
        imd.mint(who, 100_000e18);
        oimd.mint(who, 1_000e18);
        vm.startPrank(who);
        imd.approve(address(router), type(uint256).max);
        imd.approve(address(gate), type(uint256).max);
        imd.approve(address(seasons), type(uint256).max);
        oimd.approve(address(gate), type(uint256).max);
        plea.approve(address(gate), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Default: IMD sorts below PLEA (IMD is currency0). Orientation tests override this.
    function deployImd() internal virtual {
        imd = MockIMD(ArtifactDeployment.deploy("Mocks.sol:MockIMD", bytes("")));
    }

    function deployLaunch() internal {
        // Load the configured build's artifacts instead of embedding every application's creation
        // code into every inherited suite. These are still real CREATE deployments, in order.
        plea = PLEA(deployCode("PLEA.sol:PLEA", abi.encode(OWNER)));
        gate = CabalGate(
            deployCode(
                "CabalGate.sol:CabalGate",
                abi.encode(
                    address(plea), address(intake), address(oracleFeeToken()), address(imd), SIGNER, SEASON, DEADMAN
                )
            )
        );
        seat = MockSeat(ArtifactDeployment.deploy("Mocks.sol:MockSeat", bytes("")));
        seasons = Seasons(
            deployCode("Seasons.sol:Seasons", abi.encode(address(plea), address(gate), address(imd), address(seat)))
        );
        distributor =
            PleaDistributor(deployCode("PleaDistributor.sol:PleaDistributor", abi.encode(address(plea), OWNER)));
        MockIMD feeToken = oracleFeeToken();
        bytes memory letterboxCode = vm.getCode("Letterbox.sol:Letterbox");
        bytes memory tribunalCode = vm.getCode("Tribunal.sol:Tribunal");
        launch = PleaLaunch(
            deployCode(
                "PleaLaunch.sol:PleaLaunch",
                abi.encode(
                    address(plea),
                    address(gate),
                    address(seasons),
                    address(distributor),
                    address(pm),
                    address(imd),
                    address(stacker),
                    creditGasBudget(),
                    T0 + 1 days,
                    address(feeToken),
                    feeToken != imd,
                    keccak256(letterboxCode),
                    withTribunal() ? keccak256(tribunalCode) : bytes32(0)
                )
            )
        );
        // After the launch: anyone deploys the committed Letterbox (and the Tribunal, when on).
        letterbox = Letterbox(launch.deployLetterbox(letterboxCode));
        if (withTribunal() && deployTribunalAtLaunch()) {
            tribunal = Tribunal(launch.deployTribunal(tribunalCode));
        }
    }

    function hookInitCode() internal view returns (bytes memory) {
        return abi.encodePacked(
            vm.getCode("PleaHook.sol:PleaHook"),
            abi.encode(
                address(pm), address(plea), address(imd), address(stacker), OWNER, address(seasons), creditGasBudget()
            )
        );
    }

    function mineSalt(bytes32 initHash) internal view returns (bytes32 salt) {
        uint160 flags = launch.FLAGS();
        for (uint256 s;; ++s) {
            address a = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launch), bytes32(s), initHash))))
            );
            if (uint160(a) & 0x3fff == flags) return bytes32(s);
        }
    }

    function deployHook() internal {
        bytes memory code = hookInitCode();
        bytes32 salt = mineSalt(keccak256(code));
        hook = PleaHook(launch.deployHook(salt, code));
    }

    // ---------------------------------------------------------------- actions

    function buy(address who, uint256 imdIn) internal returns (uint256 out) {
        vm.prank(who);
        out = router.buyExactIn(imdIn, abi.encode(who));
    }

    function plead(address who, uint256 amount) internal returns (uint256 id) {
        return plead(who, amount, "I have held through every candle and need to pay rent; I keep the rest.");
    }

    function plead(address who, uint256 amount, string memory text) internal returns (uint256 id) {
        vm.prank(who);
        id = gate.submitSell(amount, text);
    }

    /// @dev A valid small plea: 2% of the balance (the gate's minimum is 1%), at most 2.5M PLEA.
    function small(address who) internal view returns (uint256 amount) {
        amount = plea.balanceOf(who) / 50;
        if (amount > 2_500_000e18) amount = 2_500_000e18;
    }

    function intakeIdOf(uint256 id) internal view returns (bytes32) {
        return gate.getPlea(id).intakeId;
    }

    function attestation(uint256 score, bytes32 requestId)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a = OracleAttestation.Attestation({
            requestId: requestId,
            chainId: 1,
            questionHash: keccak256("question"),
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(score),
            figure: score,
            fromBlock: 26_000_000,
            toBlock: 26_000_300,
            blockHash: keccak256("block"),
            panelJobId: keccak256(abi.encode("job", requestId)),
            panelSize: 30,
            quorum: 17,
            agreed: 20,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 3600)
        });
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        return signFor(address(gate), a);
    }

    /// @dev Signed under `consumer`'s own EIP-712 domain (the gate's or the Tribunal's).
    function signFor(address consumer, OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, OracleAttestationConsumer(consumer).attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    // ---------------------------------------------------------------- objections

    /// @dev `who` objects to `pleaId` (stake and, on the mainnet path, the fee come from `who`).
    function objectTo(address who, uint256 pleaId, string memory text) internal returns (uint256 id) {
        vm.startPrank(who);
        imd.approve(address(tribunal), type(uint256).max);
        oracleFeeToken().approve(address(tribunal), type(uint256).max);
        id = tribunal.object(pleaId, text);
        vm.stopPrank();
    }

    function objectTo(address who, uint256 pleaId) internal returns (uint256 id) {
        return objectTo(who, pleaId, "That plea is boilerplate: the same three lines as every other sell this week.");
    }

    /// @dev `who` tries to object and must fail with `err` (approvals are set first, so the revert
    /// expectation lands on `object` itself).
    function objectFails(address who, uint256 pleaId, bytes memory err) internal {
        vm.startPrank(who);
        imd.approve(address(tribunal), type(uint256).max);
        oracleFeeToken().approve(address(tribunal), type(uint256).max);
        vm.stopPrank();
        vm.expectRevert(err);
        vm.prank(who);
        tribunal.object(pleaId, "That plea is boilerplate: the same three lines as every other sell this week.");
    }

    function objectFails(address who, uint256 pleaId, bytes4 err) internal {
        objectFails(who, pleaId, abi.encodePacked(err));
    }

    /// @dev The Intake's writer completes an objection's request with a signed re-score.
    function rule(uint256 objectionId, uint256 score) internal returns (bool) {
        bytes32 intakeId = tribunal.objection(objectionId).intakeId;
        OracleAttestation.Attestation memory a = attestation(score, keccak256(abi.encode("objection", objectionId)));
        return intake.complete(intakeId, 0, abi.encode(intakeId, a, signFor(address(tribunal), a)));
    }

    /// @dev The Intake's writer completes the request with a signed score (status 0).
    function answer(uint256 id, uint256 score) internal returns (bool) {
        return deliver(intakeIdOf(id), attestation(score, keccak256(abi.encode("oracle", id))));
    }

    function deliver(bytes32 intakeId, OracleAttestation.Attestation memory a) internal returns (bool) {
        return intake.complete(intakeId, 0, abi.encode(intakeId, a, sign(a)));
    }

    /// @dev Buy, wait, plead 10% and get approved with `score`; returns the plea id.
    function approvedPlea(address who, uint256 score) internal returns (uint256 id) {
        uint256 bal = plea.balanceOf(who);
        id = plead(who, bal / 10);
        require(answer(id, score), "not delivered");
    }

    /// @dev Keeps the Cabal alive: a denied verdict resets the dead-man without points.
    function keepAlive(address who) internal {
        uint256 id = plead(who, plea.balanceOf(who) / 10);
        require(answer(id, 0), "not delivered");
    }

    /// @dev A week passes (six steps of 28 hours) while `who` keeps the Cabal alive. Under the run-7
    /// fact table a sale above 15% of the balance needs the 7-day holding points to be possible at
    /// all, so tests that sell a larger share hold a week first.
    function holdAWeek(address who) internal {
        for (uint256 i; i < 6; ++i) {
            skip(28 hours);
            keepAlive(who);
        }
    }

    /// @dev A 24-hour "up" trend for the fact score, 24 hours long: a small buy checkpoints the
    /// current price as the day-old reference, 23 hours later `who` buys `imdIn`, and the next hour's
    /// first trade (a small buy) checkpoints the lifted price. The reference must lie within two days
    /// (round 4, R4-A1-1), so a quiet week before this reads as "no history" without it.
    function trendUp(address who, uint256 imdIn) internal {
        buy(who, 1e18);
        skip(23 hours);
        buy(who, imdIn);
        skip(1 hours);
        buy(who, 1e18);
    }
}
