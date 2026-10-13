# M-2 twin front-run of `SwarmDesk.bind`: trust assumption (for the audit judge)

BLACKOUT v3.12. Source only, no code change. This document covers finding M-2 of the v3.10 independent review
([docs/review-v39-independent.md](review-v39-independent.md)). It says what an attacker who wins the
`SwarmDesk.bind` race can do and what they cannot, rates the severity, and gives the operational mitigation the
runbook ([launch-v39.md](../launch-v39.md), M4–M5 and M9) applies. Every claim below cites the code or a test.
The tests run offline (`test/TwinCaptureV312.t.sol`, `test/EndowmentEscrowV38.t.sol`); the rehearsal on a
fork of 4663 (`test/fork/RehearsalV311.t.sol`) ran the honest order against the real factory.

## 1. The race

`SwarmDesk.bind` (`src/SwarmDesk.sol`) is permissionless and runs once. It accepts the first candidate
registry that meets all of these:

- `keccak256(registryCode)` and `keccak256(paramsCode)` equal a pinned GameRegistry / Params creation hash
  (`SwarmCode.isRegistry`, `SwarmCode.isParams`);
- `registry.factory()` is the ProjectFactory `0x9c9d…265e` fixed at Desk construction;
- `keccak256(abi.encode(starterRoot, freeRoot, snapshotBlock, endowment))` equals the Desk's `gameConfigHash`;
- the Params is the factory's CREATE2 result for the pinned Params code with constructor `(Desk, 200, 1e18)` at
  the given launch coordinates, it has code, and `swarmWallet()` is the Desk;
- the registry is the factory's CREATE2 result for the pinned registry code and its constructor tuple at the
  given coordinates, and it has code.

IMD launch numbers cannot be reserved, so nothing on chain separates the honest job A from a byte-identical
"twin" job launched through the same factory. Whoever calls `bind` first with a valid registry wins.

## 2. What the attacker needs

1. **The private game configuration**: `starterRoot`, `freeRoot`, `snapshotBlock` and `endowment`. Only their
   hash is on chain (in the Desk and the hook) until job A reveals them. A twin with any other value fails the
   `gameConfigHash` check (`testEmptyChainConstructorAndAuthenticatedBindingRejectSpoofs`).
2. **The real token and hook**. Both are public after the token launch (M3). With any other token, the escrow
   has nothing to forward to the twin (`testTwinWithForeignTokenCannotDrainEscrow`).
3. **A paid IMD launch through the ProjectFactory.** Only the platform deployer `0xcECc…a551` can launch
   through the factory, so a twin has to be a launch job admitted and paid like the requester's own. The bind
   needs Params and GameRegistry. The forward also needs a registered RewardPool. A twin that should run as a
   game, rather than just block the honest one, needs the whole job A shape: an **8-contract launch**
   (Params, GameRegistry, RewardPool, FarmRewards, FarmCore, FarmItems, PackSale, StarterClaim), which the fork
   measured at 21.4M gas. A launch of just the three contracts is enough to capture the Desk and the
   escrow forward, but it leaves the endowment unpayable until someone registers a FarmRewards (see §3). In
   both cases the attacker pays a full launch job and passes its admission.
4. **To land before the honest `bind`**, in the window between job A executing (the roots become public in its
   objective and on chain) and the keeper's `bind-desk` transaction.

## 3. What a twin capture can and cannot do

| Effect | Can the attacker do it? | Why (code / test) |
|---|---|---|
| Bind the Desk to the twin registry | **Yes**, if they win the race | `bind` accepts the first valid candidate (`testTwinCaptureOrphansHonestGame`) |
| Bind the honest registry afterwards | No, for anyone | `bind` reverts `AlreadyDone` (same test) |
| Make the escrow pay an attacker wallet | **No** | `EndowmentEscrow.forward` sends only to `registry.module(0)`. That address must be the factory's CREATE2 result of the pinned RewardPool code with the bound registry as its argument, and it must have code. Other code or other coordinates revert `InvalidProof` (`testTwinCaptureCannotPayAttacker`) |
| Make the escrow pay the twin's pinned RewardPool | Yes: this is the capture's only value movement | Same test: the whole 200M lands in the twin pool, once (`AlreadyDone` after that) |
| Withdraw tokens from the twin RewardPool | **No** | `pay`, `reserve` and `recycle` are `onlyRewards` (the registry's pinned FarmRewards, role 1). The attacker gets `Unauthorized`, and before a FarmRewards is registered nothing can pay at all. There is no owner, withdrawal or sweep (`testTwinCaptureCannotPayAttacker`) |
| Change emission, prices or pauses | **No** | The twin's Params must name the same Desk as `swarmWallet` (checked in `bind`). The Desk acts only on attested oracle answers, inside hard-coded bounds |
| Take hook ETH fees | **No** | `V4Market.bindFeeRouter` accepts only the bound registry's pinned FeeRouter (role 6). `FeeRouter` routes ETH into game rewards (pull payments to players). The team's 1% comes from `LaunchFactory.claimFees`, which goes to the paying wallet whichever registry is bound |
| Change the token or the pool | **No** (enforced since v3.14) | `SwarmDesk.bind` probes `registry.market()` as a launch hook: `desk()` must be this Desk, `token()` the registry's token and `gameConfigHash()` the committed configuration (audit a8730286 M). A twin naming a foreign market or token reverts `InvalidProof` (`test/V314.t.sol`), so the hook's fee stream and the escrow can never be frozen by a capture |
| Leave the honest job A/B contracts orphaned | **Yes** | The honest registry is never bound, so its pool never receives the endowment (`fundEndowment` reverts `InsufficientBalance`) and the hook never binds its FeeRouter |

Net: **no tokens or ETH ever become withdrawable by the attacker.** The endowment still sits in a RewardPool
running the pinned code, which emits it only to players by the normal mining rules, over the same 42-day drip.
That game uses the same token, the same roots (the same starter and free-pack claims) and the same Desk. The
attacker is a player like anyone else. The one advantage is knowing the twin's addresses first, so they can
start playing before the community points the UI at the twin. The damage is **griefing**: the requester's paid
job A/B launches are wasted, the published wiring has to move to the twin registry, and the timeline slips.

## 4. Severity

**Low. This is a platform trust assumption, not a fund-loss bug.**

- Impact: no theft and no attacker-controlled exit. Funds stay under the pinned game rules. The honest launches
  are orphaned, which costs launch fees and time.
- Likelihood: the attacker needs a configuration that stays private until job A, has to pay and pass a full
  platform launch, and has to land inside a window of a few blocks that the keeper closes right after job A. The
  only party that sees the roots before job A executes is the platform that runs it (the residual noted in the
  review). Trusting the platform not to front-run its own customer is the same trust the launch already puts in
  it for deploying the exact bytecode.
- No code fix: closing the race needs an on-chain fact only the honest launch has, such as a reserved launch
  number (removed by the v3.8 brief) or a factory record of the payer (not in the factory's interface). Either
  one would change the Desk pin and is the requester's decision.

## 5. Operational mitigation (in the runbook)

1. **Keep the roots private until the bind.** `starterRoot`, `freeRoot`, `snapshotBlock` and the eligibility
   lists stay unpublished until `Desk.registry()` equals the job A registry (launch-v39.md §0).
2. **The keeper binds right after job A.** M5 is `node keeper/keeper.mjs wire --step bind-desk` the moment
   job A's addresses are recorded. It reads `Desk.registry()` before and after the bind and throws `STOP`
   if the bound registry is not the job A registry (`keeper/keeper.mjs`, wire step 1).
3. **Check `Desk.registry()` before every forward.** M9 repeats the check. `EndowmentEscrow.forward` is never
   sent unless `Desk.registry()` is `<REGISTRY>`. If it is anything else: stop, publish nothing, escalate to
   the requester. The twin then holds the endowment under the game rules, and recovery is a new Desk/escrow
   pair and a new token launch, which is the requester's decision.

## 6. Evidence

| Test | Shows |
|---|---|
| `TwinCaptureV312Test.testHonestBindThenForwardReachesHonestPool` | Without a twin: bind, forward to the honest pinned pool, drip starts |
| `TwinCaptureV312Test.testTwinCaptureOrphansHonestGame` | Twin binds first; the honest bind reverts `AlreadyDone`; forward to the honest registry reverts `InvalidProof`; the honest pool cannot fund |
| `TwinCaptureV312Test.testTwinCaptureCannotPayAttacker` | Forward to attacker-chosen code or coordinates reverts; the only exit is the twin's pinned pool; `pay`/`reserve`/`recycle` from the attacker revert `Unauthorized`; the attacker's token and ETH balances are unchanged; the twin's Params answer to the same Desk |
| `EndowmentEscrowV38Test.testTwinWithForeignTokenCannotDrainEscrow` | A twin with another token gets nothing |
| `RehearsalV311` (fork of 4663) | The honest order M1–M13 against the real ProjectFactory, its registry and LaunchFactory |
