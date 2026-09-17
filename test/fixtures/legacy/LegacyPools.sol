// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Pools as released, compiled from the npm tarballs of those releases, for fixtures that stand in for
// partner deployments. npm 1.6.0 stamps its BurnMintTokenPool "1.5.1"; there is no BurnMint 1.6.0.
import {
    SiloedLockReleaseTokenPool as SiloedLockReleaseTokenPool_1_6_0
} from "@chainlink/contracts-ccip-1.6.0/contracts/pools/SiloedLockReleaseTokenPool.sol";
import {
    BurnMintTokenPool as BurnMintTokenPool_1_5_1
} from "@chainlink/contracts-ccip-1.6.0/contracts/pools/BurnMintTokenPool.sol";
import {
    SiloedLockReleaseTokenPool as SiloedLockReleaseTokenPool_1_6_1
} from "@chainlink/contracts-ccip-1.6.1/contracts/pools/SiloedLockReleaseTokenPool.sol";
import {
    BurnMintTokenPool as BurnMintTokenPool_1_6_1
} from "@chainlink/contracts-ccip-1.6.1/contracts/pools/BurnMintTokenPool.sol";

// Referenced so the compiler emits all four artifacts.
abstract contract LegacyPools {
    function _legacyPoolCreationCodes() internal pure returns (bytes[4] memory) {
        return [
            type(SiloedLockReleaseTokenPool_1_6_0).creationCode,
            type(BurnMintTokenPool_1_5_1).creationCode,
            type(SiloedLockReleaseTokenPool_1_6_1).creationCode,
            type(BurnMintTokenPool_1_6_1).creationCode
        ];
    }
}
