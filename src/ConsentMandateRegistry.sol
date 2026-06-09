// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title ConsentMandateRegistry
 * @notice Registers AP2 Intent Mandates that authorize an agent to send
 *         transactional SMS on a user's behalf via tollkit.dev's x402 seller.
 *
 *         An Intent Mandate is an EIP-712 signed message from the recipient
 *         (the consumer who owns the phone number) granting a specific agent
 *         a capped budget of messages over a time window. Once registered,
 *         the off-chain seller can debit messages against the mandate without
 *         a per-message on-chain transaction, then batch-settle the
 *         accumulated USDC via x402 V2 transferWithAuthorization.
 *
 *         This contract is the on-chain anchor for AP2 mandates in the
 *         tollkit.dev family of paid developer tools. It is intentionally
 *         minimal: storage of signed mandates, signature verification, and
 *         events. It does NOT custody funds. Funds flow through x402 at
 *         settlement time directly between the buyer wallet and the seller
 *         wallet, using EIP-3009 transferWithAuthorization.
 *
 *         Deployed targets:
 *         - Arbitrum Sepolia (testnet): TBD on deploy
 *         - Arbitrum One (mainnet):     TBD on deploy
 *
 *         Submitted to Arbitrum Open House London 2026 as part of the
 *         tollkit-sms buildathon submission.
 */
contract ConsentMandateRegistry is EIP712 {
    using ECDSA for bytes32;

    // ────────────────────────────────────────────────────────────────────
    // Types
    // ────────────────────────────────────────────────────────────────────

    /// @notice Off-chain Intent Mandate data, signed by the recipient.
    /// @dev Mirrors AP2's Intent Mandate primitive, scoped for SMS use.
    struct Mandate {
        address recipient;      // wallet that owns the phone number / signs consent
        address authorizedAgent;// public key of the agent allowed to spend
        address buyerWallet;    // wallet that pays for messages via x402 settlement
        bytes32 phoneHash;      // keccak256 of normalized E.164 phone number
        uint256 maxMessages;    // cap on number of messages
        uint256 maxUsdc;        // cap on total USDC spend (6 decimals on Base/Arbitrum USDC)
        uint64  notBefore;      // unix timestamp lower bound
        uint64  expiresAt;      // unix timestamp upper bound
        uint256 nonce;          // mandate-level replay protection
    }

    /// @notice EIP-712 typehash for the Mandate struct.
    bytes32 public constant MANDATE_TYPEHASH = keccak256(
        "Mandate(address recipient,address authorizedAgent,address buyerWallet,bytes32 phoneHash,uint256 maxMessages,uint256 maxUsdc,uint64 notBefore,uint64 expiresAt,uint256 nonce)"
    );

    /// @notice Per-mandate state tracked on-chain.
    struct MandateState {
        bool registered;        // was this mandate ever registered
        bool revoked;           // has the recipient revoked it
        uint128 spentMessages;  // running count of messages debited off-chain
        uint128 spentUsdc;      // running USDC debited off-chain (6 decimals)
    }

    // ────────────────────────────────────────────────────────────────────
    // Storage
    // ────────────────────────────────────────────────────────────────────

    /// @notice mandateId => state. Mandate ID is the EIP-712 digest.
    mapping(bytes32 => MandateState) public mandates;

    /// @notice recipient => nonces consumed (replay protection)
    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    /// @notice seller address authorized to record spend updates off-chain → on-chain.
    /// @dev set at construction; cannot be changed. Trustless mandate
    ///      verification is on signature; trust in spend reporting is on
    ///      the seller. Future versions may move spend tracking off-chain
    ///      entirely and use the registry only for revocation.
    address public immutable seller;

    // ────────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────────

    event MandateRegistered(
        bytes32 indexed mandateId,
        address indexed recipient,
        address indexed authorizedAgent,
        address buyerWallet,
        bytes32 phoneHash,
        uint256 maxMessages,
        uint256 maxUsdc,
        uint64 notBefore,
        uint64 expiresAt,
        uint256 nonce
    );

    event MandateRevoked(
        bytes32 indexed mandateId,
        address indexed recipient
    );

    event MandateSpent(
        bytes32 indexed mandateId,
        uint128 messagesAdded,
        uint128 usdcAdded,
        uint128 totalMessagesSpent,
        uint128 totalUsdcSpent
    );

    // ────────────────────────────────────────────────────────────────────
    // Errors
    // ────────────────────────────────────────────────────────────────────

    error InvalidSignature();
    error AlreadyRegistered();
    error NotRegistered();
    error MandateRevoked_();
    error MandateExpired();
    error MandateNotYetActive();
    error CapExceededMessages();
    error CapExceededUsdc();
    error OnlyRecipient();
    error OnlySeller();
    error NonceAlreadyUsed();

    // ────────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────────

    constructor(address _seller) EIP712("tollkit.ConsentMandateRegistry", "1") {
        require(_seller != address(0), "seller=0");
        seller = _seller;
    }

    // ────────────────────────────────────────────────────────────────────
    // Mandate lifecycle
    // ────────────────────────────────────────────────────────────────────

    /**
     * @notice Register a mandate. Anyone may call as long as the signature
     *         is valid and the nonce hasn't been used by this recipient.
     *         In practice the seller relays this on the recipient's behalf
     *         to keep the recipient's gas burden zero.
     */
    function registerMandate(Mandate calldata m, bytes calldata signature)
        external
        returns (bytes32 mandateId)
    {
        if (nonceUsed[m.recipient][m.nonce]) revert NonceAlreadyUsed();
        if (block.timestamp >= m.expiresAt) revert MandateExpired();

        mandateId = _hashMandate(m);
        address signer = mandateId.recover(signature);
        if (signer != m.recipient) revert InvalidSignature();

        MandateState storage st = mandates[mandateId];
        if (st.registered) revert AlreadyRegistered();

        st.registered = true;
        nonceUsed[m.recipient][m.nonce] = true;

        emit MandateRegistered(
            mandateId,
            m.recipient,
            m.authorizedAgent,
            m.buyerWallet,
            m.phoneHash,
            m.maxMessages,
            m.maxUsdc,
            m.notBefore,
            m.expiresAt,
            m.nonce
        );
    }

    /**
     * @notice Recipient can revoke a previously-registered mandate.
     *         After revocation, the seller must reject any further sends
     *         against this mandate.
     */
    function revokeMandate(bytes32 mandateId) external {
        MandateState storage st = mandates[mandateId];
        if (!st.registered) revert NotRegistered();
        // The mandate ID is the EIP-712 digest; we re-verify via recipient call.
        // For simplicity at v1, only require msg.sender to assert ownership via
        // a separate signed revocation (off-chain), and emit an event the seller
        // honors. Future versions may track recipient address on-chain to avoid
        // off-chain trust. For the buildathon scope, revocation is intentionally
        // simple: anyone can flag, seller validates against recorded mandate.
        st.revoked = true;
        emit MandateRevoked(mandateId, msg.sender);
    }

    /**
     * @notice Seller reports off-chain spend against a mandate. Spend is
     *         recorded for transparency; the actual USDC has already moved
     *         (or will move) via x402 batched settlement separately.
     *
     *         The seller calls this periodically (e.g. every 5 messages,
     *         matching the batch-settlement cadence) so the on-chain audit
     *         trail stays in sync with off-chain reality.
     */
    function recordSpend(
        bytes32 mandateId,
        uint128 messagesAdded,
        uint128 usdcAdded,
        uint256 capMessages,
        uint256 capUsdc
    ) external {
        if (msg.sender != seller) revert OnlySeller();

        MandateState storage st = mandates[mandateId];
        if (!st.registered) revert NotRegistered();
        if (st.revoked) revert MandateRevoked_();

        uint128 newMessages = st.spentMessages + messagesAdded;
        uint128 newUsdc = st.spentUsdc + usdcAdded;

        if (uint256(newMessages) > capMessages) revert CapExceededMessages();
        if (uint256(newUsdc) > capUsdc) revert CapExceededUsdc();

        st.spentMessages = newMessages;
        st.spentUsdc = newUsdc;

        emit MandateSpent(
            mandateId,
            messagesAdded,
            usdcAdded,
            newMessages,
            newUsdc
        );
    }

    // ────────────────────────────────────────────────────────────────────
    // Views
    // ────────────────────────────────────────────────────────────────────

    /**
     * @notice EIP-712 digest the recipient must sign to register a mandate.
     */
    function getMandateId(Mandate calldata m) external view returns (bytes32) {
        return _hashMandate(m);
    }

    /**
     * @notice Convenience: recompute the EIP-712 domain separator.
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ────────────────────────────────────────────────────────────────────
    // Internal
    // ────────────────────────────────────────────────────────────────────

    function _hashMandate(Mandate calldata m) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    MANDATE_TYPEHASH,
                    m.recipient,
                    m.authorizedAgent,
                    m.buyerWallet,
                    m.phoneHash,
                    m.maxMessages,
                    m.maxUsdc,
                    m.notBefore,
                    m.expiresAt,
                    m.nonce
                )
            )
        );
    }
}
