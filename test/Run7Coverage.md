# Additional run-7 regression coverage

These tests supplement the existing manifest, audit-round, token, trading, letter,
season and Tribunal suites. No production code, launch arguments, dependencies or
Foundry settings are changed.

- `Run7DistributorLifecycle.t.sol`: bounded random sequences begin before root
  publication and mix ownership nominations, replacement, cancellation, acceptance,
  renunciation, publication, claims, corrupt proofs and donations. Ghost accounting
  checks every recipient and bitmap edge against the committed allocation, including
  the maximum index. Administration cannot move funds; failed claims cannot consume
  allocations; claims remain available after renunciation. A helper deploys and
  initializes the real PLEA and distributor in one outer call.
- `Run7SeatAccounting.t.sol`: bounded random seat changes, delayed recording, bad
  NFT replies, donations and season closing. An independent batch ranking model
  uses the score and seat observed at each successful record. Existing records never
  gain or lose points when the NFT moves or fails. Both IMD and PLEA bonus balances
  are reconciled against payments and burns. The mock gate supplies external results;
  the real Seasons and PLEA perform ranking, payment, burning and access checks.
- `Run7ObjectionPoints.t.sol`: real gate/Tribunal/Seasons/Letterbox/pool integration
  with 18,000-second seasons, 118,800-second dead-man and 1,300,000 credit gas, in
  both currency orientations. Covers raw score versus multiplied points, denial,
  sustained and overruled objections, two panels, changing seats while points are
  held, exact deadline boundaries, late-record duplicates, late stake settlement,
  the sixth bonus season, and sales remaining final while points are disputed.

Both new stateful campaigns run in the default profile. Explicit deterministic
sequences exercise successful payments and rejected transitions, so conservation
is also checked in states with actual payouts. Expected reverts are checked by
selector (and arguments where applicable); unexpected handler reverts fail the
campaign. The existing `LaunchManifest.t.sol` and `ManifestInput.t.sol` continue to
check the exact manifest and both creation-code commitments.

One residual defect is reported in `.imd-findings.json`: a seller who accepts PLEA
ownership while an objection is pending is excluded by Seasons, but the Tribunal's
`standing` view still reports the plea as held. Both an isolated reproduction and a
real deployment integration test failed on that expected-versus-actual difference.
The report contains the self-contained failing proof; the passing suite does not
assert that this behavior is correct. The observed defect is limited to standing;
Seasons still refuses the excluded seller's points.

Run the production build first, then this group, without compiling the entire tree
as one fresh solc job:

```sh
forge build --skip test --skip script
FOUNDRY_FUZZ_SEED=0x2098de5e4458b94d3d9244de82563d528653d0a20bd536067c6a06aacc930687 \
  forge test --match-path 'test/{Run7DistributorLifecycle,Run7SeatAccounting,Run7ObjectionPoints}.t.sol'
```

No RPC, network access, `ffi`, environment mutation or additional dependency is
needed. Exact external Sepolia addresses are exercised by the existing manifest
tests; external NFT, oracle and quote services are controlled locally in these
behavioral tests.
