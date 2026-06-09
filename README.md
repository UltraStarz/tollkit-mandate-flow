# tollkit-mandate-flow

> AP2 Intent Mandates for the [tollkit.dev](https://tollkit.dev) family of paid developer tools, settled via x402 V2 on Arbitrum.

**Buildathon submission for [Arbitrum Open House London 2026](https://blog.arbitrum.foundation/open-house-london-registration-is-now-open/).**

Live product the deliverables plug into:

- **[tollkit.dev](https://tollkit.dev)** — umbrella brand landing page
- **[sms.tollkit.dev](https://sms.tollkit.dev)** — production x402 SMS gateway (Twilio toll-free verified, TCPA/CTIA compliant)
- **[npmjs.com/package/x402-sms-mcp](https://www.npmjs.com/package/x402-sms-mcp)** — MCP client for Claude Desktop / Cursor / Windsurf

---

## What's in this repo

The on-chain anchor for the AP2 mandate flow described in our submission:

```
src/
  ConsentMandateRegistry.sol   ← the smart contract
script/
  Deploy.s.sol                 ← Foundry deploy script (Arbitrum Sepolia + One)
test/
  ConsentMandateRegistry.t.sol ← Foundry test suite (6 tests)
foundry.toml                   ← Foundry config with Arbitrum RPC + Arbiscan endpoints
.env.example                   ← required env vars for deploy
```

## The problem we're solving

x402 V2 enables HTTP-native, sub-2-second USDC payments — but per-call settlement still incurs gas (~$0.0005 on Arbitrum). For micropayment APIs (sub-cent SMS, paid AI inference, web scraping), settling every single call on-chain breaks the economics.

[Ben Greenberg's talk at Devworld](https://www.youtube.com/watch?v=YNmcn-mLpv8) put it succinctly: *"An agent paying per API call can't spend dollars on transaction fees for each call."*

## How `ConsentMandateRegistry` solves it

This contract is the on-chain primitive for an **AP2 + x402 hybrid settlement model**:

1. **Recipient signs an Intent Mandate** (EIP-712) authorizing a specific agent to send up to *N* messages to their phone over a time window, paid from a specific buyer wallet.
2. **Agent calls `tollkit-sms /send`** with the mandate ID. Seller verifies the signature, debits an off-chain balance ledger, dispatches the SMS via Twilio.
3. **Every 5 sends**, the seller batches accumulated debits into one on-chain `recordSpend()` call here for the audit trail, and a single x402 V2 `transferWithAuthorization` for the USDC settlement.

**Result:** 50 SMS = 1–2 on-chain transactions. Per-call gas approaches zero. Sub-cent pricing becomes economically viable.

The mandate primitive is **AP2 v0.2 compliant** (donated to FIDO Alliance April 2026) and intentionally chain-agnostic — the same EIP-712 typed-data model deploys cleanly on Arbitrum One, Arbitrum Sepolia, and Base.

## Architecture

```
┌──────────────────┐   1. signs Intent Mandate (EIP-712)        ┌────────────────────────┐
│   Recipient      │ ──────────────────────────────────────────▶│ ConsentMandateRegistry │
│  (phone owner)   │                                            │     (this contract)    │
└──────────────────┘                                            └────────────────────────┘
                                                                            ▲ 4. recordSpend()
                                                                            │   (every 5 sends)
┌──────────────────┐   2. /send + mandateId                     ┌────────────────────────┐
│   AI agent       │ ──────────────────────────────────────────▶│   sms.tollkit.dev      │
│ (Claude / Cursor)│                                            │   (x402 seller, Hono)  │
└──────────────────┘   3. SMS dispatched                        └────────────────────────┘
                       ◀────────────────────────────                       │ 5. x402 V2 settle
                                                                           ▼   (one tx per batch)
                                                                ┌────────────────────────┐
                                                                │   Arbitrum One / Base  │
                                                                │     (USDC EIP-3009)    │
                                                                └────────────────────────┘
```

## Contract surface

```solidity
struct Mandate {
    address recipient;
    address authorizedAgent;
    address buyerWallet;
    bytes32 phoneHash;       // keccak256 of normalized E.164
    uint256 maxMessages;
    uint256 maxUsdc;
    uint64  notBefore;
    uint64  expiresAt;
    uint256 nonce;
}

function registerMandate(Mandate calldata m, bytes calldata signature) external returns (bytes32 mandateId);
function recordSpend(bytes32 mandateId, uint128 messagesAdded, uint128 usdcAdded, uint256 capMessages, uint256 capUsdc) external;
function revokeMandate(bytes32 mandateId) external;
function getMandateId(Mandate calldata m) external view returns (bytes32);
```

Events for full off-chain indexing: `MandateRegistered`, `MandateRevoked`, `MandateSpent`.

## Build, test, deploy

Prerequisites: [Foundry](https://book.getfoundry.sh/getting-started/installation), an Arbitrum Sepolia RPC, an Arbiscan API key.

```bash
# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts --no-git
forge install foundry-rs/forge-std --no-git

# Compile
forge build

# Run the test suite (6 tests: happy path + auth + replay + revocation)
forge test -vv

# Configure and deploy
cp .env.example .env
# edit .env with DEPLOYER_PRIVATE_KEY + ARBISCAN_API_KEY

source .env
forge script script/Deploy.s.sol \
  --rpc-url arbitrum_sepolia \
  --broadcast \
  --verify
```

The Foundry script prints the deployed registry address and verifies on Arbiscan in one step.

## Deployed addresses

- **Arbitrum Sepolia**: `TBD` (deploying during buildathon window — address will appear here)
- **Arbitrum One**: `TBD` (mainnet flip once seller is feature-complete)

## What's intentionally out of scope here

- USDC settlement itself — happens via x402 V2's `PAYMENT-REQUIRED` flow in [the seller](https://sms.tollkit.dev). This contract is the *mandate* anchor only; it does not custody funds.
- Multi-recipient batched settlement aggregations — v2 once we have real volume.
- Cross-chain mandate portability — deferred until we see demand.

## Related repos

- **[sms.tollkit.dev seller](https://sms.tollkit.dev)** (private during buildathon) — Hono + x402-hono + Twilio. Migrating to `@x402/hono` V2 and multi-chain (Base + Arbitrum) during the buildathon window.
- **[x402-sms-mcp](https://www.npmjs.com/package/x402-sms-mcp)** — open-source MCP client.

## License

MIT.
