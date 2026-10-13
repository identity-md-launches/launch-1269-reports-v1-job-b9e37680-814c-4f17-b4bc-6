# BLACKOUT v3.9 / v3.10 / v3.11 / v3.12 report

Source only. No deployment, broadcast, oracle purchase, schedule, token action or mint. v3.10 finishes v3.9
(job 14aa1d96). **No contract source changed in v3.10**: every module, Registry, Params, SwarmDesk,
EndowmentEscrow and hook build is byte-identical to the v3.9 pins. The v3.8 report is archived at
[docs/report-v38.md](docs/report-v38.md); earlier ones are in `docs/`.
X: https://x.com/IMDBlackout · https://playblackout.xyz · https://playblackout.xyz/freepack

## Changes

### v3.9 (job 14aa1d96, contracts)
- **Fees.** The hook has no network share. After the 30-minute stepped launch tax (90/50/25%, all to rewards)
  it adds exactly 1% to rewards on every swap, plus the progressive sell surcharge (cap 15%). `FeeRouter._base`
  sends 100% to reward ETH. The team's swap income is the platform 1% via `LaunchFactory.claimFees`. Pool fee
  12500.
- **Toolchain pins.** `ModuleCode`/`SwarmCode` pin both the IMD verifier build (viaIR false, bytecode_hash
  none) and the repository's via-IR build. Every runtime is under 24,576 bytes on both (FarmCore 21,987 /
  24,330). The SwarmDesk constructor is twelve words.
- **Severity floor 3000** in GridOperator; the Desk band is 5000–7000.
- **Keeper:** attestation relay, `wire` command (bind-desk with `Desk.registry()` check, register,
  bind-router, forward, fund, claim-fees). UI wiring status. Simulation `sim/run_v39.py`.

### v3.10 (this job, tests, tools, docs)
- **Launch toolchain tests.** The suite now compiles and passes with `FOUNDRY_VIA_IR=false
  FOUNDRY_BYTECODE_HASH=none`. Four stack-too-deep sites were refactored in tests only:
  `EndowmentEscrowV38.t.sol`, `LazyAccounting.t.sol` and two in `SwarmDeskV37.t.sol`.
- **Review fix M-1.** `tools/schedule_bodies.mjs` and `make_oracle_bodies.mjs` now generate `schedule.create`
  bodies with `consumer {4663, Desk}` and no `deliver`. `test/oracle-v310.test.mjs` covers it.
- **Regression tests.** `test/V310.t.sol` checks that the build's own 14 modules plus Registry and Params match
  one toolchain's pins together. `testTwinWithForeignTokenCannotDrainEscrow` covers the bounded part of M-2.
- **Docs.** [launch-v39.md](launch-v39.md) is the final ordered runbook (fork rehearsal since v3.11, then 4663) with
  objective texts, inputs and on-chain checks per step. [docs/review-v39-independent.md](docs/review-v39-independent.md)
  is the review.

## Tests on both toolchains

| Check | IMD verifier toolchain (`FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none`) | Repository toolchain (`foundry.toml`, via-IR) |
|---|---|---|
| `forge build` | Passes (v3.9: failed, stack too deep) | Passes (~10 min compile) |
| `forge test` | **262 passed, 0 failed, 1 skipped** (optional live-RPC fork), 45 suites | Full suite 259/0/1 before the v3.10 additions. The four changed or new suites were re-run afterwards: 36/36 passed. Total 262 passed, 0 failed, 1 skipped |
| `forge fmt --check` | Passes | same |
| Pins (`tools/pin_module_code.py --check`, `tools/pin_swarm_code.py --check`) | All 14 modules plus Registry/Params match; every runtime ≤ 24,576 | same |
| Flattened `launch/V4Market.sol` | Byte-identical to `src/V4Market.sol` and embeds `REGISTRY_LAUNCH` | n/a |
| Node: `oracle-v37`, `keeper-v39`, `oracle-v310` | Pass | — |
| v3.11 fork rehearsal `test/fork/RehearsalV311.t.sol` (needs a 4663 fork; skips offline) | 5 passed on the anvil fork (`artifacts/v311/rehearsal.log`) | compiles; skips offline |

Logs are in `artifacts/v310/`. The repository toolchain's full run was not repeated after the last test edits
because of its ten-minute compile; the edited suites were re-run on it.

## Simulation (Balanced, 35 days, five seeds, medians; from `artifacts/v39/simulation.md`)

| Scenario | v3.6 team ETH | v3.9 team ETH (swarm sells 50% day 1) | v3.6 drawdown | v3.9 drawdown | v3.6 week-1 payback | v3.9 week-1 payback |
|---|---:|---:|---:|---:|---:|---:|
| steady | 3.579 | 3.586 | 1.8% | 7.5% | 3.75 d | 3.75 d |
| weak | 0.917 | 0.914 | 0.7% | 11.2% | 4.25 d | 4.25 d |
| hype | 4.996 | 5.008 | 1.9% | 2.2% | 3.50 d | 3.25 d |

v3.6 used 11.1 ETH FDV and no swarm sales; v3.9 uses 10 ETH FDV and the swarm's 10% claimable after one hour.
The fee rework does not move team income: the team gets 1% of volume plus 10% of packs and of the surcharge
in both. The swarm sales set the larger drawdown in the first day. These are conditional model outputs, not
predictions. v3.10 did not re-run the simulation because no economics changed.

## Review result

The second-contributor review of v3.8 → v3.9 is in [docs/review-v39-independent.md](docs/review-v39-independent.md):
- **T-1** (launch blocker): tests did not compile on the verifier toolchain. Fixed.
- **M-1**: schedule bodies with `deliver`. Fixed, with a regression test.
- **M-2**: twin front-run of `Desk.bind`. Open by design, mitigated operationally (see below).
- **L-1**: mixed-toolchain artifacts would strand hook fees. Documented, with a pin-consistency test.

Fees, severity floor, escrow refactor, Desk constructor packing and keeper relay/wiring had no findings.

## v3.11 fork rehearsal (job 2f166600)

Source only; nothing deployed or broadcast; no contract logic changed (the rehearsal found no bug in the
contracts). `tools/rehearse_v311.sh <4663 rpc>` starts a local anvil fork of Robinhood Chain, builds with the IMD
launch toolchain (`FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none`) and runs `test/fork/RehearsalV311.t.sol`,
which executes runbook steps M1–M13 in order through the **real** ProjectFactory, its registry, LaunchFactory,
PoolManager, Intake and IntakeDelivery addresses, impersonating the platform deployer `0xcECc…a551` where the
platform deploys or initializes. Throw-away roots, a test attester key and launch numbers 777001–777005 (asserted
unrecorded) were used; the test skips on any chain other than 4663, so the offline suite is unchanged. The log
with every address, call and check is `artifacts/v311/rehearsal.log` (5 passed, 0 failed, fork block 86865884,
2026-10-12). The factory ABIs were recovered from the runtime selectors and the calldata of recorded launches
1015, 1271, 1300 and 1316; the factory sources remain unverified.

| Check (brief §2) | Result on the fork |
|---|---|
| `Desk.registry()` = job A registry after `bind`; wrong coordinates and a non-registry refused; second bind refused | passed |
| `register` 0–13: factory CREATE2 addresses equal `predictContract`; duplicate role refused | passed, 14 registered |
| `bindFeeRouter`: non-router refused; `fees()`/`params()` set; `flushFees` no longer `NotConfigured` | passed |
| `escrow.forward`: wrong pool index refused; full balance (200,560,364e18) to the authenticated RewardPool; second call refused | passed |
| `fundEndowment` starts the drip (42 days); second call refused | passed |
| First pack only after launch + 1h (`TooEarly` before); entropy captured via the ArbSys clock | passed |
| Buys at +5/+15/+25 min pay 90/50/25% to rewards; +31 min exactly 1%; net sell carries the surcharge (cap 15%); `flushFees` lands in the FeeRouter | passed |
| Attested answer relayed by an arbitrary wallet via `SwarmDesk.submit`; forged signature refused; replay ignored; plan severity clamped to 7000 (band 5000–7000) for epochs e+1, e+2 | passed |
| Keeper `advanceEpoch` at `epochEnd` resolves the event with revealed entropy (seed ≠ 0), epoch 2 starts | passed |
| `LaunchFactory.claimFees(N_T)` pays the paying wallet: 0.0198 ETH after a 2 ETH buy (≈ 1%) | passed |

The four items v3.10 marked unproven:

| Item | Fork result |
|---|---|
| Attested creation-code hashes vs the real factory | Every deployed contract's initcode prefix hashes to the launch pins (`SwarmCode.*_LAUNCH`, `ModuleCode.launchHash(0..13)`), and the factory's CREATE2 addresses match `predictContract`, so the Desk, hook, Registry and escrow proofs all pass against the real factory. |
| `afterInitialize` sender | **LaunchFactory `0xa25b…4645`** (trace: `PoolManager.initialize` inside the LaunchFactory's launch tx, hook called with that sender). `initializedAt` set. |
| Gas per launch vs the 0.01 ETH ceiling | Desk 5,415,993; Escrow 1,743,701; token + hook 7,220,053; job A 21,411,808; job B 19,523,888 gas. At the fork basefee (0.0206 gwei) the dearest launch costs about 0.00045 ETH; it fits under the ceiling up to ≈ 0.47 gwei. |
| Constructor encoding through the real launcher | Twelve-word Desk, three-word escrow, eight-word hook (`$poolManager`, `$token`, `$factory`), job A/B words: all decoded as intended. |

Where reality differed (folded into `launch-v39.md`, no code change): the LaunchFactory's launch tuple names the
pair currency explicitly and every recorded 4663 hook launch so far was IMD-paired, so BLACKOUT's ETH pairing
must carry the zero address there (with IMD the hook's key check reverts the launch, as first observed on the
fork); `remainderTo` receives the 20% plus whatever pool dust the position did not seed (≥ 200,000,000e18, as
the runbook's checks already allow); and the keeper's first `advanceEpoch` must land before packs open at +1h.

The Sepolia rehearsal of v3.10 is replaced by this fork rehearsal: the same checks ran against the real 4663
platform contracts and bytecode, without spending IMD on Sepolia launches. What a fork cannot prove: the plane's
admission (audit panel, manifest, stand-in checks), the plane's own liquidity/price figures for the ETH pair,
live oracle schedules and the real attester, and the gas price on launch day.

## v3.12 launch-ready source (job c36ea654)

Source only. No deployment, broadcast, token action or oracle purchase. No contract changed.

**1. foundry.toml: not changed (blocked).** The brief asked for via_ir false and bytecode_hash "none" in the
root profile. This job type protects `foundry.toml`, and the previous attempt was rejected
(`path_violation: foundry.toml`), so the file is unchanged: `via_ir = true` and no `bytecode_hash`. The IMD
imported-launch check will keep blocking on bytecode_hash until the requester gets the change made in a job
where `foundry.toml` is writable, or by the platform. The edit needed is exactly two lines in
`[profile.default]`: `via_ir = false` and `bytecode_hash = "none"`. The rest of the profile (solc 0.8.26,
cancun, optimizer true, 200 runs) already matches. Until then the launch build uses the documented overrides
(`FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none`, `out-launch/`), which produce the bytecode below.

**2. Pins unchanged.** Creation-code hashes of the launch build (`artifacts/v312/launch-creation-hashes.txt`),
all equal to research 4e478378 §3:

| Contract | Creation hash (launch toolchain) |
|---|---|
| GameRegistry (`SwarmCode.REGISTRY_LAUNCH`) | `0xee08039e9860c09d55aefe5cd2d9ffd5993f3fe60a1d606549902f56188418cb` |
| Params (`SwarmCode.PARAMS_LAUNCH`) | `0x26c9f36af040b02eba9644f52daeed84fae4e42eab9bdb23277d0bb28c6dc6c0` |
| SwarmDesk | `0x9e0cf571a687b4e79948f2af5fd2095058226c11bd002342955d6022ddeda214` |
| EndowmentEscrow | `0xeeb7a2c17455a83fd04d6ab155c2c580720bd0d3c02d95a6bc0e9cd213491610` |
| V4Market | `0x758e2ab5a6db72b6c5192702ecb0fcb291101c599f91e1bbee1cc36091e3a974` |
| `ModuleCode.launchHash(0..13)` | unchanged; `tools/pin_module_code.py --check` passes on both builds |

The via-IR repo pins (`REGISTRY_REPO`, `PARAMS_REPO`, `ModuleCode.repoHash`) **stay**. Removing them would
change contract bytecode: `SwarmCode.isRegistry/isParams` are inlined into SwarmDesk and EndowmentEscrow, and
`ModuleCode.matches/repoHash` into GameRegistry and EndowmentEscrow. Dropping them would move the SwarmDesk,
EndowmentEscrow and GameRegistry launch pins, and through `REGISTRY_LAUNCH` the V4Market pin. The repository's
own via-IR build also still needs them, because `foundry.toml` is via-IR.

**3. Checks** (logs in `artifacts/v312/`):

| Check | Result |
|---|---|
| `forge build` (plain `foundry.toml`, via-IR, no env) | passes (16 min compile) |
| `forge test` (plain `foundry.toml`, no env) | 265 passed, 0 failed, 6 skipped (same skips), 47 suites, including the new `TwinCaptureV312` |
| `forge test` (launch toolchain overrides) | 265 passed, 0 failed, 6 skipped (the 5 fork-rehearsal tests and the optional live-RPC test skip offline), 47 suites |
| Fork rehearsal `tools/rehearse_v311.sh https://robinhood.drpc.org` (anvil fork of 4663, block 87346575) | 5 passed, 0 failed (`artifacts/v312/rehearsal.log`); M1–M13 against the real ProjectFactory, registry, LaunchFactory, PoolManager |
| `forge fmt --check` | passes |
| `pin_module_code.py --check`, `pin_swarm_code.py --check` | pass, both toolchains |
| Node (`keeper-v39`, `oracle-v310`, `oracle-v37`, `reveal`, `ui-v35`) | all pass |
| Python `unittest` (`test/python`) | 34 passed |

New test (test only): `test/TwinCaptureV312.t.sol`, three tests behind the M-2 document (honest path, twin
orphans the honest game, twin cannot pay the attacker).

**4. IMD public check (`/requests/check`) for M1, M2, M3, M4, M7: not run.** The check runs against the new
commit, and that commit exists only after this job is delivered. This worker cannot push, and the steps
(audit-imported-code, adapt-contract-project, adversarial-review) would see the unchanged `foundry.toml`. The
expected result is the known bytecode_hash blocker, which item 1 could not clear. Run it once the delivered
commit is public and the profile change has landed, and record `blockers` per launch.

**5. M-2.** [docs/m2-trust-assumption.md](docs/m2-trust-assumption.md) is written for the audit judge. A twin
capture cannot pay the attacker: the escrow forwards only to a pinned RewardPool, and that pool pays only by
the mining rules. It is griefing (the honest modules are orphaned), rated low as a platform trust assumption,
and mitigated by binding right after job A and checking `Desk.registry()` before `forward`. One correction to
the brief: capturing the Desk and the forward needs a paid factory launch of at least Params, GameRegistry and
RewardPool. A twin that should also run as a game needs the full 8-contract job A shape.

**6. Runbook.** `launch-v39.md` has the research corrections: named `$contract:Params` /
`$contract:GameRegistry` references, the ProjectFactory registry `0xf52b…8406` for proofs, the M3 request
fields (no owner, no `initialMarketCapWei`), objective texts for M1, M2, M4 and M7 with one common paragraph,
the M-2 pointer in M1 and M4, and timing (1-contract median about 63 min; 8-contract unknown, budget 2 h; about
7–9 h from M1 to M10).

**Open items (v3.12):**
1. `foundry.toml`: apply `via_ir = false` and `bytecode_hash = "none"` in a job where the file may be edited.
   The launch pins above stay valid (they are the override build). After the change, the via-IR repo pins can
   only be dropped together with a re-pin (see 2).
2. Run the IMD public check for M1, M2, M3, M4 and M7 against the delivered commit and record the blockers.
3. Research 4e478378 was not in this workspace. Compare the objective texts in `launch-v39.md` with its
   recommended texts before pasting.
4. Still open from v3.11: the requester inputs (snapshot, roots, keeper wallet, Ethereum IMD), the plane's
   admission on the live path, and launch-day gas.

## Still open

1. **M-2 twin front-run** (trust assumption, [docs/m2-trust-assumption.md](docs/m2-trust-assumption.md)). It cannot be closed without an on-chain fact only the honest launch has. Mitigation:
   keep `starterRoot`, `freeRoot`, the snapshot block and the lists private until `Desk.registry()` equals the
   job A registry; bind immediately after job A; never forward otherwise. If the requester wants a code fix,
   they must decide the anchor (for example a factory record of the payer). That changes the Desk pin.
2. **Requester inputs:** snapshot block, the two Merkle roots, the keeper wallet and its RPC, the Ethereum IMD
   for the schedules, and the Sepolia platform addresses (read and verified at rehearsal time).
3. **Fork rehearsal done, live platform path not.** The fork proved the creation-code pins, the `afterInitialize`
   sender, gas per launch, the relay and `claimFees` against the real 4663 contracts (above). Still unproven: the
   plane's admission and manifest checks, its liquidity/price figures for the ETH pair, the live attester and
   schedules, and launch-day gas.
4. Slither/Mythril and live oracle schedules were not run. This is not an external audit.

## Responsibilities

The requester pays and approves each launch job and the schedules, and supplies the inputs above. Anyone may send
the permissionless wiring calls; the keeper wallet only pays gas and holds no game power. SwarmDesk acts only on
attested oracle answers within hard-coded bounds. Nothing is upgradeable or owned.

## v3.14 (job dd9bbfea): launch-ready source, audit a8730286 fixes, deploy gate

Source only; nothing deployed. Inputs: pre-launch audit a8730286 (`files/AUDIT.md`, Identity-md/research) and the
deploy-gate refusal of launch 1557. The repo `foundry.toml` is protected in this job and still says `via_ir = true`
with no `bytecode_hash`; the launch pins below are the documented override build (viaIR false, bytecode_hash none,
`out-launch/`) and the repo pins the via-IR build, exactly as in v3.9–v3.12 (`tools/pin_module_code.py`).

**A. Audit fixes (all eight).** 1 (H) `V4Market.quote`/`quoteSell` net the pool's 1.25% LP fee; 2 (M)
`SwarmDesk.bind` probes `registry.market()` (`desk()`, `token()`, `gameConfigHash()`), an EOA market reverts;
3 `FeeRouter.executeSells` sells `min(total, maxSellBatch())`, reverts only on zero, `minOut` still against
`quoteSell(amount)`; 4 `FarmCore.retire` is owner-only (`Unauthorized`); 5 `_regulate` skips keys 0 and > 45;
6 `FarmRewards._credit` keeps the earlier vintage timestamp; 7 `Season.claimLottery` commits a `PackSale.rewardPack`
receipt like `claimDistrict`; 8 `Economy._insert` walks at most 32 nodes (`MAX_INSERT_STEPS`, the sorted prefix
`districtStake` reads stays exact). `docs/m2-trust-assumption.md` row "Change the token or the pool" corrected.

**B. Deploy gate.** `src/lib/IMD.sol` holds every IMD protocol address as a constant (ProjectFactory, its registry,
Intake, IntakeDelivery, attester, Robinhood IMD, LaunchFactory, PoolManager). SwarmDesk takes seven words
(action, policy word, two question hashes, two body hashes, gameConfigHash); EndowmentEscrow takes only the Desk;
GameRegistry drops the factory word; V4Market drops the ProjectFactory word (`$poolManager`, `$factory` placeholders
stay). `tools/check_deploy_gate.mjs` checks every launch's constructor words against the eight addresses and the
runbook table: passes (19 contracts, 4 launches).

**C/F. Four launches.** `launch-v39.md` §5: L1 SwarmDesk + EndowmentEscrow (`$contract:SwarmDesk`), L2 token +
hook (univ4_hook, pairWith eth, poolBps 7000, remainderTo the L1 escrow), L3 job A, L4 job B, each with the exact
constructor words, expected creation hashes, NO SOURCE CHANGES and the accepted list (`docs/accepted-v314.md`).

**D. Pins (launch build, repo foundry.toml compiler pins).** GAME_CONFIG_HASH unchanged.

| Contract | Creation hash (launch build) |
|---|---|
| SwarmDesk | `0x1529298271e9c3d2700de32d1be2a64f712b07213a32eb8fdb0c4e37c0d06899` |
| EndowmentEscrow | `0xca3226021c259bf399599eb8dc489fe401bf2b71570808ec33deea1c85ff5d35` |
| V4Market | `0x265a61697cdce9ce2888a1572d74df75a8c9efc2c0f7059f82054a4a8c2811b1` |
| GameRegistry (`SwarmCode.REGISTRY_LAUNCH`) | `0xc3f63ca18e4734d9e56e6fa38b8015c1a1cdc41caec1fafa2eb1466c380ea42b` |
| Params (`SwarmCode.PARAMS_LAUNCH`, unchanged) | `0x26c9f36af040b02eba9644f52daeed84fae4e42eab9bdb23277d0bb28c6dc6c0` |
| `ModuleCode.launchHash(0..13)` | regenerated; FarmRewards, FarmCore, FeeRouter, Season, Economy changed, the other nine unchanged (`src/lib/ModuleCode.sol`) |

**Results.** Launch toolchain `forge build` and `forge test`: 272 passed, 0 failed, 6 skipped (fork/live tests
skip offline), 49 suites, including the new `test/V314.t.sol` (quote clears the 1.5% band on a 10 ETH full-range
pool at spot == TWAP, buy and sell; the v3.13 quote still fails; bind rejects an EOA market, a foreign hook, a
foreign configuration and a foreign token; the honest registry binds and every constant is in place).
`forge fmt`, `pin_module_code.py --check`, `pin_swarm_code.py --check`, `check_deploy_gate.mjs`, Node and Python
tests: see the final message of this job. **Not run in this job (time):** the full `forge test` under the via-IR
repo profile (its test compile alone took 16 minutes in v3.12; the via-IR `src` build and both repo pins were
produced and checked) and the fork rehearsal `tools/rehearse_v311.sh` (`test/fork/RehearsalV311.t.sol` is
updated to the new constructors and the constant attester with an ERC-1271 stand-in on the fork). Run both before
the launches. One audit regression (keeper sale after a depth nudge on a real pool) was not finished as a test.

**Test fixtures.** The local `LocalApplicationFactory` is etched at the constant ProjectFactory address with a
records stand-in at the launch-registry address, and an ERC-1271 `MockAttester` is etched at the constant attester
so tests keep signing with the test key (`script/Deploy.s.sol`, `test/mocks/MockAttester.sol`). The oracle
conformance test still reproduces the protocol digest and accepts the vector's signature through that stand-in.
