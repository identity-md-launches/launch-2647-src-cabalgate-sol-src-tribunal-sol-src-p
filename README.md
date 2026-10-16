# PLEA

**A sell-gated meme token on Uniswap v4.** Anyone can buy. To sell, you write a plea, and **the Cabal** decides. The Cabal is a panel of 30 IdentityMD oracle judges that scores each plea from 0 to 45. While the Cabal lives, approved pleas also compete in **seasons** for IMD and PLEA prizes. If the Cabal goes 33 hours without a verdict, it dies, and PLEA trades freely forever.

Launched through the IMD swarm straight from this repository (`launch.open` with `repoUrl` + `baseCommit`). It builds on PLEA v2 (IMD launch #1148) and the v4 fixes.

---

## Contents

- [At a glance](#at-a-glance)
- [How it works](#how-it-works)
  - [Buying](#buying)
  - [Pleading to sell](#pleading-to-sell)
  - [Pleading by letter](#pleading-by-letter)
  - [The judges' rules](#the-judges-rules)
  - [The fact score](#the-fact-score)
  - [The dead-man](#the-dead-man)
  - [Seasons](#seasons)
  - [Objection!](#objection)
- [Fees](#fees)
- [Contracts](#contracts)
- [Launch and lifecycle](#launch-and-lifecycle)
- [Build and test](#build-and-test)
- [Design notes](#design-notes)
- [Credits](#credits)

---

## At a glance

| | |
|---|---|
| Supply | 1,000,000,000 PLEA (82% pool liquidity, 6% season bonus prizes, 12% Merkle distributor: the swarm's 10% and a 2% airdrop) |
| Pool | PLEA/IMD on Uniswap v4 with a fork of POOL4's CappedBurnHook: LP fee 0, the hook is the only LP, liquidity locked forever |
| Selling | Through the Cabal's gate while it lives, from the site or by sending a letter (a text transaction, e.g. from Etherscan); owner-allowlisted senders are exempt |
| Judges | 30-seat oracle panel, quorum 17, score 0–45 |
| Trade fee | 2.0%, paid inside the swap (0.5% back to the trader as staked IMD, 0.75% to the owner, 0.25% prize pot, 0.25% buy wall, 0.25% of the PLEA burned) |
| Seasons | 15 days each (5 hours on Sepolia); the top 25 wallets with 60+ points share the IMD pot (4.50% for first place down to 3.50% for 25th), and for the first six seasons 10,000,000 PLEA each. Holders of an IMD seat NFT earn 1.2× points per plea |
| Objection! | For 20 minutes after an approval anyone else may object (0.5 IMD fee + 0.35 IMD stake): a second panel re-scores the plea; its points can only fall, and fall to nothing if the new score is more than 2 below the need |
| End state | 33h with no verdict → the Cabal dies → free trading, no comeback |

---

## How it works

### Buying

Buying is open to everyone from the moment trading opens. PLEA bought while the Cabal lives is delivered as a plain ERC-20 to the buyer, and the hook records each buyer's cost basis and buy-weighted holding time for the fact score.

For the first **90 minutes** after trading opens, buys pay an extra launch fee that falls from 70% to 0% of the IMD that reaches the pool (41.8% of the IMD sent at the open, 0% at the end) and are capped at **5M PLEA** each.

### Pleading to sell

While the Cabal lives, ordinary holders send PLEA through `CabalGate`. The owner can permanently exempt any sender with `PLEA.allow(account)`. An exempt sender can transfer to buyers or other trading venues without a plea or this hook's fees and cap trim; direct transfers to this pool's PoolManager and gate remain restricted. This add-only owner power is part of the accepted launch design.

1. **Plead.** Ask to sell at least **1%** of your balance (or 2.5M PLEA, when that is less) and at most **2.5M PLEA** and **50%** of your balance, with a plea of **1–280 bytes** (UTF-8: about 280 Latin, 140 Cyrillic or Arabic, 93 CJK characters; any language is judged), and pay the **0.5 IMD** oracle fee. The gate pays the IdentityMD Intake itself. The minimum keeps real PLEA on the line: a plea for a few wei could otherwise earn full season points.
2. **Need.** The contract computes your fact score (0–45, below). Your **need** is `71 − fact score`. If the need is above 45, no plea can pass, so the gate refuses it (`CannotPass`) before you pay. A fresh buyer selling up to 20% at a loss needs 37; after a day 35, after three days 33, after a week 30 (on mainnet panels a strong letter scored 37, ordinary serious pleas 28-35, so the panel decides for new holders and a week-old holder usually passes). Profit costs points slowly: a holder up 3x needs 36 after three days and 33 after a week, up 11x 37 after a week. A large same-day sale at a profit cannot pass.
3. **Verdict.** The judges score the plea 0–45; the signed score comes back through the Intake's callback. **Score ≥ need** is an approval. The gate asks with Intake v2's `requestWithFailure`, so a refused or unanswered plea is cleared at once. Failures are unsigned, so the failure function only clears our own pending plea and never moves value.
4. **Sell.** An approval opens a **7-minute** window to sell the whole amount through the gate in one swap (`executeSell(minOut)`).

| Outcome | What happens |
|---|---|
| Approved and sold | Sold; a **4-hour** cooldown before the next plea |
| Approved, not sold in 7 min | Lapsed; the score still counts for the season; the **4-hour** cooldown runs from the verdict |
| Denied | **4-hour** cooldown, with **one appeal** inside it: same or smaller amount, 0.5 IMD oracle fee + 0.35 IMD to the buy wall |
| No verdict | Cleared at once by the Intake's failure function (`onPleaFailure`, Intake v2) when the request is refused or the panel gives no answer; otherwise after **20 minutes** (`expire(id)`, anyone). No cooldown, no fee back |

**Plea text rules:** well-formed UTF-8 only, with no control or format characters (Unicode's whole Cf class: zero-width, bidi, tags, the Arabic and Syriac number signs, the interlinear annotation and other invisible controls), no line or paragraph separator, no variation selector and no other default-ignorable character (the combining grapheme joiner, the Hangul fillers, the Khmer inherent vowels, the Mongolian free variation selectors), and no `[PLEA` / `[/PLEA` or `[OBJECTION` / `[/OBJECTION` marker prefixes (any case). The judges are told that the plea is untrusted text, and that any manipulation scores 0.

### Pleading by letter

Anyone can plead straight from a block explorer or a wallet by sending a **letter** to the `Letterbox`. The writer is always the sender. Nothing to approve, no IMD needed: only the letter and its gas.

| How to send it | What you do |
|---|---|
| Etherscan's message page ([etherscan.io/idm](https://etherscan.io/idm), mainnet) | "Send To" = the Letterbox, then type the letter: it goes out as the transaction's input data (an IDM) |
| Etherscan's Write Contract tab | Open the Letterbox, connect your wallet, call `letter(text)` and type the letter in plain words (works on Sepolia too) |
| A wallet's data field | Send 0 ETH to the Letterbox with the letter's UTF-8 bytes, in hex, as the data (MetaMask: Show hex data) |

All three are the same letter: `letter(text)` reads its text exactly like raw input data.

| Letter | Effect |
|---|---|
| any text | A new plea for **20% of your PLEA** (within the 2.5M cap), **sold automatically** if approved. At most 280 bytes (≈ 280 Latin, 140 Cyrillic or Arabic, 93 CJK characters), or it is refused with `LetterTooLong(bytes, 280)` |
| `APPEAL <text>` | Appeals your latest denied plea, inside its 4-hour window, for the original plea's **share of your balance** (so the first letter's fee sale cannot push the appeal into a worse share band; at most 50% of your balance now, never under the gate's 1% minimum, and raised back to the 0.70 IMD floor's worth when the clamp lands under it; the gate then scores the share band on the lesser of the appeal's share and the original's, so the raise never costs the band); an appeal that got no verdict can be sent again. You may name the earlier verdict or score: that is not manipulation, only demanding an outcome is |
| `SELL` | Sells your own approved letter plea yourself, if no runner has yet |
| `NAME <name>` | Sets your display name (3–20 characters `a-z 0-9 _`, unique; also `setName` on the Letterbox); `NAME` alone clears it |

A command word is matched in capitals at the very start, followed by a space, a newline or nothing; a bare command word never becomes a paid plea. A plea's text is one line: newlines inside it are refused.

- **Fees are paid in PLEA, in the letter's own transaction.** The gate sells just enough of your PLEA, through the hook with the normal 2.0% fee and your own 0.5% cashback, for exactly the IMD needed: the 0.5 IMD oracle fee, a **0.25 IMD runner tip** and, for an appeal, the 0.35 IMD wall share. That is all a letter ever costs: **letters pay no auto-sell fee**, and a writer who sends `SELL` gets the tip back. It may spend at most the hourly snapshot value **+10%**; unspent PLEA comes straight back. A letter whose fees would take more than 10% of your PLEA, or whose 20% is under 1,000 PLEA (a balance under 5,000 PLEA), is refused (an appeal's fees may instead go up to the original plea's amount, with the same 10% slack, so whoever could plead by letter can appeal by letter unless the hourly price fell sharply since the letter: by more than about 14% at the 0.70 IMD floor on Sepolia, about a third when the fees are bought in IMD). On Sepolia the oracle fee token is a separate test token, so the Letterbox mints that 0.5 instead of buying it.
- **Escrow.** The plea's PLEA waits in the Letterbox. It keeps its buy record: only the final sale reduces it.
- **Auto-sell.** Once approved, **anyone** may call `deliver(id)` inside the 7-minute window: the gate sells the escrow for at least **95%** of its snapshot value after the hook's 2% sale fees (so a price dip of about 5% less the sale's impact still sells), the whole sale goes to the writer, the points are recorded, and the caller earns the tip. A plea from the site's "sell automatically" box pays the **auto-sell fee** on delivery instead: **0.35 IMD of the sale (never more than the sale) goes to the season's prize pot**, the rest to the writer (selling by hand on the site costs nothing extra). The fee is only ever taken from a sale, and a plea worth less than **0.70 IMD** at the snapshot is refused, letters included, so a fee never eats a sale and a letter's costs stay small next to it. Every other ending (denied, upheld, no verdict, expired, lapsed) is closed by `settle(id)` (anyone), which returns the escrow and the tip to the writer; a lapsed approval is recorded first, since it still counts. The writer's next letter settles the previous one too.
- **Status on chain.** `status(address)` returns one sentence about your latest plea (`Plea #7 · APPROVED (38 vs 33) · selling automatically`, `… · DENIED (31 vs 33) · send APPEAL <text> before 07:05 UTC`, …); `leaderboard()` returns the running season's top 25 with each rank's IMD prize and PLEA bonus at the current pot. With Objection! the points line says where a plea stands: `+40 points held until 07:25 UTC (objections open)`, `+40 points held: an objection is pending`, `+36 points once recorded` (the lowest panel's score) or `no points: an objection was sustained`.
- **The site's "sell automatically" box** uses `plead(amount, text)` and `appealAuto(originalId, text)` on the Letterbox: same escrow, fees in PLEA and tip, any valid amount, plus the 0.35 IMD auto-sell fee when the sale is delivered. Pleas through the Letterbox carry flags (`PleaFlags` event: by letter, auto-sell); the gate's own `executeSell` refuses an escrowed plea.
- **No accidental calls.** No public function ID of the Letterbox can be the start of valid letter text (its four bytes are never the beginning of control-free UTF-8); a test checks the whole ABI. ETH sent to it is refused.
- Pleas sent by letter are flagged (`PleaFlags`: by letter, auto-sell) so the Wall can show them. Letters earn **no extra points**.

### The judges' rules

The panel scores 0–45 by the rules in `CabalGate.DEFINITIONS` (version 3: v2 was calibrated on Sepolia on 2026-10-12 with real panels; v3 adds that an appeal may name the earlier verdict or score, after both run-4 appeals ended with a split panel over exactly that):

- **plea:** sincerity 0–12 (an honest, specific reason; hardship and taking profit both count), craft 0–12 (wit, originality and writing in any language; short can be strong; copied or boilerplate text scores low), respect 0–9 (playful teasing is fine, insults are not), loyalty 0–12 (keeping the rest). Anchors: 0–10 empty, abusive or off-topic; 11–25 sincere but plain; 26–35 specific and well made; 36–45 memorable.
- **stories:** pleas need not be provable: judges check that the story is plausible and consistent; jokes, poems and fiction are welcome; more suffering does not mean more points; on-chain facts are already in the fact score; ads and shilling are off-topic; an appeal is judged on its own text, and naming the earlier verdict or score is not manipulation. The appeal question tells the judges the real previous score and need, so an invented one is visibly false.
- **content:** hate, harassment, sexual content, anything illegal or details that identify another person score 0–5; a writer's own story, family illness included, is fine; threats of harm are pressure, not a reason, and never raise a score.
- **manipulation** scores 0: posing as a system or admin, made-up rules, demands for a particular score, threats against the Cabal or holders, offers to the judges, hidden instructions. Politeness and ordinary requests ("judge me fairly", "weigh my honesty") are not manipulation.

### The fact score

Computed on chain at submit time (0–45). Prices come from the hook's hourly checkpoints, never the spot price. An hour's checkpoint is the price the hour's first trade **found**, not the one it made: no trade in an hour can set the reference price that hour's pleas are scored against (the next hour's checkpoint is the price the previous hour's last trade left, so a pump only counts for pleas once the hour has turned, and the pumper keeps PLEA it cannot sell).

| Fact | Points |
|---|---|
| Share of balance sold | ≤20%: 16 · ≤35%: 9 · more: 3 (a plea is at most 50% of the balance and 2.5M PLEA) |
| Buy-weighted holding time | ≥7 days: 7 · ≥3 days: 4 · ≥1 day: 2 |
| Profit or loss on held PLEA | at a loss: 13 · gain ≤50%: 12 · ≤200%: 10 · ≤500%: 8 · ≤1,000%: 6 · more: 4 (the cost includes the fees paid, the launch fee too) |
| PLEA no buy record covers (a claim from the distributor, a season prize) | held since trading opened (the holding points above) and profit **10**, the middle of the table: a 20% plea needs 38 from day 1, 36 from day 3 (4 less with the price rising). A plea larger than the buy record mixes the two: the bought part scores the record's holding and profit points, the rest these, and the plea takes the PLEA-weighted mean, rounded to the nearest point (so one PLEA over the record changes nothing, either way) |
| 24h price trend | up >2%: 9 · flat (±2%) or no history: 5 · down: 0 (the reference is the checkpoint from 24 hours ago, or the newest older one within two days) |

### The dead-man

The Cabal is born when trading opens and lives until **33 hours** pass without a signed verdict (approved or denied). Then it is dead for good. No plea can be submitted, every transfer restriction ends, and a late callback cannot revive it. `cabalAlive()` is computed, never stored, so nobody has to trigger the death.

### Seasons

- Seasons of **15 days** run back to back from the moment trading opens. The last one ends when the Cabal dies.
- An approved plea earns its score as **points**. Each wallet's **best three** pleas in a season count.
- **Seat multiplier.** A seller who holds at least one **IMD seat NFT** (the identity.md NFT on Ethereum, the test NFT on Sepolia; `Seasons.seat`) when the plea is recorded earns **1.2× the score** as points (rounded down: 45 → 54). One seat or ten, the same. Points only: the judges' score, the need, the Tribunal's comparison and the 60-point bar are untouched. The NFT is read with a gas-capped `staticcall` that never blocks a record (no seat, a reverting read or a missing contract mean no multiplier). `Seasons.pointsFor(wallet, score)` says what a plea would earn now.
- Points are recorded by `Seasons.record(pleaId)` (anyone; the seller has every reason to), or by `closeSeason`, once the plea's objection window has closed and no objection is pending (see [Objection!](#objection)).
- When a season ends, anyone calls `closeSeason(pleaIds)` after a **1-hour grace**:
  - the **top 25** wallets with at least **60 points** are paid shares of the prize pot in IMD that fall in a straight line from **4.50%** (first) to **3.50%** (25th): 450, 446, 442, 438, 433, 429, 425, 421, 417, 412, 408, 404, 400, 396, 392, 388, 383, 379, 375, 371, 367, 362, 358, 354 and 350 basis points (`Seasons.shareBps`);
  - unpaid shares roll over to the next season;
  - **PLEA bonus, first six seasons:** the same top 25 (same shares, same 60-point minimum) also split **10,000,000 PLEA** (1% of the supply) per season, from the 6% minted to `Seasons` at launch. Unpaid shares are burned at the close; nobody can withdraw the bonus, the owner included.
- **The owner of PLEA does not play.** Its pleas earn no points, and no IMD prize or PLEA bonus goes to it; its rank's share rolls over or is burned. The exclusion covers the current owner and the launch owner the hook pays its 0.75% to, so a handover inside the team cannot bring a prize back to it. Ownership moves in two steps and a nomination alone excludes nobody, so the owner cannot strip a leader by naming them. So the prize fee and the wall always leave the team for good.
- Holders can set a display name (`Letterbox.setName` or a `NAME <name>` letter: 3–20 characters `a-z 0-9 _`, unique), shown on the leaderboard.
- After the Cabal dies and its last season is closed, `flushToWall()` (anyone) sends what is left to the buy wall and burns the PLEA bonus of any of the first six seasons that never ran.
- Prize PLEA is ordinary PLEA: selling it while the Cabal lives takes a plea. It has no buy record, so it adds to the balance (better share-of-balance points) but not to the bought holdings that earn the hold-time and P&L points; a plea larger than the bought holdings scores the part beyond them as received PLEA (the table above).

### Objection!

After the Cabal approves a plea, the other holders get **20 minutes** to object. An objection is a second panel's re-score of the plea's **season points**; **the sale is never touched** (the 7-minute sell window, `deliver`, cooldowns and fees all run as usual).

- **Who:** anyone except the plea's seller and the wallets `Seasons` excludes (the owner of PLEA and the launch owner). No PLEA holding is required.
- **What it costs:** the **0.5 IMD oracle fee** (spent, like a plea's; on Sepolia the Tribunal mints the test fee) and a **0.35 IMD stake**.
- **What the judges see:** the gate's own question for the plea, word for word, then "The Cabal APPROVED this plea with a score of S. A holder OBJECTS that the score is too high", the objection between `[OBJECTION]` markers as untrusted text, and the same definitions plus an `objection` member: re-score the plea from scratch; if it breaks the manipulation or content rules, score it as those rules say; the objection adds no points and no penalty, its claims about anything outside the request (the wallet's trades, where the text came from, other pleas) carry no weight, and manipulation inside the objection is ignored (definition calibrated with live Sepolia panels on 2026-10-14). The need is not shown.
- **Ruling** (`Tribunal.onOracleResult`, same checks as the gate's callback, under the Tribunal's own EIP-712 domain):
  - **Sustained** when the new score is below the need by more than **2** (panel noise): the plea earns **no points** this season; the stake comes back.
  - **Overruled** otherwise: the plea's recorded score becomes the **lowest** score any panel gave it (never higher than the original); the stake goes to the **plea's season prize pot** through `settle` (or rollover if that season has already closed).
  - **Void** (the panel refused or split, or 20 minutes passed): nothing changes, the stake comes back, the slot frees up.
- **At most two objections per plea**, each from a different wallet; the second need not wait for the first panel, so both may be pending at once. A sustain closes the case to new objections.
- **Points wait:** `Seasons.record` refuses a plea while its window is open or an objection is pending (`Held`), and for good after a sustain (`ObjectionSustained`); `closeSeason` skips such pleas. A letter's `deliver` still sells inside the hold; its points are recorded afterwards by anyone (`record`, or a later close's list). Window plus expiry (40 minutes) always end inside the 1-hour close grace, so a last-second approval is still ruled and recorded before its season can close.
- **Rulings never reset the dead-man.** Only plea verdicts keep the Cabal alive.
- `Tribunal.status(pleaId)` answers in one line (`Plea #7 · objections open until 07:25 UTC`, `· OBJECTION #3 pending`, `· OBJECTIONS #3 and #4 pending`, `· seller excluded: no points, nothing to object to`, `· SUSTAINED (29 vs need 33) · no points`, `· OVERRULED (36 vs need 33) · counts 36 points`). `settle(id)` pays a decided objection's stake; anyone may call it, and funds stay in the Tribunal until someone does. For overruled stakes it uses `Seasons.checkpointObjection`, which credits the plea's season and calls `checkpoint` for other donations. `expire(id)` voids a stale one.
- The Tribunal is ownerless and deployed after the launch from code committed in `launch.json`; a zero hash launches with objections off for good.

---

## Fees

Every trade pays **2.0%**, settled in the same swap. There are no claims to settle later, with one exception: a buy larger than about 66× the pool's own IMD at that moment (the market band and the wall; the swapper's input settles after the hook runs, and the PoolManager's balance itself is never trusted, since a router could flash-take it inside its own unlock) is paid its cashback, owner and prize shares as ERC-6909 IMD claims on the PoolManager, redeemable with a contract that unlocks, burns and takes (Seasons redeems its own at a close). In practice that is the opening minutes, which the owner's own 2 IMD buy right after `seed` covers (the pool's IMD plus the next buy's fee then reach the 2 IMD reserve), and a buy right after a post-death sell has drained the market band. The refund of a partially filled exact-input buy (a price limit of the trader's own choosing) comes after the payouts and is paid the same way when it exceeds what the PoolManager still holds. An exact-output trade (after the Cabal's death; refused while it lives) fills whole or reverts `PartialFill`: its fee is reserved on the requested output, so a price limit must leave room for the whole fill.

| Share | Goes to |
|---|---|
| 0.50% | Cashback to the trader as staked IMD (sIMD), through imd/acc's Stacker (approved for exactly that cashback, per credit; the wall reserve the hook holds is never within its reach) |
| 0.75% | The owner |
| 0.25% | The season's prize pot (pool liquidity once the Cabal is dead) |
| 0.25% | Pool liquidity (the IMD buy wall) |
| 0.25% | Burned, taken from the PLEA side |

**Who gets the cashback and the buy record** (imd/acc's trader rule): the trader named in the swap's `hookData` (`abi.encode(trader)`); else the wallet the router is acting for, read from the router's `msgSender()` (the Universal Router and v4 Router expose it). else the swap sender itself, only when it is a plain wallet (in practice unreachable: the PoolManager calls back `unlockCallback`, which a codeless account cannot answer). A smart-contract wallet or an EIP-7702 account that calls the PoolManager itself counts as a router, so it must go through a router that names it (or name another recipient in `hookData`); while the Cabal lives its direct buy reverts `RecipientRequired`. Never a router, never `tx.origin`, never the Stacker, the IMD token, the sIMD vault, the PoolManager or the hook. When nothing resolves the trade still goes through without cashback (the 0.5% stays in the pool) and without a buy record, and the unearned fee of a partial fill is refunded to the router, the only party the hook knows; a buy while the Cabal lives needs a recipient for its PLEA, so it reverts `RecipientRequired`. The gate always names the seller.

Beyond fees, the hook keeps the market supplied the way POOL4's CappedBurnHook does: PLEA above an inventory cap is trimmed and **burned**, and recovered IMD is redeployed as an IMD-only **buy wall** below the price (`rebalance()`, anyone, unpaid: the wall's IMD never leaves the pool). `pendingRebalance()` is a hint: while a post-death sale has drained the pool to a price limit beyond the market band, `rebalance()` places no wall and reverts `RebalanceNotNeeded` when that is all it could do, so a keeper simulates the call before sending it.

- **Cap pace.** The cap starts at the seeded inventory and ratchets down toward what the market holds (on buys, and on sells that leave the market under it), at most `(seeded inventory − 900k floor) ÷ 15` PLEA a day, so it can reach its floor in 15 days (one mainnet season). It never falls below what the market actually holds. PLEA sold back above the cap is trimmed: burned, with the matching slice of IMD moved to the wall. A sale's input reaches the PoolManager only after the hook has run, so when a sale (after the death) is larger than the PLEA the PoolManager holds, the trimmed PLEA is kept as ERC-6909 PLEA claims and burned at the next `rebalance()` instead of reverting the sale (`pleaClaims`; the 0.25% sale fee too).
- **Wall placement guard** (POOL4's deployment floor, mirrored for an IMD bid). The wall is never placed above a guard price that drops at once to any lower price PLEA trades at, and rises toward the market at most 400 ticks (~4%) a day. Lifting the wall to a pumped price would mean holding that price for days. A sell that empties the pool's IMD side (free trading after the Cabal dies) ends at the seller's price limit, whether the router's default at the tick extreme or any limit chosen inside the liquidity-free region below the market band; the pool has no active liquidity at that tick, it is not a traded price, and the guard ignores it, so the wall is placed against the market once IMD is back, not parked at the extreme for years. A tick inside a band with liquidity was paid for in PLEA and the guard drops to it at once. Until the next buy brings spot back from a drained tick, `rebalance()` places no wall (it still redeems claims and closes a wall that is due), whatever limit the seller chose inside the liquidity-free region.

---

## Contracts

| Contract | Role |
|---|---|
| `PLEA` | ERC-20, 1e9 supply. Transfers are gated while the Cabal lives, with system-sender and permanent owner-allowlist exemptions. |
| `CabalGate` | Pleas, the Intake request and callback, appeals, gated sells and the dead-man. |
| `Seasons` | Points (with the seat multiplier), leaderboard, `closeSeason` payouts, the final flush to the buy wall. |
| `PleaHook` | The only liquidity provider (fork of POOL4's CappedBurnHook, IMD side): fees, cap and trim burns, buy wall, price checkpoints. Deployed after launch. |
| `Letterbox` | Letters (raw input data, or `letter(text)` from an explorer) and auto-sell: escrow, fees paid in PLEA, `deliver` for the runner's tip, `settle`, display names, and the `status` / `leaderboard` text views. No owner. Deployed after launch. |
| `Tribunal` | Objection!: objections to approved pleas, the second panel's request and ruling, stakes, and what `Seasons` reads before recording points. No owner. Deployed after launch. |
| `PleaLaunch` | Registers the contracts at launch and commits to the hook's, the Letterbox's and the Tribunal's code; `deployLetterbox`, `deployTribunal`, `deployHook` and `seed` afterwards. |
| `PleaDistributor` | Merkle claims for the 12% distributor share (the swarm's 10% and a 2% airdrop), one root set once by the owner. Two-step ownership; no renounce before the root is set. |
| `OracleAttestation` | EIP-712 verification of the IdentityMD oracle's signed answer. |

---

## Launch and lifecycle

`launch.json` lists the five launch contracts, deployed in order in one transaction:

```
PLEA → CabalGate → Seasons → PleaDistributor → PleaLaunch
```

The factory must deploy all five atomically. PleaLaunch's constructor registers the system contracts (`PLEA.setLauncher`) and commits to the code of the three contracts deployed afterwards: the Letterbox, the Tribunal and the hook. This keeps the launch inside one Ethereum transaction: mainnet caps a transaction at 16,777,216 gas (EIP-7825), and storing contract code costs 200 gas per byte. `PLEA.setLauncher` accepts the deployment transaction's transient flag **or** PLEA's deployment block, as required by the launch rehearsal. Until registration, any caller in that block can register first; atomic deployment prevents an intervening transaction. `script/Deploy.s.sol` is for local simulations only: its separate broadcasts expose this window and can also fail if they span blocks.

Then:

1. **Deploy the Letterbox.** Anyone calls `PleaLaunch.deployLetterbox(creationCode)` once (`script/DeployLetterbox.s.sol`). The code must match the hash committed at launch; the Letterbox reads its settings from PleaLaunch and `PLEA.setLetterbox` registers it (launcher only, once). `seed` waits for it, so trading never opens without letters.

   ```
   LAUNCH=… forge script script/DeployLetterbox.s.sol --rpc-url $RPC --private-key $KEY --broadcast
   ```

2. **Deploy the Tribunal.** Anyone calls `PleaLaunch.deployTribunal(creationCode)` once (`script/DeployTribunal.s.sol`); the code must match the hash committed at launch (a zero hash means the launch has no objections). `Seasons` finds it through PleaLaunch. With objections on, `seed` waits for it, so no plea is ever recorded out of its reach.

   ```
   LAUNCH=… forge script script/DeployTribunal.s.sol --rpc-url $RPC --private-key $KEY --broadcast
   ```

3. **Deploy the hook.** `script/MineSalt.s.sol` mines a CREATE2 salt whose address carries the hook's flag bits and calls `PleaLaunch.deployHook(salt, initCode)`. The init code is committed at launch, so the result is fixed whoever calls it. PLEA then mints 82% to the hook, 6% to Seasons (the bonus prizes) and 12% to the distributor.

   ```
   LAUNCH=… POOL_MANAGER=… IMD=… STACKER=… SEASONS=… CREDIT_GAS=… \
   forge script script/MineSalt.s.sol --rpc-url $RPC --private-key $KEY --broadcast
   ```

4. **Open trading.** `PleaLaunch.seed()` creates the pool at a 14,000 IMD market cap (5,700 on the Sepolia runs; at least that, within one 60-tick spacing: the band is aligned to the grid on the PLEA-only side) and starts the Cabal. The hook, the Letterbox and (with objections on) the Tribunal must exist first. PLEA's current owner may call it any time, and anyone may call it once `START` has passed.

**Ethereum mainnet settings** (`launch.json` on this branch, `mainnet`; `testnet7` is the same code with the Sepolia settings (run 7), `testnet6` run 6's, `testnet4` run 4's (launch #1466), `testnet3` run 3's (launch #1426), `testnet` run 2's):

| Setting | Value |
|---|---|
| Intake v2 | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| Oracle fee asset and pool IMD | IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Oracle signer | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| PoolManager | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Stacker | `0x06909f672301f28a810f78cfe7a754851269f4f0` (imd/acc launch #1409, live since 2026-10-12) |
| Seat NFT | identity.md `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d` (the IMD seats; 1.2× points for holders) |
| Season | 15 days |
| Dead-man | 33 hours |
| Plea timings | 20 min, 7 min, 4 h |
| `START` | **TODO** (placeholder 1793016000 = 2026-10-26 12:00 UTC in `launch.json`; the owner may seed earlier) |
| Cashback credit gas | 400,000 (a first credit measured 197k–249k on a mainnet fork) |
| Letterbox | buys the 0.5 IMD oracle fee with the writer's PLEA, with the tip (`mintOracleFee = false`) |
| Seed | 14,000 IMD market cap (`PleaHook.MARKET_CAP_IMD`; 5,700 on the Sepolia runs) |
| Owner | **TODO** (a fresh wallet; the owner cannot play seasons) |

The manifest rehearsal measures the launch as the chain charges it (the init codes as transaction data, then their execution) plus the overhead of IMD's real factory, measured by sending these five codes through the mainnet ProjectFactory on a fork (994,547 gas; the test adds 1.1M): about **13.49M gas**, and about **16.46M** with the 22% headroom IMD's deployer adds to a gas limit, under the 16,777,216 cap; the test asserts it. `deployLetterbox` is its own transaction of about **5.58M** gas, and `deployTribunal` about **5.27M**, `deployHook` about **5.4M** on Ethereum's schedule. `test/fork/ForkTestnet.t.sol` rehearses the whole run on a Sepolia fork against the live Intake v2:

```
SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-path test/fork/ForkTestnet.t.sol -vv
MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-path test/fork/ForkMainnet.t.sol -vv
```

`test/fork/ForkMainnet.t.sol` does the same on an Ethereum fork with chain-1 settings, against the real IMD, sIMD, PoolManager and Intake v2 (its price for a question is the gate's 0.5 IMD, and its 200k callback gas carries the verdict with room to spare): a letter buys the oracle fee and the tip with PLEA, a runner delivers it, a typed `letter(text)` is denied, appealed and refunded, and a site plea pays the fee in IMD. imd/acc's mainnet Stacker (launch #1409) is credited for real. `test/LetterboxInvariant.t.sol` runs random letters, appeals, verdicts, failures, deliveries, sales, settles and strangers' attempts in both the Sepolia and the mainnet fee modes, and checks that the Letterbox holds exactly its open escrows and tips, that every escrow ends once (sold only after an approval, otherwise refunded to its writer), and that no writer's PLEA moves except through their own letters.

The season length and the dead-man are constructor values so a testnet can run a fast clock. On Ethereum mainnet `PleaLaunch.seed` refuses anything below 15 days and 33 hours, and a hook built with an opening market cap under 14,000 IMD (`BelowAgreedMarketCap`: the cap is the hook's compile-time `MARKET_CAP_IMD`, 5,700 on the Sepolia code), checked when trading opens, on the live chain: launch rehearsals deploy the manifest on a bare EVM with chain id 1, where a constructor check refused the Sepolia settings.

---

## Build and test

Foundry 1.8.3:

```
forge build --skip test --skip script                  # the sources alone, under a minute
forge test                                             # the default profile: unit suites
forge test --match-path test/LetterboxInvariant.t.sol  # one heavy suite at a time
FOUNDRY_PROFILE=full forge test --match-path test/fork/ForkTestnet.t.sol   # with SEPOLIA_RPC_URL
forge test --isolate --match-path test/Launch.t.sol    # each call as its own transaction
```

The whole tree compiles under via-IR as one slow solc job (two contracts sit near the size limit), so the default profile keeps the fork rehearsals and the fuzz-heavy invariant and adversarial suites out of a bare `forge build` (`skip` in `foundry.toml`); `FOUNDRY_PROFILE=full` compiles everything with the same compiler settings. Build the sources first, then run the tests in groups with `--match-path`.

`foundry.toml` turns off forge's lint-on-build (`[lint] lint_on_build = false`). With it on, the linter runs out of memory on `PleaHook`.

**Gas per flow** (`test_gasBenchmark` in the fork rehearsal: Ethereum's gas schedule against the live Sepolia contracts, 280-byte texts with quotes):

| Flow | Gas |
|---|---|
| Buy (first, sIMD cashback included) | 0.94M |
| Plea from the site | 0.76M |
| Letter (a typical ~85-byte letter: 1.28M) | 1.46M |
| Appeal letter | 1.75M |
| Verdict delivery (the Intake's callback) | 0.19M |
| Sale from the site / `deliver` of a letter (records the points) | 0.60M / 0.83M |
| `record` | 0.21M |

The mainnet gas pass (escaping only the plea texts in the oracle question, unchecked byte reads in the text rules, the hook's price views reading one checkpoint, a one-slot escrow) cut these by up to half without changing any behaviour; `test/GasPass.t.sol` holds each change to the code it replaced.

---

## Design notes

- **The oracle callback is kept small.** Mainnet gives it 200k gas, so it only stores the signed score. Points are recorded separately (`record`, or `closeSeason` with a list of plea ids).
- **Cashback can't be skipped by a low gas limit.** A swap must reach the hook with the credit gas plus a 1M reserve, or it reverts. A wallet's gas estimate therefore always includes the sIMD credit, and only a credit that itself reverts (or a Stacker address without code, a launch misconfiguration) falls back to plain IMD.
- **Signatures:** a plain ECDSA signature is accepted first, then ERC-1271, so an oracle key with an EIP-7702 delegation still verifies.
- **The very first buy** after trading opens may find no IMD in the PoolManager yet. That one trade's cashback, owner and prize shares then go to pool liquidity instead of reverting (a buy whose fee rounds to zero does not count as that first buy). A later buy larger than about 66× the IMD the PoolManager holds at that moment is paid those shares as ERC-6909 IMD claims instead (the swapper's input settles after the hook runs); the owner's own first buy right after `seed` keeps that to the opening minutes.

---

## Credits

- **TokenWorks** and their CabalCoin (2025), the original "plead to the Cabal to sell" token. PLEA is inspired by it. Thank you for the idea.
- **POOL4**: `PleaHook` is a fork of POOL4's CappedBurnHook (Ethereum `0xc6c965bd164c483e87d0b550671798e9a3602840`), converted to the IMD side: IMD instead of ETH as the quote asset, trims burn 100%, and recovered IMD becomes an IMD-only buy wall.
