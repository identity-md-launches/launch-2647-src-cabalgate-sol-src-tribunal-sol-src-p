# PLEA Ethereum mainnet adaptation

The imported contracts already implement the requested launch. Review and reproduction of the three supplied import findings found no defect requiring a contract change. All `src/` code, deployment scripts, `launch.json`, build configuration and dependencies are retained unchanged. No deployment or broadcast was performed.

## Changes in this assignment

| File | Change and reason |
|---|---|
| `test/MainnetImportReview.t.sol` | Eight offline regressions reproduce the informational import findings and test their boundaries. They use the existing artifact-based fixture, chain ID 1, IMD for both fees and the pool, objections enabled, 15-day seasons, a 33-hour dead-man, and 400,000 credit gas. The tests join the default build without changing its skip list or dependencies. |
| `ADAPTATION.md` | Replaces the obsolete Sepolia run-5 adaptation report with this mainnet review, finding dispositions and verification results. The project's historical fixes and accepted limitations remain in `audit/FINDINGS.md`. |

## Imported findings

**Coverage (`2e94049ded821ff4d7d93b349a0d2a6a32108f1847a7a44fb213151d9c716b8b`).** Informational, not a defect to fix. Read all nine `src` contracts, both interfaces, the four deployment scripts, the manifest, README, OBJECTIONS, threat model, findings ledger and supplied protected checks and security/address references. Traced ownership, one-time registration and minting, constructor dependencies, external call authorization, oracle consumption, sell accounting, escrow custody, objection settlement, season payouts and hook callbacks. The existing manifest suites reproduce the empty-chain atomic deployment, code commitments and gas checks. The absent `../../floor/OwnerChecks.sol` dependency of the supplied owner-check wrapper is not fabricated; ownership is checked by the project's manifest and ownership suites. Live dependency behavior is not established by the offline mocks; no new live-fork, Slither or Mythril result is claimed.

**First recorder chooses the seat-multiplier moment (`4bef999a2172d8b953fe735a65703e6b21642fd466e39dfe7a7e52649c704792`).** Reproduced: a rival records a seatless seller's approved 45-point plea after 20 minutes; acquiring a seat afterwards changes `pointsFor(seller, 45)` to 54 but leaves `pointsOf(id)` at 45, and another record reverts `AlreadyRecorded`. The recorder's own seat does not count. The reverse also reproduces: a seller's seat held at recording produces 54 permanent points even after it leaves. Recording at the exact 20-minute boundary, or after it while an objection is pending, is refused; once the objection resolves, recording uses the lowest score and the seller's seat at that time. No funds move when points are recorded. This matches README's record-time rule, threat-model invariant 7 and the existing R1-A1-1 disposition. Retained as requested; a seller-only recording window or verdict-time snapshot would change the specified behavior.

**Buys naming court contracts (`609fb315510817a3891491728b94ea25a29dbbebb553324c89fb622f28b13e64`).** Reproduced for the Letterbox, Seasons and distributor. A buy naming the Letterbox delivers PLEA to it without creating an escrow and credits its sIMD, while the paying buyer receives neither. The reproduction first funds the pool through a normal 2 IMD buy so the 100 IMD test buy exercises the Stacker path instead of the unfunded opening-pool exception; both the sIMD balance and the mock Stacker's project attribution are asserted. A separate test with an existing writer proves the donation cannot enlarge or redirect that writer's escrow or tip refund. PLEA bought for Seasons burns with unpaid bonuses; a distributor donation does not increase any Merkle entitlement and remains after the legitimate allocation is claimed. These are voluntary transfers of the payer's own assets, already documented in threat-model section 3 and accepted in R4-A2-4. Adding recipients to the hook's deny list would change that behavior without repairing a reproduced third-party loss.

The finding's inclusion of **the gate as a successful sink does not reproduce**: PLEA permits transfers into the gate only when the gate pulls them. A buy naming it reverts atomically, with the buyer's IMD, total supply and burn accounting unchanged. `test_namedGateBuyRevertsWithoutSpendingTheBuyersFunds` preserves this distinction.

## Launch compatibility

- The existing manifest deploys `PLEA`, `CabalGate`, `Seasons`, `PleaDistributor`, `PleaLaunch`, in that order, in one zero-value factory transaction. Their nonpayable constructors have 1, 7, 4, 2 and 13 static arguments. There are no external library links. Calls from Seasons and PleaLaunch's constructors resolve only earlier applications in the same transaction; no live mainnet dependency is required to deploy the five applications.
- PLEA and the distributor receive `$owner`; PleaLaunch derives its immutable fee beneficiary from PLEA. The current PLEA owner retains early seeding and the add-only sender exemption; the distributor root remains owner-settable once. The factory and transaction origin receive no admin role. The hook's original owner remains excluded from points and prizes after a PLEA ownership transfer.
- `PLEA.setLauncher` retains both the deployment-transaction flag and the deployment-block fallback. The production five-contract deployment must remain atomic. `PLEA.init` still mints exactly once, after the committed hook is deployed, with the 82/6/12 split.
- Letterbox and Tribunal remain post-launch deployments against the manifest's existing hashes. The hook remains a separate CREATE2 deployment with mined permission bits and `getHookPermissions()`. The existing post-launch scripts are retained. Trading waits for all three contracts.
- Every requested setting and economic rule is unchanged, including START 1795532400, mainnet dependencies, 400,000 credit gas, 20,000 IMD opening market cap, chain-1 seed floors, pass mark 69, holding points 3/2/1, received-PLEA profit 9, the fact table, 2.25% fees, plea limits, letter fees/floors/slippage, panel/quorum, objection timings/stake/margin/cap, wall/cap pace and season prizes.

| Contract | Runtime bytes | EIP-170 headroom |
|---|---:|---:|
| PLEA | 4,893 | 19,683 |
| CabalGate | 24,018 | 558 |
| Seasons | 12,473 | 12,103 |
| PleaDistributor | 1,513 | 23,063 |
| PleaLaunch | 4,178 | 20,398 |
| PleaHook | 24,381 | 195 |
| Letterbox | 23,255 | 1,321 |
| Tribunal | 21,654 | 2,922 |

The unchanged creation-code commitments are:

- Letterbox: `0xd3371a7f985211e18339f476d2f56e7bd478b585aec574558c6bc3af40d8c8d5`.
- Tribunal: `0x4869267458c34ec220c42b46c12246890825e504a335dde33bde75b7e5c47274`.

## Verification

All fuzz checks used `FOUNDRY_FUZZ_SEED=0x53811c629d9d2cffb354db49454a04ae5cf07e0d32343f242370e49e78d51169` with the repository's own compiler settings (Solc 0.8.26, Cancun, via-IR, optimizer 200).

- **`forge build`: passed.** The initial build compiled 122 files in 31.38 seconds; the final build after adding and refining the regression suite compiled its changed file in 20.71 seconds. Existing compiler warnings remain; no compiler settings were overridden.
- **`forge test`: passed before the change (22 tests). Final `forge test -vv`: 30 passed, 0 failed, 0 skipped, in 6 suites.** This includes all eight new regressions, the atomic manifest deployment, dependency/ownership wiring, deployment-block fallback, init-code limits, runtime/opcode checks, one-time mint split, and both code-hash commitments.
- **Every one of the 48 files in `test/full/`: passed**, using `FOUNDRY_PROFILE=full forge test --match-path 'test/full/{A,B,C}.t.sol'` in 25 sequential groups (invariant files separately). Foundry reported **803 passed, 0 failed, 0 skipped across 84 suites**. These totals count a grouped invariant campaign as one entry; all constituent invariants passed. Coverage includes historical audit regressions, gate and hook adversarial cases, both pool orientations, letter custody in both fee modes, ownership, distributor claims, season accounting/ranking/bonus, oracle conformance/replay, trader attribution, and Tribunal eligibility/rulings/stakes/text. Compilation plus execution of all groups took 811.14 seconds. No whole-tree full-profile build was run.
- **Launch gas:** 13,489,877 under the project's factory-overhead model; **16,457,649 with 22% headroom**, leaving **319,567** below the 16,777,216 cap. The separate Letterbox and Tribunal transaction estimates are 5,580,980 and 5,271,271. These are local rehearsal measurements, not deployment receipts.
- Artifact inspection confirms the five constructors are nonpayable, have the manifest's exact static arities, and contain no library links. Creation code including arguments is respectively 5,929 / 25,797 / 13,140 / 1,861 / 31,849 bytes, all below 49,152. Runtime sizes and committed hashes remain those listed above.
- The fork suites were not run; the external mainnet dependencies remain configured at the requester's specified addresses, without a new live-verification claim. No tools or dependencies were installed.
- Final diff review confirms only this report and `test/MainnetImportReview.t.sol` are delivered changes. `git diff --check` passed. Production source, scripts, manifest, protected build files and dependencies are unchanged; scratch logs and the batching helper are excluded from submission.
