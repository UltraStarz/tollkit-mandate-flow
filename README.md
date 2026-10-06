# tollkit-mandate-flow

[![ci](https://github.com/UltraStarz/tollkit-mandate-flow/actions/workflows/test.yml/badge.svg)](https://github.com/UltraStarz/tollkit-mandate-flow/actions/workflows/test.yml)
[![Sourcify](https://img.shields.io/badge/source-Sourcify%20verified-2eba8b?logo=ethereum)](https://repo.sourcify.dev/contracts/full_match/42161/0x361a19EdeDB00Cd955C81191d3FE447972c72C52/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> AP2 Intent Mandates for the [tollkit.dev](https://tollkit.dev) family of paid developer tools, settled via x402 V2 on Arbitrum.

**Buildathon submission for [Arbitrum Open House London 2026](https://blog.arbitrum.foundation/open-house-london-registration-is-now-open/).**

Live product the deliverables plug into:

- **[tollkit.dev](https://tollkit.dev)** — umbrella brand landing page
- **[sms.tollkit.dev](https://sms.tollkit.dev)** — x402 SMS gateway (Twilio toll-free verification in progress)
- **[npmjs.com/package/x402-sms-mcp](https://www.npmjs.com/package/x402-sms-mcp)** — MCP client for Claude Desktop / Cursor / Windsurf

---

## What's in this repo

The on-chain anchor for the AP2 mandate flow described in our submission, plus a TypeScript library sellers can drop in to consume it:

```
src/
  ConsentMandateRegistry.sol      ← the smart contract
script/
  Deploy.s.sol                    ← Foundry deploy script
test/
  ConsentMandateRegistry.t.sol    ← Foundry test suite (7 tests)
abi/
  ConsentMandateRegistry.abi.json ← published ABI for direct consumption
ts/                               ← @tollkit/mandate TypeScript library
  src/                              types + EIP-712 + verify + recordSpend + ledger
  test/                             vitest suite (16 tests)
docs/
  architecture.png                ← 3-phase visual of the mandate flow
examples/
  sample_mandate.json             ← annotated EIP-712 mandate fixture
scripts/
  verify_sourcify.py              ← re-verify the contract via Sourcify
foundry.toml                      ← Foundry config
.env.example                      ← required env vars for deploy
```

The `ts/` package (`@tollkit/mandate`) is what production sellers — `sms.tollkit.dev`, the upcoming `extract.tollkit.dev`, and any third party building on this contract — use to verify mandate signatures, track off-chain spend, and trigger batched `recordSpend()` calls. See [`ts/README.md`](ts/README.md) for the API surface and a working `/send` integration example.

## The problem we're solving

x402 V2 enables HTTP-native, sub-2-second USDC payments — but per-call settlement still incurs gas (~$0.0005 on Arbitrum). For micropayment APIs (sub-cent SMS, paid AI inference, web scraping), settling every single call on-chain breaks the economics.

[Ben Greenberg's talk at Devworld](https://www.youtube.com/watch?v=YNmcn-mLpv8) put it succinctly: *"An agent paying per API call can't spend dollars on transaction fees for each call."*

## How `ConsentMandateRegistry` solves it

This contract is the on-chain primitive for an **AP2 + x402 hybrid settlement model**:

1. **Recipient signs an Intent Mandate** (EIP-712) authorizing a specific agent to send up to *N* messages to their phone over a time window, paid from a specific buyer wallet.
2. **Agent calls `tollkit-sms /send`** with the mandate ID. Seller verifies the signature, debits an off-chain balance ledger, dispatches the SMS via Twilio.
3. **Every 5 sends**, the seller batches accumulated debits into one on-chain `recordSpend()` call here for the audit trail, and a single x402 V2 `transferWithAuthorization` for the USDC settlement.

**Result:** 50 SMS = 1–2 on-chain transactions. Per-call gas approaches zero. Sub-cent pricing becomes economically viable.

The mandate primitive is **AP2 v0.2 compliant** (donated to FIDO Alliance April 2026) and intentionally chain-agnostic — the same EIP-712 typed-data model is currently deployed on Arbitrum One (mainnet) and is portable to any EVM chain that supports USDC EIP-3009.

## Architecture

![tollkit mandate flow architecture](docs/architecture.png)

Three phases:

1. **Mandate setup** — once per recipient. The phone owner signs an EIP-712 Intent Mandate authorizing a specific agent to send up to *N* messages to their phone over a time window, paid from a specific buyer wallet. The seller calls `registerMandate()` to anchor it on-chain.
2. **Send SMS** — N times, no gas. The agent calls `/send` on the seller with a mandate ID. The seller verifies the signature, debits an off-chain ledger, and dispatches the SMS via Twilio. Zero on-chain cost per send.
3. **Batch settle** — every 5 sends. The seller calls `recordSpend()` for the audit trail and `transferWithAuthorization` (EIP-3009) for the USDC settlement. 50 SMS collapses into 1 on-chain transaction.

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

## Integration

### Sample mandate

A mandate is just typed data signed by the recipient. Example for "agent `0xbeef…` may send up to 50 SMS to a specific phone for up to $1.50 USDC over the next 30 days":

```json
{
  "recipient":        "0xA11CE…",
  "authorizedAgent":  "0xBEEF…",
  "buyerWallet":      "0xB07E1…",
  "phoneHash":        "0x4f5d…",
  "maxMessages":      50,
  "maxUsdc":          1500000,
  "notBefore":        1717891200,
  "expiresAt":        1720483200,
  "nonce":            1
}
```

`phoneHash` is `keccak256` of the normalized E.164 string (`+15551234567`). `maxUsdc` is 6-decimal USDC (so `1500000` = $1.50). `nonce` prevents replay across mandate updates.

A complete annotated sample lives at [`examples/sample_mandate.json`](examples/sample_mandate.json) with EIP-712 domain, signing steps, and per-field notes.

### EIP-712 domain + types

```ts
const domain = {
  name:              'tollkit.ConsentMandateRegistry',
  version:           '1',
  chainId:           42161,
  verifyingContract: '0x361a19EdeDB00Cd955C81191d3FE447972c72C52',
} as const;

const types = {
  Mandate: [
    { name: 'recipient',       type: 'address' },
    { name: 'authorizedAgent', type: 'address' },
    { name: 'buyerWallet',     type: 'address' },
    { name: 'phoneHash',       type: 'bytes32' },
    { name: 'maxMessages',     type: 'uint256' },
    { name: 'maxUsdc',         type: 'uint256' },
    { name: 'notBefore',       type: 'uint64'  },
    { name: 'expiresAt',       type: 'uint64'  },
    { name: 'nonce',           type: 'uint256' },
  ],
} as const;
```

### Recipient signs the mandate (off-chain, via viem)

```ts
import { createWalletClient, http, keccak256, toBytes } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { arbitrum } from 'viem/chains';

const recipient = privateKeyToAccount('0x…recipientKey…');
const client = createWalletClient({
  account: recipient,
  chain:   arbitrum,
  transport: http(),
});

const mandate = {
  recipient:        recipient.address,
  authorizedAgent:  '0xBEEF…',
  buyerWallet:      '0xB07E1…',
  phoneHash:        keccak256(toBytes('+15551234567')),
  maxMessages:      50n,
  maxUsdc:          1500000n,
  notBefore:        BigInt(Math.floor(Date.now() / 1000)),
  expiresAt:        BigInt(Math.floor(Date.now() / 1000) + 30 * 86400),
  nonce:            1n,
};

const signature = await client.signTypedData({
  domain,
  types,
  primaryType: 'Mandate',
  message:     mandate,
});
```

### Seller registers the mandate on-chain

The ABI is published at [`abi/ConsentMandateRegistry.abi.json`](abi/ConsentMandateRegistry.abi.json) for direct consumption.

```ts
import { createPublicClient, createWalletClient, http } from 'viem';
import { arbitrum } from 'viem/chains';
import abi from 'tollkit-mandate-flow/abi/ConsentMandateRegistry.abi.json';

const seller = privateKeyToAccount('0x…sellerKey…');
const wallet = createWalletClient({ account: seller, chain: arbitrum, transport: http() });

const hash = await wallet.writeContract({
  address: '0x361a19EdeDB00Cd955C81191d3FE447972c72C52',
  abi,
  functionName: 'registerMandate',
  args: [mandate, signature],
});

// mandateId is emitted in MandateRegistered event
```

The contract verifies the signature recovers to `mandate.recipient`, checks the nonce hasn't been used, and stores the mandate. Subsequent `/send` calls reference `mandateId` and the seller debits the off-chain ledger. Every 5 sends, the seller calls `recordSpend(mandateId, 5, 150000, 50, 1500000)` to anchor the batch.

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

- **Arbitrum One** (mainnet): [`0x361a19EdeDB00Cd955C81191d3FE447972c72C52`](https://arbiscan.io/address/0x361a19EdeDB00Cd955C81191d3FE447972c72C52)
  - Deploy tx: [`0xabeac42b...10043`](https://arbiscan.io/tx/0xabeac42b664139cf3798b4bc099db93ff7d871db24fbf3285359d23061510043)
  - Block: 471,641,187
  - Seller authorized: `0x60725F59CC7C300cb40360C804D053066966CfcD`
  - Source verified: [**Sourcify (perfect match)**](https://repo.sourcify.dev/contracts/full_match/42161/0x361a19EdeDB00Cd955C81191d3FE447972c72C52/) — bytecode, metadata, and all 13 source files publicly indexed. Arbiscan picks up Sourcify verifications and displays the verified source on the contract page.

## What's intentionally out of scope here

- USDC settlement itself — happens via x402 V2's `PAYMENT-REQUIRED` flow in [the seller](https://sms.tollkit.dev). This contract is the *mandate* anchor only; it does not custody funds.
- Multi-recipient batched settlement aggregations — v2 once we have real volume.
- Cross-chain mandate portability — deferred until we see demand.

## Related repos

- **[sms.tollkit.dev seller](https://sms.tollkit.dev)** (private during buildathon) — Hono + x402-hono + Twilio. Migrating to `@x402/hono` V2 and multi-chain (Base + Arbitrum) during the buildathon window.
- **[x402-sms-mcp](https://www.npmjs.com/package/x402-sms-mcp)** — open-source MCP client.

## License

MIT.
