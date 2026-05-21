# Security Review Report: Permanent Loss of Pending Inbound Roots upon Optimistic-to-Slow Mode Fallback in `RootManager.sol`

## Executive Summary
A critical architectural flaw exists in `RootManager.sol`'s state machine handling of the transition between optimistic and slow modes. When `activateOptimisticMode()` is called, the contract intentionally truncates the `pendingInboundRoots` queue (`pendingInboundRoots.last = pendingInboundRoots.first - 1;`) to clear out slow-mode messages, under the assumption that these roots will be included in the upcoming off-chain optimistic proposition. However, if a Watcher detects fraud in the optimistic proposition and invokes `activateSlowMode()` to fall back to on-chain verification, the previously truncated valid inbound roots are not recovered. Consequently, perfectly valid cross-chain messages sent via the AMB are permanently erased from the system, leading to a permanent invariant mismatch where users' locked assets on the Spoke domains can never be claimed on the destination chains.

## Detailed Technical Scenario
1. The protocol operates in slow mode, and several spokes send valid inbound roots to the hub. These roots are enqueued into `pendingInboundRoots` via the `aggregate` function.
2. The owner transitions the system to optimistic mode by invoking `activateOptimisticMode()`. During this transition, `pendingInboundRoots.last` is artificially decremented, effectively setting the queue's length to `0` and logically deleting all pending items.
3. An off-chain proposer acts maliciously or erroneously, submitting a fraudulent `proposeAggregateRoot`.
4. A Watcher detects the fraud within the dispute window and calls `activateSlowMode()`. This sets `optimisticMode = false` and resets `proposedAggregateRootHash` to `FINALIZED_HASH`, neutralizing the fraudulent proposal.
5. The system is now safely back in slow mode. However, the valid inbound roots from Step 1 remain logically erased from the queue.
6. When the verification delay passes and `dequeue()` is triggered (e.g. via `propagate`), the queue returns `0` elements. The valid inbound roots are never inserted into the `MerkleTreeManager`, and the corresponding cross-chain messages permanently fail to settle, breaking the core protocol invariant.

## Systemic Impact
This vulnerability creates a catastrophic Denial of Service (DoS) and permanent lock-up of funds. Any time a fraudulent proposal is made and correctly disputed by a Watcher, the necessary fallback to slow mode inadvertently wipes out all in-flight legitimate messages that were pending at the time optimistic mode was activated. This breaks the ledger invariant where assets locked on the origin spoke must be claimable on the destination domain.

## Verification: Local Regression Test

```solidity
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
      10, // delayBlocks
      address(merkle),
      address(this), // watcherManager
      5, // minDisputeBlocks
      10 // disputeBlocks
    );

    merkle.setArborist(address(rootManager));
    rootManager.addConnector(domain, address(this));
  }

  function isWatcher(address) external pure returns (bool) {
    return true;
  }

  // Mock WatcherManager behavior
  fallback() external {
      assembly {
          mstore(0, 1)
          return(0, 32)
      }
  }

  function test_optimistic_fallback_erasure() public {
    // 1. Spoke sends valid messages which are aggregated into RootManager via slow mode.
    rootManager.aggregate(domain, bytes32(uint256(1)));
    rootManager.aggregate(domain, bytes32(uint256(2)));
    rootManager.aggregate(domain, bytes32(uint256(3)));

    assertEq(rootManager.getPendingInboundRootsCount(), 3);

    // 2. Owner switches to optimistic mode. The pending inbound queue is truncated.
    rootManager.activateOptimisticMode();
    assertEq(rootManager.getPendingInboundRootsCount(), 0);

    // 3. Proposer proposes an invalid/malicious aggregate root (Simulated).
    // 4. Watcher correctly detects the fraud and calls activateSlowMode to halt it.
    rootManager.activateSlowMode();

    // 5. Delay passes.
    vm.roll(block.number + 15);

    // 6. Relayer propagates, which triggers dequeue in slow mode.
    rootManager.dequeue();

    // 7. Verify Invariant Failure: The valid items (1, 2, 3) are forever lost!
    assertEq(merkle.count(), 0);

    console.log("Bug Confirmed: Valid messages permanently erased from state on slow mode fallback.");
  }
}
```
