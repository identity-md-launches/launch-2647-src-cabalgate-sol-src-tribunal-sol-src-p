# Paid-fee mainnet custody tests

These additions run in the default profile. They extend the accepted manifest, audit-regression,
and full-profile suites without changing application code, bytecode commitments, configuration,
or dependencies. Contracts are loaded from build artifacts, avoiding a second embedded copy of
their creation code in each suite.

`PaidFeeAtomicity.t.sol` uses the real application contracts and the repository's Uniswap v4
PoolManager. The local external dependencies are the existing IMD, Intake v2 (200,000 gas
callback), sIMD, Stacker, and seat mocks. It uses chain id 1, the shared IMD fee/pool asset,
400,000 credit gas, 15-day seasons, 33-hour dead-man, committed Tribunal and Letterbox, and the
unchanged 20,000 IMD market-cap code. The existing manifest suites independently check the exact
mainnet addresses, START, constructor order, atomic factory call, code hashes and gas ceiling.

## Discovery and selected properties

The five supplied invariant-discovery perspectives were applied locally, without helpers:

| Perspective | Property chosen | Source basis |
|---|---|---|
| Conservation | Every writer's initial/bought/claimed/prize PLEA equals their wallet, fee sales, sold escrows and outstanding escrows; stake and tip custody includes donations separately | `PLEA.init`, `PleaDistributor.claim`, `Letterbox._open/_close`, `Tribunal.object/settle`, `Seasons._payBonus` |
| State transitions | An escrow ends once; a stake is paid once; inventory cap cannot rise; Cabal death cannot reverse | `Letterbox._deliver/_settle`, `Tribunal.settle`, `PleaHook._applyCap`, `CabalGate.cabalAlive/onOracleResult` |
| Round trips and rounding | Failed nested operations leave balances, pool state, allowances, request counters and escrow unchanged; a refund returns precisely the principal and tip | `Letterbox._plead/_appeal/_deliver/_settle`, `CabalGate.submitFor/executeSellFor` |
| Adversarial value extraction | A relayer cannot redirect a claim, tip or stake; direct donations do not enlarge anyone's entitlement; stalled oracle requests cannot lock custody forever | `PleaDistributor.claim`, `Tribunal.expire/settle`, `Letterbox.settle` |
| Protocol-specific | Supply plus hook and bonus burns stays 1 billion; cashback is accounted as sIMD, plain IMD or v4 claims; objections change points independently of sale authorization | `PLEA.init`, `PleaHook._burnPlea/_payCashback`, `Seasons.flushToWall`, `OBJECTIONS.md` |

These are accounting identities or documented guarantees. Known design choices in
`audit/FINDINGS.md` and the threat model are retained, including the deployment-block registration
fallback, keeper-selected record time, received-PLEA scoring, deferred v4 claims and donated funds.

## Deterministic and fuzz coverage

- Intake rejection after the PLEA fee swap: the pool price, burns, fees and letter all roll back.
- Invalid appeal after attempting to refund an old escrow: the old escrow and appeal eligibility
  remain intact, and a valid appeal still succeeds.
- Lost failure callback followed by an invalid replacement letter: the stale original is not
  partially refunded; a valid retry expires it and leaves exactly one tip/escrow.
- Last runner-tip transfer failure after selling and paying the writer: the entire sale rolls
  back, including nested fees; retry sells once despite pending objections.
- Tip failure after a denied letter's PLEA refund: both assets remain claimable together.
- Objection allowance covering only the stake: failure to pay the shared-asset oracle fee cannot
  leave a half-funded objection, spent id, reduced allowance or locked stake.
- Overruled-stake transfer failure: settlement remains retryable and pays the pot exactly once.
- Two concurrently pending objections, arbitrary scores 0–45, either callback order: the strict
  margin, stake destinations, minimum recorded score and independent sale are checked (128 runs).

The transfer outages are deliberately injected dependency faults, not claims that mainnet IMD
currently pauses or rejects these transfers.

## Stateful campaign

`PaidFeeCustodyInvariant.t.sol` uses four writers and a separate keeper. Its handler randomly
interleaves buys (healthy/reverting Stacker), Merkle claims/replays, letters/site pleas, verdicts,
oracle failures, deliveries/refunds, objections, rulings, expiry/settlement, donations, time and
season closure. Both courts start with live liabilities. Independent ghosts track successful
deposits and payments. Expected application errors are enumerated, assertions are not swallowed,
and `fail-on-revert` is enabled (128 runs, depth 80, inline configuration).

After each generated history, the test advances EVM time beyond the dead-man and expiry windows,
refunds all remaining escrows, settles every stake, closes the final season and burns unused
bonuses. Only unsolicited donations may remain in the courts. A deterministic witness exercises
sales even after sustained objections, denied-letter refunds, overruled/sustained/void stake
settlements, both cashback routes, bitmap word-boundary claims, replay and final closure.

## Reproduction

```sh
forge build
FOUNDRY_FUZZ_SEED=0x53811c629d9d2cffb354db49454a04ae5cf07e0d32343f242370e49e78d51169 forge test
```

No RPC or new dependency is needed. These are offline tests; they do not verify current mainnet
external implementations or live oracle operations. The repository's separately configured
mainnet and Sepolia fork rehearsals remain necessary for that validation. Broader ranking,
Unicode, router, checkpoint, fact-table and historical audit regressions remain in `test/full/`.
