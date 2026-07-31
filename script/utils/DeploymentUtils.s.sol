// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title DeploymentUtils
/// @notice Shared deployment-saving utilities used by all deploy scripts to avoid duplication.
/// Each function creates the target directory if it does not exist, writes a timestamped JSON
/// file containing the deployed contract address(es), and prints the saved path to the console.
///
/// @dev The append-only ledger lives under **`history/<category>/<selectorName>/…`**, keyed by the
/// canonical **selectorName** directory. The token, pool, and lock-box file bodies key by
/// `chainNameIdentifier` (e.g. `ETHEREUM_SEPOLIA_TOKEN`), so those callers pass BOTH the selectorName
/// (the directory) and the chainNameIdentifier (the body); the hooks file is named by symbol +
/// poolType and carries a fixed `POOL_HOOKS` body key. Each deploy writes a NEW timestamped file -
/// pure create, never rewrite. `history/` is gitignored.
library DeploymentUtils {
    /// @dev Saves a token deployment.
    /// Output: `history/tokens/{selectorName}/{timestamp}-{symbol}-Token.json`
    /// @param vm              Forge VM cheat-code interface
    /// @param selectorName    Canonical selectorName (the ledger directory, == config basename)
    /// @param chainNameIdentifier Chain identifier string used in the file BODY (e.g. `ETHEREUM_SEPOLIA`)
    /// @param symbol          Token symbol, used as the file-name prefix
    /// @param tokenAddress    Address of the deployed token contract
    function _saveTokenDeployment(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        string memory symbol,
        address tokenAddress
    ) internal {
        string memory deploymentDir = string.concat(vm.projectRoot(), "/history/tokens/", selectorName, "/");
        vm.createDir(deploymentDir, true);

        // Unique serialization handle per call: forge's serialize journal is keyed by the handle and
        // ACCUMULATES across calls in one process, so a shared handle would bleed stale keys from a prior
        // save into this artifact's body (proven for the pool handle). Keying by the address isolates it.
        string memory handle = string.concat("tokenDeployment-", vm.toString(tokenAddress));
        string memory deploymentJson =
            vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile = string.concat(deploymentDir, timestamp, "-", symbol, "-Token.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat("Deployment saved: history/tokens/", selectorName, "/", timestamp, "-", symbol, "-Token.json")
        );
    }

    /// @dev Saves a burn-mint token pool deployment.
    /// Output: `history/token-pools/{selectorName}/{timestamp}-{symbol}-{poolType}TokenPool.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param selectorName        Canonical selectorName (the ledger directory)
    /// @param chainNameIdentifier Chain identifier string used in the file BODY (e.g. `ETHEREUM_SEPOLIA`)
    /// @param tokenPoolAddress    Address of the deployed token pool contract
    /// @param tokenAddress        Address of the token the pool is deployed for (used to resolve the symbol)
    /// @param poolType            Pool type label used in the file name (e.g. `BurnMint`)
    function _saveTokenPoolDeployment(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        address tokenPoolAddress,
        address tokenAddress,
        string memory poolType
    ) internal {
        string memory symbol = _getSymbol(vm, tokenAddress);
        string memory deploymentDir = string.concat(vm.projectRoot(), "/history/token-pools/", selectorName, "/");
        vm.createDir(deploymentDir, true);

        // Unique handle per call (see saveTokenDeployment): a shared "poolDeployment" handle would carry a
        // stale LOCK_BOX key from a prior lock-release save into this burn-mint body.
        string memory handle = string.concat("poolDeployment-", vm.toString(tokenPoolAddress));
        vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN_POOL"), tokenPoolAddress);
        string memory deploymentJson =
            vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile =
            string.concat(deploymentDir, timestamp, "-", symbol, "-", poolType, "TokenPool.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: history/token-pools/",
                selectorName,
                "/",
                timestamp,
                "-",
                symbol,
                "-",
                poolType,
                "TokenPool.json"
            )
        );
    }

    /// @dev Saves a lock-release token pool deployment (includes the associated lock box address).
    /// Output: `history/token-pools/{selectorName}/{timestamp}-{symbol}-{poolType}TokenPool.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param selectorName        Canonical selectorName (the ledger directory)
    /// @param chainNameIdentifier Chain identifier string used in the file BODY (e.g. `ETHEREUM_SEPOLIA`)
    /// @param tokenPoolAddress    Address of the deployed token pool contract
    /// @param tokenAddress        Address of the token the pool is deployed for (used to resolve the symbol)
    /// @param lockBox             Address of the ERC20LockBox associated with this pool
    /// @param poolType            Pool type label used in the file name (e.g. `LockRelease`)
    function _saveLockReleaseTokenPoolDeployment(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        address tokenPoolAddress,
        address tokenAddress,
        address lockBox,
        string memory poolType
    ) internal {
        string memory symbol = _getSymbol(vm, tokenAddress);
        string memory deploymentDir = string.concat(vm.projectRoot(), "/history/token-pools/", selectorName, "/");
        vm.createDir(deploymentDir, true);

        // Unique handle per call (see saveTokenDeployment) so this lock-release body never bleeds keys
        // into (or from) a sibling pool save sharing the process.
        string memory handle = string.concat("poolDeployment-", vm.toString(tokenPoolAddress));
        vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN_POOL"), tokenPoolAddress);
        vm.serializeAddress(handle, "LOCK_BOX", lockBox);
        string memory deploymentJson =
            vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile =
            string.concat(deploymentDir, timestamp, "-", symbol, "-", poolType, "TokenPool.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: history/token-pools/",
                selectorName,
                "/",
                timestamp,
                "-",
                symbol,
                "-",
                poolType,
                "TokenPool.json"
            )
        );
    }

    /// @dev Saves a lock box deployment.
    /// Output: `history/lock-boxes/{selectorName}/{timestamp}-{symbol}-LockBox.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param selectorName        Canonical selectorName (the ledger directory)
    /// @param chainNameIdentifier Chain identifier string used in the file BODY (e.g. `ETHEREUM_SEPOLIA`)
    /// @param lockBoxAddress      Address of the deployed ERC20LockBox contract
    /// @param tokenAddress        Address of the token the lock box is deployed for (used to resolve the symbol)
    function _saveLockBoxDeployment(
        Vm vm,
        string memory selectorName,
        string memory chainNameIdentifier,
        address lockBoxAddress,
        address tokenAddress
    ) internal {
        string memory symbol = _getSymbol(vm, tokenAddress);
        string memory deploymentDir = string.concat(vm.projectRoot(), "/history/lock-boxes/", selectorName, "/");
        vm.createDir(deploymentDir, true);

        // Unique handle per call (see saveTokenDeployment).
        string memory handle = string.concat("lockBoxDeployment-", vm.toString(lockBoxAddress));
        vm.serializeAddress(handle, "LOCK_BOX", lockBoxAddress);
        string memory deploymentJson =
            vm.serializeAddress(handle, string.concat(chainNameIdentifier, "_TOKEN"), tokenAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory deploymentFile = string.concat(deploymentDir, timestamp, "-", symbol, "-LockBox.json");
        vm.writeJson(deploymentJson, deploymentFile);

        console.log(
            string.concat(
                "Deployment saved: history/lock-boxes/", selectorName, "/", timestamp, "-", symbol, "-LockBox.json"
            )
        );
    }

    /// @dev Saves an AdvancedPoolHooks deployment.
    /// Output: `history/advanced-pool-hooks/{selectorName}/{timestamp}-{symbol}-{poolType}AdvancedPoolHooks.json`
    /// @param vm                  Forge VM cheat-code interface
    /// @param selectorName        Canonical selectorName (the ledger directory)
    /// @param symbol              Token symbol (distinguishes co-located tokens' hooks, matching the ledger)
    /// @param poolType            Pool type the hooks belong to
    /// @param hooksAddress        Address of the deployed AdvancedPoolHooks contract
    function _savePoolHooksDeployment(
        Vm vm,
        string memory selectorName,
        string memory symbol,
        string memory poolType,
        address hooksAddress
    ) internal {
        string memory deploymentDir =
            string.concat(vm.projectRoot(), "/history/advanced-pool-hooks/", selectorName, "/");
        vm.createDir(deploymentDir, true);

        // Unique handle per call (see saveTokenDeployment) for isolation across sibling saves.
        string memory handle = string.concat("hooksDeployment-", vm.toString(hooksAddress));
        string memory deploymentJson = vm.serializeAddress(handle, "POOL_HOOKS", hooksAddress);
        string memory timestamp = vm.toString(block.timestamp);
        string memory fileName = string.concat(timestamp, "-", symbol, "-", poolType, "AdvancedPoolHooks.json");
        vm.writeJson(deploymentJson, string.concat(deploymentDir, fileName));

        console.log(string.concat("Deployment saved: history/advanced-pool-hooks/", selectorName, "/", fileName));
    }

    /// @dev Resolves the token symbol by calling `symbol()` on the token contract, falling back to
    /// the TOKEN_SYMBOL environment variable, or "unknown" if neither is available.
    /// `internal` so the single-writer `DeploymentRecorder` composes the registry key from the same
    /// symbol the ledger file is named with.
    function _getSymbol(Vm vm, address tokenAddress) internal view returns (string memory symbol) {
        (, symbol) = _trySymbol(vm, tokenAddress);
    }

    /// @notice The token's symbol, and whether one was established.
    /// @dev `_getSymbol` ends at the literal "unknown" when no symbol was established. That is
    ///      serviceable for a filename, but it collides as a registry key: two unreadable tokens on one
    ///      chain both key as "unknown", and the later write overwrites the earlier. Callers that key
    ///      storage on the symbol use this variant and refuse when `ok` is false.
    ///
    ///      `TOKEN_SYMBOL` covers both ways a token can fail to supply one: a `symbol()` that reverts and
    ///      a `symbol()` that answers the empty string. If it only covered the revert, a token answering
    ///      "" would be told to set `TOKEN_SYMBOL` and then have the value ignored.
    /// @return ok True when a non-empty symbol other than the literal "unknown" came from the token or
    ///         from `TOKEN_SYMBOL`. The empty string and "unknown" count as no symbol wherever they came
    ///         from: both are what a failure looks like, so neither can key the registry.
    /// @return symbol The symbol as established, which is "unknown" or empty when `ok` is false.
    function _trySymbol(Vm vm, address tokenAddress) internal view returns (bool ok, string memory symbol) {
        return _establishSymbol(_readSymbol(tokenAddress), vm.envOr("TOKEN_SYMBOL", string("unknown")));
    }

    /// @dev The raw on-chain read: a `symbol()` that reverts and one that is absent both come back as
    ///      the empty string, the same shape as a token answering "".
    function _readSymbol(address tokenAddress) internal view returns (string memory symbol) {
        try IERC20Metadata(tokenAddress).symbol() returns (string memory s) {
            symbol = s;
        } catch {}
    }

    /// @dev The decision, separated from the reads so it can be pinned without `vm.setEnv` (which is
    ///      process-wide while tests run in parallel): the token's answer wins when non-empty, the
    ///      fallback covers everything else, and neither "" nor "unknown" counts from either source.
    function _establishSymbol(string memory fromToken, string memory fallbackSymbol)
        internal
        pure
        returns (bool ok, string memory symbol)
    {
        symbol = bytes(fromToken).length > 0 ? fromToken : fallbackSymbol;
        ok = bytes(symbol).length > 0 && keccak256(bytes(symbol)) != keccak256(bytes("unknown"));
    }

    /// @dev Sentinel meaning "DECIMALS was not supplied": no uint8 can hold it.
    uint256 internal constant DECIMALS_UNSET = type(uint256).max;

    /// @notice The pool's token-decimals constructor argument. `decimals()` is optional in ERC20, and
    /// the pool treats an on-chain read as a cross-check only (`TokenPool` verifies `localTokenDecimals`
    /// against it when it answers, and skips the check when it does not), so a token without the getter
    /// is a designed-for case: the operator supplies `DECIMALS` explicitly. The one thing this never
    /// does is guess - the value is immutable and scales every amount the pool moves.
    /// @param supplied The DECIMALS environment value, `DECIMALS_UNSET` when the variable is not set.
    ///        Read at the call site so the primitives catalog (and any reader of the deploy script)
    ///        sees the input where it is consumed.
    function _resolveTokenDecimals(Vm vm, address tokenAddress, uint256 supplied) internal view returns (uint8) {
        (bool okRead, uint8 read) = _readDecimals(tokenAddress);
        if (!okRead && supplied != DECIMALS_UNSET) {
            console.log(
                string.concat(
                    unicode"⚠️  decimals() not readable on the token; using DECIMALS=",
                    vm.toString(supplied),
                    " as the pool's immutable scaling factor."
                )
            );
            console.log("   Nothing on-chain can verify it - a wrong value mis-scales every transfer and");
            console.log("   only a pool redeploy can fix it.");
        }
        return _establishDecimals(okRead, read, supplied);
    }

    /// @dev The raw on-chain read: absent and reverting `decimals()` look alike, per ERC20 both mean
    ///      "the token does not supply one".
    function _readDecimals(address tokenAddress) internal view returns (bool ok, uint8 value) {
        try IERC20Metadata(tokenAddress).decimals() returns (uint8 d) {
            return (true, d);
        } catch {
            return (false, 0);
        }
    }

    /// @dev The decision, pure so it is pinnable without `vm.setEnv`. `supplied == DECIMALS_UNSET`
    ///      means the DECIMALS variable was not set.
    ///      - read only: use the token's answer (zero-config path);
    ///      - supplied only: use the supplied value (the token has no getter, as ERC20 allows);
    ///      - both: they must agree - the same cross-check the pool constructor makes, surfaced here
    ///        with a message that names the fix (the pool's would be a raw `InvalidDecimalArgs`);
    ///      - neither: refuse, naming the variable to set. A guessed value would deploy a pool whose
    ///        immutable scaling factor nothing downstream can detect as wrong.
    function _establishDecimals(bool okRead, uint8 read, uint256 supplied) internal pure returns (uint8) {
        if (supplied == DECIMALS_UNSET) {
            require(
                okRead,
                "The token does not answer decimals(): set DECIMALS=<n> to the token's decimals to deploy its pool"
            );
            return read;
        }
        require(supplied <= type(uint8).max, "DECIMALS must fit uint8 (0-255)");
        if (okRead) {
            require(
                uint256(read) == supplied,
                string.concat(
                    "DECIMALS=",
                    Strings.toString(supplied),
                    " disagrees with the token's own decimals()=",
                    Strings.toString(read),
                    ": fix or drop the variable"
                )
            );
        }
        return uint8(supplied);
    }
}
