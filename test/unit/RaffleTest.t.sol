// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "@mocks/VRFCoordinatorV2Mock.sol";
import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Raffle} from "../../src/Raffle.sol";

contract RaffleTest is Test {
    /** INTERFACE, LIBRARY, CONTRACT */
    Raffle private raffle;

    /** CONSTANT */
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    /** IMMUTABLE */
    address public immutable i_player = makeAddr("player");

    /** STORAGE */
    HelperConfig private s_config;
    uint256 private s_entranceFee;
    uint256 private s_interval;
    address private s_vrfCoordinator;
    bytes32 private s_gasLane;
    uint64 private s_subscriptionId;
    uint32 private s_callbackGasLimit;
    address private s_link;

    /** EVENT */
    event EnteredRaffle(address indexed player);

    modifier raffleEnterandTimePassed() {
        vm.prank(i_player);
        raffle.enterRaffle{value: s_entranceFee}();
        vm.warp(block.timestamp + s_interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    modifier skipFork() {
        if (block.chainid != 31337) {
            // not on local network
            return;
        }
        _;
    }

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, s_config) = deployer.run();
        (
            s_entranceFee,
            s_interval,
            s_vrfCoordinator,
            s_gasLane,
            s_subscriptionId,
            s_callbackGasLimit,
            s_link,

        ) = s_config.activeNetworkConfig();
        vm.deal(i_player, STARTING_USER_BALANCE);
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN); // assertEq doesn't work with enums
    }

    /**
     * Raffle entrance
     */

    function testRaffleRevertsWhenYouDontPayEnough() public {
        vm.prank(i_player);
        vm.expectRevert(Raffle.Raffle__NotEnoughEthSent.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordsPlayerWhenTheyEnter() public {
        vm.prank(i_player);
        raffle.enterRaffle{value: s_entranceFee}();
        assertEq(i_player, raffle.getPlayer(0));
    }

    function testEmitEventOnEntrance() public {
        vm.prank(i_player);
        vm.expectEmit(true, false, false, false, address(raffle));
        emit EnteredRaffle(i_player);
        raffle.enterRaffle{value: s_entranceFee}();
    }

    function testCantEnterWhenRaffleIsClosed() public raffleEnterandTimePassed {
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(i_player);
        raffle.enterRaffle{value: s_entranceFee}();
    }

    /**
     * Raffle checkUpkeep
     */

    function testCheckUpkeepReturnsFalseIfItHasNoBalance() public {
        vm.warp(block.timestamp + s_interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        assertEq(upkeepNeeded, false);
    }

    function testCheckUpkeepReturnsFalseIfItHasNotOpen()
        public
        raffleEnterandTimePassed
    {
        raffle.performUpkeep("");

        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        assertEq(upkeepNeeded, false);
    }

    function testCheckUpkeepReturnsFalseIfNotEnoughTimeHasPassed() public {
        vm.prank(i_player);
        raffle.enterRaffle{value: s_entranceFee}();

        (bool upkeepNeeded, ) = raffle.checkUpkeep("");
        assertEq(upkeepNeeded, false);
    }

    function testCheckUpkeepReturnsTrueWhenParametrsAreGood()
        public
        raffleEnterandTimePassed
    {
        (bool upkeepNeeded, ) = raffle.checkUpkeep(""); // raffleState is OPEN on construct
        assertEq(upkeepNeeded, true);
    }

    /**
     * Raffle performUpkeep
     */

    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue()
        public
        raffleEnterandTimePassed
    {
        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Raffle.Raffle__UpkeepNotNeeded.selector,
                address(raffle).balance,
                raffle.getPlayers().length,
                raffle.getRaffleState()
            )
        );
        raffle.performUpkeep("");
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitsRequestId()
        public
        raffleEnterandTimePassed
    {
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        assert(uint256(requestId) > 0);
        assert(raffle.getRaffleState() == Raffle.RaffleState.CLOSE);
    }

    /**
     * Raffle fulfillRandomWords
     */

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(
        uint256 randomRequestId
    ) public skipFork raffleEnterandTimePassed {
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(s_vrfCoordinator).fulfillRandomWords(
            randomRequestId,
            address(raffle)
        );
    }

    function testFulfillRandomWordsPicksAWinnerResetsAndSendsMoney()
        public
        skipFork
        raffleEnterandTimePassed
    {
        uint256 additionalEntrants = 5;
        for (uint256 i = 1; i < additionalEntrants + 1; i++) {
            address player = address(uint160(i));
            hoax(player, STARTING_USER_BALANCE);
            raffle.enterRaffle{value: s_entranceFee}();
        }

        uint256 prize = s_entranceFee * (additionalEntrants + 1);

        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        uint256 previousTimestap = raffle.getLastTimestap();

        // pretend to be chainlink vrt to get random number & pick a winner
        VRFCoordinatorV2Mock(s_vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(raffle)
        );

        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
        assert(raffle.getLastWinner() != address(0));
        assert(raffle.getPlayers().length == 0);
        assert(raffle.getLastTimestap() > previousTimestap);
        assert(address(raffle).balance == 0);
        assert(
            address(raffle.getLastWinner()).balance ==
                (STARTING_USER_BALANCE - s_entranceFee + prize)
        );
    }
}
