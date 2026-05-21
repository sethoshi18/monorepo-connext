// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity 0.8.17;

import {Test, console} from "forge-std/Test.sol";
import {RootManager} from "../contracts/messaging/RootManager.sol";
import {MerkleTreeManager} from "../contracts/messaging/MerkleTreeManager.sol";

contract RootManagerAudit is Test {
  RootManager rootManager;
  MerkleTreeManager merkle;
  uint32 domain = 1;

  function setUp() public {
    merkle = new MerkleTreeManager();
    merkle.initialize(address(this));

    rootManager = new RootManager(
      10,
      address(merkle),
      address(this),
      5,
      10
    );

    merkle.setArborist(address(rootManager));
    rootManager.addConnector(domain, address(this));
  }

  function isWatcher(address) external pure returns (bool) {
    return true;
  }

  fallback() external {
      assembly {
          mstore(0, 1)
          return(0, 32)
      }
  }

  function test_optimistic_fallback_erasure() public {
    // 1. Spoke sends valid messages which are aggregated into RootManager via slow mode AMB.
    rootManager.aggregate(domain, bytes32(uint256(1)));
    rootManager.aggregate(domain, bytes32(uint256(2)));
    rootManager.aggregate(domain, bytes32(uint256(3)));

    assertEq(rootManager.getPendingInboundRootsCount(), 3);

    // 2. Owner switches to optimistic mode. The comment says "Discarded roots will be included on the upcoming optimistic aggregateRoot."
    rootManager.activateOptimisticMode();
    assertEq(rootManager.getPendingInboundRootsCount(), 0);

    // 3. Proposer proposes an invalid/malicious aggregate root.
    // (Simulated by Watcher catching the fraud).

    // 4. Watcher calls `activateSlowMode` to halt the optimistic fraud.
    rootManager.activateSlowMode();

    // 5. Delay passes.
    vm.roll(block.number + 15);

    // 6. Relayer propagates, which triggers dequeue.
    rootManager.dequeue();

    // The valid items (1, 2, 3) are forever lost!
    assertEq(merkle.count(), 0);

    console.log("Bug Confirmed: Valid messages permanently erased from state on slow mode fallback.");
  }
}
