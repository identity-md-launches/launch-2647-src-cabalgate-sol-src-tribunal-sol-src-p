# PLEA swarm audit loop

Before the run-7 launch job (and again before mainnet), the IMD swarm audits the pinned commit with **three IMD audit jobs, one per area** (PondPad's pattern). Each job is IMD's native `audit` template: four specialists (math, permissions, economics, control flow) read the code at once, then a judge reproduces, merges and ranks their findings. We fix, push, and run another round on the new commit until every area is clean.

| File | What it is |
|---|---|
| [`THREAT-MODEL.md`](THREAT-MODEL.md) | Actors, trust, the 22 invariants with the agreed numbers, deliberate behaviour (not findings), the severity scale. Every job reads it |
| [`FINDINGS.md`](FINDINGS.md) | Ledger of rounds and findings (open / fixed / accepted), seeded with the run-5 and run-6 panel findings. Every job reads it |
| [`jobs/`](jobs/) | `common.md` (the shared objective) and one file per area: `A1.md`, `A2.md`, `A3.md` |
| [`make_jobs.py`](make_jobs.py) | Builds a round at a pinned commit; `--check` runs IMD's free check on each job |
| `rounds/<n>/` | Per round: `manifest.json` (every in-scope file, sha256, lines), `<ID>.objective.txt` (paste into the form), `<ID>.request.json` (API body), and the reports once they are in |

## Scope

`src/` (nine contracts and two interfaces), `script/` (the local and post-launch scripts) and `launch.json`. Out of scope: tests, `lib/`.

| Job | Area | Files |
|---|---|---|
| A1 | The game | `CabalGate`, `Tribunal`, `Seasons`, `OracleAttestation`, `IPleaParts` |
| A2 | Letters and the launch | `Letterbox`, `PleaLaunch`, `PLEA`, `PleaDistributor`, `launch.json`, `script/*` |
| A3 | The market | `PleaHook`, `IStacker` |

Cost: 0.5 IMD per job, **1.5 IMD per round**, paid in IMD on Ethereum mainnet through the explorer.

## One round

1. **Freeze.** Commit the code to audit and push it (the swarm reads GitHub).
2. **Build the jobs:** `python3 audit/make_jobs.py round 1 --check` (HEAD; or `--commit <sha>`). It writes `rounds/1/` and runs IMD's free check on each job.
3. **Submit each job (A1 to A3) in the web form** at <https://explorer.imd.fun/launch> ("Hire the swarm" → **Audit**): repository `https://github.com/khaed1/plea` at the full commit, Description = the whole of `rounds/1/<ID>.objective.txt`, **Check** (free: four specialist steps and a judge, no blockers), then pay (0.5 IMD). Note the job id.
4. **Read the reports** at `https://api.imd.fun/jobs/<job id>/report.md` once the judge is accepted (`GET /jobs/<id>/submissions` for each node's findings on the way).
5. **Record.** Save the reports in `rounds/1/`, add the round and every valid finding to `FINDINGS.md`, commit.
6. **Fix.** One commit per finding where practical, each with a test that fails before the fix. Critical and High: always fixed. Medium: fixed, or accepted by the project owner with a written reason in `FINDINGS.md`. Low / Info: fixed when cheap.
7. **Repeat** from step 1 on the new commit until all three judges report no open Critical or High and no Medium is open.

Then the launch job is pinned to the clean commit, so IMD's adapt step has nothing left to change and the delivered Letterbox and Tribunal hashes stay ours.
