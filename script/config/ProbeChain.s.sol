// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

/// @notice Read a chain's CCIP wiring over plain JSON-RPC, WITHOUT forking it.
///
/// @dev Why this exists alongside `doctor`. Every other read primitive reaches the chain by
///      `vm.createSelectFork`, which pulls in Foundry's fork backend and with it `eth_getProof` and
///      EIP-1898 block-hash calls. A chain that serves ordinary `eth_call` but not those cannot be read
///      at all, even though the work here is code presence and a few view calls. `vm.rpc` issues the
///      request directly, so the fork backend never runs.
///
///      The commoner failure is subtler than an unsupported method: `createSelectFork` pins whatever
///      one node called `latest`, and a later request routed to a node a moment behind cannot serve
///      that block (`{"message":"Unknown block"}`). How badly that bites scales with block time - on
///      Monad (~0.3s blocks) a few hundred milliseconds of lag is several blocks gone, while Sepolia's
///      ~12s blocks absorb it. Measured on `make doctor` against monad-testnet: 3 of 10 runs failed
///      through a paid load-balanced gateway, 9 of 10 through its free tier, 0 of 3 through the
///      chain's own RPC. This target pins no block, so that class cannot reach it.
///
///      This is deliberately READ-ONLY and additive. It writes nothing, and it does not replace
///      `doctor`: `doctor` verifies far more, and where forking works it stays the fuller check. Use
///      this when `doctor` cannot reach the chain at all, or to answer "is this endpoint usable"
///      before a longer run.
///
///      Every value is reported, never asserted, with one exception: a chainId mismatch is fatal,
///      because public RPC directories carry chainId collisions and every later line would then
///      describe a different chain.
///
///      Usage: make probe-chain CHAIN=<selectorName>
///      Raw:   forge script script/config/ProbeChain.s.sol --sig "run(string)" <selectorName>
/// @dev Holds the calls that must be catchable. `try this.f()` would be the obvious way to make a
///      failing `vm.rpc` recoverable, but it compiles to `address(this)`, which forge refuses inside a
///      Script contract ("script contracts are ephemeral"). A separate contract gives the same
///      try/catch boundary without one.
contract RpcReader {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function rawRpc(string memory url, string memory method, string memory params) external returns (bytes memory) {
        return VM.rpc(url, method, params);
    }

    function ethCall(string memory url, address to, bytes memory data) external returns (bytes memory) {
        string memory params =
            string.concat("[{\"to\":\"", VM.toString(to), "\",\"data\":\"", VM.toString(data), "\"},\"latest\"]");
        return VM.rpc(url, "eth_call", params);
    }

    function decodeString(bytes memory raw) external pure returns (string memory) {
        return abi.decode(raw, (string));
    }
}

contract ProbeChain is Script {
    string internal constant CONFIG_DIR = "config/chains/";
    uint256 internal constant RPC_ATTEMPTS = 3;
    uint256 internal constant RPC_BACKOFF_MS = 250;

    uint256 internal s_passes;
    uint256 internal s_fails;
    RpcReader internal s_reader;

    function run(string memory name) external {
        s_reader = new RpcReader();

        string memory path = string.concat(CONFIG_DIR, name, ".json");
        require(vm.exists(path), string.concat("no ", path, " - onboard the chain first: make add-chain"));
        string memory json = vm.readFile(path);

        // Non-EVM chains speak a different RPC entirely; there is nothing here that would apply.
        string memory family = vm.parseJsonString(json, ".chainFamily");
        require(
            keccak256(bytes(family)) == keccak256(bytes("evm")),
            string.concat("probe-chain reads EVM JSON-RPC; ", name, " is chainFamily '", family, "'")
        );

        string memory rpcEnv = vm.parseJsonString(json, ".rpcEnv");
        string memory url = vm.envOr(rpcEnv, string(""));
        require(
            bytes(url).length > 0, string.concat("env ", rpcEnv, " unset - set it in ./.env, or export it, then re-run")
        );

        console.log(string.concat("== probe-chain ", name, " (no fork; plain JSON-RPC) =="));

        // The identity gate. Not a report line: if the endpoint answers for another chain, everything
        // below would be true of that chain instead, which is worse than no answer at all.
        uint256 declaredId = vm.parseJsonUint(json, ".chainId");
        uint256 liveId = _chainId(url);
        require(
            liveId == declaredId,
            string.concat(
                "RPC answers as chain ",
                vm.toString(liveId),
                " but ",
                name,
                " declares ",
                vm.toString(declaredId),
                " - wrong endpoint for this chain"
            )
        );
        _pass(string.concat("rpc: reachable, eth_chainId == ", vm.toString(declaredId)));

        // The CCIP core. `link` is a token rather than a CCIP contract, but a chain whose LINK address
        // has no code cannot pay a fee, so it is checked with the rest.
        _reportCode(url, json, ".ccip.router", "router");
        _reportCode(url, json, ".ccip.rmnProxy", "rmnProxy");
        _reportCode(url, json, ".ccip.tokenAdminRegistry", "tokenAdminRegistry");
        _reportCode(url, json, ".ccip.registryModuleOwnerCustom", "registryModuleOwnerCustom");
        _reportCode(url, json, ".ccip.link", "link");

        // typeAndVersion is the one string that says WHAT a contract is. It is read tolerantly: a
        // contract that does not expose it is reported as such, never treated as absent or wrong.
        address tar = _addressOr(json, ".ccip.tokenAdminRegistry", address(0));
        if (tar != address(0)) {
            (bool ok, string memory tv) = _typeAndVersion(url, tar);
            if (ok) {
                _pass(string.concat("tokenAdminRegistry typeAndVersion: ", tv));
            } else {
                _note("tokenAdminRegistry did not answer typeAndVersion() - readable, but unidentified");
            }
        }

        console.log("");
        console.log(
            string.concat(
                "== probe-chain ", name, ": ", vm.toString(s_passes), " ok, ", vm.toString(s_fails), " unreadable =="
            )
        );
        // Reporting, not a verdict: a missing optional contract is a fact about the chain, not a
        // failure of the probe. The caller decides what to do with it.
    }

    /// @dev One `vm.rpc` is one HTTP request with no retry of its own, where the fork backend pools
    ///      and retries - which made this the MORE fragile reader on a shaky endpoint, the exact
    ///      situation it exists for. Measured on Pharos mainnet before this loop: 5 runs in 8, the rest
    ///      dying mid-read on a transport error. A failed request is retried; a request that ANSWERS is
    ///      never retried, so a chain legitimately reporting "no code" still costs one call.
    function _rpc(string memory url, string memory method, string memory params) internal returns (bytes memory) {
        for (uint256 attempt = 0; attempt < RPC_ATTEMPTS; attempt++) {
            try s_reader.rawRpc(url, method, params) returns (bytes memory raw) {
                return raw;
            } catch {
                if (attempt + 1 == RPC_ATTEMPTS) revert(string.concat("rpc failed after retries: ", method));
                vm.sleep(RPC_BACKOFF_MS * (attempt + 1)); // linear backoff; the failures are transport, not load
            }
        }
        revert("unreachable");
    }

    /// @dev eth_chainId returns a minimal-width hex quantity ("0xaa36a7"), not a padded word, so it is
    ///      folded big-endian by hand rather than abi.decode'd.
    function _chainId(string memory url) internal returns (uint256 id) {
        bytes memory raw = _rpc(url, "eth_chainId", "[]");
        for (uint256 i = 0; i < raw.length; i++) {
            id = (id << 8) | uint8(raw[i]);
        }
    }

    function _hasCode(string memory url, address a) internal returns (bool) {
        string memory params = string.concat("[\"", vm.toString(a), "\",\"latest\"]");
        return _rpc(url, "eth_getCode", params).length > 0;
    }

    function _typeAndVersion(string memory url, address a) internal returns (bool ok, string memory tv) {
        try s_reader.ethCall(url, a, abi.encodeWithSignature("typeAndVersion()")) returns (bytes memory raw) {
            if (raw.length == 0) return (false, "");
            // A non-conforming return decodes to nonsense or reverts the decode; either way it is not
            // an answer, and this reports rather than guesses.
            try s_reader.decodeString(raw) returns (string memory s) {
                return (bytes(s).length > 0, s);
            } catch {
                return (false, "");
            }
        } catch {
            return (false, "");
        }
    }

    function _reportCode(string memory url, string memory json, string memory key, string memory label) internal {
        address a = _addressOr(json, key, address(0));
        if (a == address(0)) {
            _note(string.concat(label, ": not declared in this config"));
            return;
        }
        if (_hasCode(url, a)) {
            _pass(string.concat(label, ": code present at ", vm.toString(a)));
        } else {
            _fail(string.concat(label, ": NO CODE at ", vm.toString(a)));
        }
    }

    function _addressOr(string memory json, string memory key, address dflt) internal view returns (address) {
        if (!vm.keyExistsJson(json, key)) return dflt;
        return vm.parseJsonAddress(json, key);
    }

    function _pass(string memory m) internal {
        s_passes++;
        console.log(string.concat("[ ok ] ", m));
    }

    function _fail(string memory m) internal {
        s_fails++;
        console.log(string.concat("[FAIL] ", m));
    }

    function _note(string memory m) internal pure {
        console.log(string.concat("[note] ", m));
    }
}
