# BLACKOUT v3.14: accepted low/info findings (paste into every launch objective)

Pre-launch audit a8730286 (Identity-md/research, `files/AUDIT.md`) on commit 24bfb1d. The high (V4Market quote)
and medium (SwarmDesk.bind market/token probe) findings and six low items (executeSells amount, retire caller,
regulator key, vintage timestamp, claimLottery receipt, lock walk bound) are **fixed in v3.14** (see `report.md`).
The remaining low/info items are accepted as documented, one line each:

- **RewardPool shortfall.** `remainderTo` must deliver at least 200,000,000e18 to the escrow; a shortfall is repaired by a plain token transfer to the RewardPool (not `donate`), after which `fundEndowment` is called.
- **Exact-input swaps only.** The launch pool accepts exact-input swaps only; exact-output swaps revert `InvalidValue` for every trader, including the system buy/sell paths.
- **spot() bounds.** `spot()` refuses prices outside (1e-18, 1e22] tokens/ETH; unreachable for a 1e9-supply pool with full-range liquidity and the 1.25% LP fee.
- **Fixed oracle signer and endpoints.** The attester, Intake and IntakeDelivery are bytecode constants with no rotation path; if the IMD attester key or Intake moves, the Desk stops acting and the game runs on its fallback event table and current Params (a deliberate ownerless design).
- **Answers between job A and job B.** Attested answers accepted between job A (L3) and job B (L4) are consumed but not executable (`NotConfigured` on roles 7/10/11/12); job B is launched in the same session and no funds are at stake.
- **Future-block randomness.** Pack, starter and season entropy come from a future block hash and are sequencer-influenced; no VRF claim is made, and expired windows re-arm instead of minting fallbacks.
- **Reserved Params keys.** 17 reserved Params keys have no reader (docs/params-keys-v313.md); the regulator skips any key outside 1..45 (v3.14) and the attester recipe emits only known keys.
- **M-2 twin.** A pinned-code twin registry can still win the `SwarmDesk.bind` race, but after fix 2 it must name the Desk's own launch hook and token, so the capture is griefing only (the honest job A/B contracts are orphaned, no fee stream or endowment can be frozen or taken); mitigated by binding right after job A (docs/m2-trust-assumption.md).
- **executeSells quoting.** The keeper sells the best batch available at inclusion time; `minOut` is still checked against the live `quoteSell`, and a stale `minOut` reverts harmlessly for a retry.
