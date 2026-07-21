// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseForkTest} from "../BaseForkTest.t.sol";
import {DeploySafe} from "../../script/governance/DeploySafe.s.sol";
import {ISafe} from "../../src/base/ISafe.sol";
import {SafeTxHash} from "../../src/base/SafeTxHash.sol";

/// @notice Proves the local EIP-712 `safeTxHash` recompute (`SafeTxHash`) against a REAL Safe deployed
///         from the canonical v1.4.1 stack on a Sepolia fork: the recomputed domain separator and
///         transaction hash must equal the Safe's own `domainSeparator()` / `getTransactionHash()`,
///         including under fuzzed inputs. Also pins the `_nonce` typehash gotcha as a regression test.
contract SafeTxHashForkTest is BaseForkTest {
    uint256 internal constant OWNER1_KEY = 0xA11CE;
    uint256 internal constant OWNER2_KEY = 0xB0B;
    uint256 internal constant OWNER3_KEY = 0xC0FFEE;

    ISafe internal safe;

    function setUp() public override {
        super.setUp();
        vm.setEnv(
            "SAFE_OWNERS",
            string.concat(
                vm.toString(vm.addr(OWNER1_KEY)),
                ",",
                vm.toString(vm.addr(OWNER2_KEY)),
                ",",
                vm.toString(vm.addr(OWNER3_KEY))
            )
        );
        vm.setEnv("SAFE_THRESHOLD", "2");
        vm.setEnv("SAFE_SALT_NONCE", "0");
        safe = ISafe(new DeploySafe().run());
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Typehash regression (the `_nonce` gotcha)
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The canonical SafeTx typehash, as Safe >= 1.3.0 hardcodes it on-chain.
    function test_SafeTxTypehash_MatchesCanonicalConstant() public pure {
        assertEq(
            SafeTxHash.SAFE_TX_TYPEHASH,
            0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8,
            "SAFE_TX_TYPEHASH must equal the canonical Safe constant"
        );
    }

    /// @dev GOTCHA regression: encoding the Solidity PARAMETER name `_nonce` instead of the EIP-712
    ///      struct FIELD name `nonce` yields a DIFFERENT typehash - and a `safeTxHash` that never
    ///      matches signer devices. This pins the trap so it cannot be reintroduced.
    function test_SafeTxTypehash_NonceNotUnderscoreNonce() public pure {
        bytes32 wrongTypehash = keccak256(
            "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 _nonce)"
        );
        assertTrue(wrongTypehash != SafeTxHash.SAFE_TX_TYPEHASH, "the _nonce type string must NOT match");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Local recompute == on-chain, against the real Safe
    // ─────────────────────────────────────────────────────────────────────────

    function test_DomainSeparator_MatchesOnChain() public view {
        assertEq(
            SafeTxHash._domainSeparator(block.chainid, address(safe)),
            safe.domainSeparator(),
            "local domain separator recompute must equal Safe.domainSeparator()"
        );
    }

    function test_SafeTxHash_MatchesOnChain_SimpleTransfer() public view {
        SafeTxHash.SafeTx memory t = SafeTxHash.SafeTx({
            to: address(0x1111111111111111111111111111111111111111),
            value: 1 ether,
            data: hex"",
            operation: 0,
            safeTxGas: 0,
            baseGas: 0,
            gasPrice: 0,
            gasToken: address(0),
            refundReceiver: address(0),
            nonce: safe.nonce()
        });
        assertEq(
            SafeTxHash._compute(block.chainid, address(safe), t),
            safe.getTransactionHash(
                t.to,
                t.value,
                t.data,
                t.operation,
                t.safeTxGas,
                t.baseGas,
                t.gasPrice,
                t.gasToken,
                t.refundReceiver,
                t.nonce
            ),
            "local safeTxHash recompute must equal Safe.getTransactionHash()"
        );
    }

    /// @dev Fuzzed cross-check: for arbitrary to/value/data/gas params and both operations, the local
    ///      recompute equals the on-chain hash. This is the strongest form of the three-way check the
    ///      production ceremony applies (recompute == getTransactionHash == safe-hash).
    function testFuzz_SafeTxHash_MatchesOnChain(
        address to,
        uint256 value,
        bytes memory data,
        bool delegateCall,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) public view {
        SafeTxHash.SafeTx memory t = SafeTxHash.SafeTx({
            to: to,
            value: value,
            data: data,
            operation: delegateCall ? 1 : 0,
            safeTxGas: safeTxGas,
            baseGas: baseGas,
            gasPrice: gasPrice,
            gasToken: gasToken,
            refundReceiver: refundReceiver,
            nonce: nonce
        });
        assertEq(
            SafeTxHash._compute(block.chainid, address(safe), t),
            safe.getTransactionHash(
                t.to,
                t.value,
                t.data,
                t.operation,
                t.safeTxGas,
                t.baseGas,
                t.gasPrice,
                t.gasToken,
                t.refundReceiver,
                t.nonce
            ),
            "fuzzed local safeTxHash recompute must equal Safe.getTransactionHash()"
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deploy helper properties
    // ─────────────────────────────────────────────────────────────────────────

    function test_DeploySafe_OwnersAndThreshold() public view {
        assertEq(safe.getThreshold(), 2, "threshold must be 2");
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 3, "must have 3 owners");
        assertTrue(safe.isOwner(vm.addr(OWNER1_KEY)), "owner1 missing");
        assertTrue(safe.isOwner(vm.addr(OWNER2_KEY)), "owner2 missing");
        assertTrue(safe.isOwner(vm.addr(OWNER3_KEY)), "owner3 missing");
    }

    /// @dev Idempotence: rerunning the deploy script for the same owners/threshold/salt returns the
    ///      SAME address without reverting - the property a mirrored multi-chain rollout relies on.
    function test_DeploySafe_RerunReturnsSameAddress() public {
        address again = new DeploySafe().run();
        assertEq(again, address(safe), "rerun must return the same CREATE2 address");
    }
}
