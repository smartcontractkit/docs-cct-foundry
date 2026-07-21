// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IConfigSource
/// @notice The config-sync seam: abstracts *where* CCIP chain metadata comes from, so the config
/// writer (`script/config/SyncCcipConfig.s.sol`) is decoupled from any specific API version. An
/// implementation fetches a chain's ACTIVE CCIP address set and returns it as a compact, normalized,
/// flat JSON object whose keys mirror the repo's `config/chains/<name>.json` `ccip{}` block
/// (`router`, `rmnProxy`, `tokenAdminRegistry`, `registryModuleOwnerCustom`, `link`, `feeQuoter`,
/// `tokenPoolFactory`, `feeTokens[]`), plus `apiName` + `chainId` so the caller can cross-check the
/// selector's identity against the local config (the SELECTOR MISMATCH guard).
/// @dev Swapping the config source (a future API version, or a local snapshot for offline testing)
/// is a one-file change: provide a new implementation of this interface. The current implementation
/// is `CcipApiSource` (CCIP REST API v2, `https://api.ccip.chain.link/v2`).
interface IConfigSource {
    /// @notice Fetches a chain's ACTIVE CCIP infrastructure addresses, normalized to a flat JSON object.
    /// @param chainSelector The CCIP chain selector (uint64) identifying the chain.
    /// @return flatJson A compact JSON object: {apiName, chainId, router, rmnProxy, tokenAdminRegistry,
    /// registryModuleOwnerCustom, link, feeQuoter, tokenPoolFactory, feeTokens:[...]} - every address
    /// already resolved to the `isActive` entry.
    function fetchActiveCcipConfig(uint64 chainSelector) external returns (string memory flatJson);
}
