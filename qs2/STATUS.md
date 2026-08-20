# QuickySitter v2 build status

## The plan, 2026-07-29

Built in LSL now, ported to SLua later (DESIGN.md banner). Two stages, so the
first one ships on its own.

### Stage 1 — drop-in replacement, nothing else changes

`sitA` + `sitB` (2N scripts) become `core` + `seat` + `menu` (3 singletons).
They read the **v1 LSD schema** that today's `boot` writes and speak the
existing 900xx wire, so the notecard, the plugins, the HUD and every other
script are untouched. A four seater goes from nine scripts to four.

Work, in order. **All six done, and it compiles** (2026-07-29).

1. ~~Delete `[QS]anim`.~~ Permission cycling is measured (DESIGN.md §3), so the
   per-seat script never needed to exist.
2. ~~`seat` absorbs the animation driving:~~ acquire and start every occupant in
   one handler, two passes with one shared sleep for a pose change.
3. ~~Re-point `seat`~~ at the v1 schema (`qs:cfg:<ch>`, `qs:sitter:<ch>`).
4. ~~Re-point `core`~~ at `qs:p:<ch>:<i>`, coupling re-implemented as v1's
   `SYNC`-broadcast-by-name. The largest single piece of rework.
5. ~~Re-point `menu`~~ at the `qs:nm` / `qs:nt` sidecar.
6. ~~Delete `[QS]boot`~~ from qs2. The v1 boot keeps its job.

**Compiling means the syntax is valid and nothing else.** The schema reads, the
wire and the behaviour are all still unverified, and the gaps listed further
down are still gaps.

It does unblock the figure that has been open since the first draft. DESIGN
questions 1 and 1b ask what these three actually cost, and every number in
DESIGN section 2 is an estimate at 50 bytes per line of code. All three print
`llGetFreeMemory` in their ready line at verbose 1, so a `VERBOSE 1` in the
notecard turns the projection into a measurement.

| Script | code lines | predicted at 50 B/line |
|---|---|---|
| `core` | 235 | ~11.8 KB |
| `seat` | 294 | ~14.7 KB |
| `menu` | 356 | ~17.8 KB |
| **total** | **885** | **~44 KB**, against 2 x 64 KB per seat today |

### Stage 2 — several pieces of furniture in one linkset

Still wanted. Needs one new token and therefore does touch `boot`, which is why
it is not in stage 1.

```
ITEM Bett
SITTER 0|Links|F
SITTER 1|Rechts|M
ITEM Stuhl
SITTER 2|Sitz
```

* `boot` writes `qs:item:count` and `qs:item:<n>` = `<name>|<firstSlot>|<count>`.
  Nothing else in the notecard changes, and a file with no `ITEM` is one item.
* **`core` scopes `SYNC` to the item.** This is the semantic that has to be
  added rather than moved: v1 broadcasts a `SYNC` by name to every slot, so a
  bed pose and a chair pose sharing a label would couple across two pieces of
  furniture. Today that cannot happen because there is only ever one piece.
* `seat` resolves a touched seat prim to its item.
* Per-slot menus already exist in v1, so the menu side needs nothing.

**Out of scope for stage 2:** binding a non-seat prim (a bed frame, a cushion)
to an item so that touching it opens that item's menu. That needs prim-name
binding, which is a creator-facing change, and it can be stage 3.

> **2026-07-29: the format half is cancelled.** See the banner in
> [DESIGN.md](DESIGN.md). The runtime split stands; the notecard format change
> does not. What that costs of the code below:
>
> | Script | Fate |
> |---|---|
> | `[QS]anim` | **survives unchanged**, it is format-agnostic |
> | `[QS]seat` | re-point at the v1 LSD schema (`qs:cfg:<ch>`, `qs:sitter:<ch>`) instead of `qs:i` / `qs:s` |
> | `[QS]core` | re-point at `qs:p:<ch>:<i>`, and re-implement coupling as v1's name broadcast rather than the seat list in a pose row |
> | `[QS]menu` | re-point at the `qs:nm` / `qs:nt` sidecar instead of `qs:m` / `qs:pm` |
> | `[QS]boot` | **obsolete.** v1 `boot` keeps its job. |
>
> `core` carries the most rework, because `POSE`-versus-`SYNC` coupling comes
> back as a semantic it has to implement rather than read off a pose line.
>
> Still open and not cancelled: adding a single `ITEM` grouping token to the v1
> format, which is what several pieces of furniture in one linkset actually
> needs.

**What exists is a spine, not feature parity.** Sit down, get a pose, see a
menu, pick another pose, stand up. Enough to prove the architecture in
[DESIGN.md](DESIGN.md); nowhere near enough to put in furniture.

**Nothing here has been compiled.** There is no LSL toolchain in the
development environment, so syntax and behaviour are both unverified.

Written 2026-07-29. Line counts against the estimates in DESIGN.md §6.4:

| Script | code lines | estimate | |
|---|---|---|---|
| `[QS]boot` | 234 | — | new, no v1 counterpart to estimate from |
| `[QS]seat` | 399 | 480 | close |
| `[QS]core` | 151 | 475 | **a third of it** |
| `[QS]menu` | 374 | 840 | **under half** |
| `[QS]anim` | 100 | 120-150 | complete |

The gaps below are why `core` and `menu` are short. They are listed so the
shortfall reads as scope, not as an efficient implementation.

---

## Missing, and shipped in v1

These are features customers have today. Every one of them has to come back
before this is furniture.

| Where | Missing | Note |
|---|---|---|
| `core` | **Access gating**, the whole `root-security` handoff | Nothing is gated at all right now: any avatar can drive any menu. This is the largest single gap and the one with a security shape. |
| `core` | **Camera** (`llSetLinkCamera`, 90202) | absent entirely. **Deferred 2026-08-13** by decision: a notecard feature not every product uses, and it does not block a test run. |
| `seat` | ~~Gender-based seat assignment~~ | **Done** (0.15). v1 picks WHICH FREE SEAT an avatar lands on from their body-shape gender (sitA.lsl:1334). Not animation variants: that was an error in an earlier draft. v2 cannot copy the mechanism, since the arrival is already on a prim - it swaps the prim BINDING with a free seat that wants that gender. |
| `core` | **`SEQUENCE`** stepping and its timer path | parsed into `qs:x:*`, not consumed. **Deferred 2026-08-13** by decision. |
| `core` | **Keyframed motion** path in sit-target application | v1 pauses and resumes `llSetKeyframedMotion` around a pose change. **Deferred 2026-08-13** by decision. |
| `core` | Legacy 90045 pose-played broadcast | emitted; 90005 and 90060/90065 are done in seat. The rest of §7.5 is untested. |
| `menu` | 90299/90300 | 90100/90101 back route, 90271 resync and 90301 pose-saved are done. These two are not, and their contract has not been read yet. |
| `seat` | ~~90070~~ | **Done.** Both HUD scripts build their sitter mirror from it, and hudadmin looks the avatar up there before attaching, so omitting it stopped the HUD attaching at all. |
|---|---|---|
| `90096` / `90097` `QSALIVE` | sitter presence **and version**; hudadmin forwards the version to the updater | **nobody answers.** This is also the project's documented presence mechanism, so it is load-bearing beyond the HUD |
| `90100` / `90101` | menu choice, the HUD driving the pose menu | missing |
| `90271` | SYNC re-sync trigger | `core` has the v2 equivalent (`QSC_RESYNC`, 90423) but does not listen on 90271 |
| `90299` - `90301` | pose refresh and adjuster back-routes | missing |

Fixed in passing: **`90005`**, the stock "send menu to user", now opens a menu.
`menu` previously listened only for the v2 touch number, so anything that used
the stock number - plugins and the HUD both do - was ignored. Its id is either a
plain key or a `<controller>|<sitter>` composite, and both are handled.

`hudproxy`'s LSD reads (`qs:offset:alive`, `QPP_CFG:*`) are unaffected, since
those keys are written by other scripts entirely.

## The authoring path is not drop-in, and that is the principle's doing

Asked whether `[QS]prop` is needed for the HUD to attach. It is not: the chain
is `adjuster` → `90266` → `hudproxy` → `hudadmin` as ATTACH_FOR_ADJUST, three
scripts v2 does not replace, over link messages that never pass through the seat
engine.

**And that chain is the ADJUSTMODE auto-attach only, not "the HUD".** Corrected
after the product owner pointed it out: `[QS]adjuster` is removed by
`/5 cleanup`, and finalised furniture still has to work with the HUD, so nothing
the HUD needs may depend on it. What it does need - QSALIVE, the 90100/90101
back route, 90271 - is answered by `core` and `menu` and is unaffected. The
auto-attach is an authoring convenience; without the adjuster the user attaches
the HUD themselves, as they always could.

But v1's `sitB` renders `[HELPER]` and `[HELPER HUD]` as **hardcoded literals**,
and `[HELPER HUD]` is the entry point that fires 90266. `menu` carries no
authoring literals by design (DESIGN.md §2), so those buttons do not appear.

**Two ways out, and they are not equivalent:**

* **`[QS]adjuster` registers its own entries** over 90213, which is what the
  principle asks for and what makes `/5 cleanup` a real removal. Costs a change
  to a shipped script, so the drop-in claim becomes "swap the seat scripts *and*
  update the adjuster".
* **`menu` re-adds the literals**, which keeps the swap to three files and
  abandons the principle.

Not decided. It is the first place where "nothing else changes" and "no
authoring code in the base scripts" pull against each other.

### Resolved: the adjuster is forked into qs2

`qs2/[QS]adjuster.lsl`, copied from `qs/` at v1 1.27 and versioned 2.00. Two
changes, both marked `v2 FORK ONLY` in the source:

* `state_entry` registers `[HELPER]` and `[HELPER HUD]` over 90213 with the
  owner-only flag, since `menu` renders no authoring literals.
* The `/5 cleanup` teardown sends 90216 before removing itself.

The second one **fixes a bug that exists in v1**. The comment beside the
`qs:alive:adjuster` delete describes it: on the Paloma sofa the flag survived
the teardown and sitB kept rendering `[HELPER]`/`[HELPER HUD]` pointing at a
script that no longer existed. Registered entries leave with their owner, so the
race cannot happen.

**The registration channel is a link-message number, not a chat channel.** It is
90101, the back route this script already handles, so the click lands in the
existing handler unchanged. `menu` shapes the v1 payload
(`<slot>|<msg>|<controller>|<idx>`) for any entry registered on 90100/90101,
rather than sending a bare label.

**Cost: a fork of a 1347-line script**, which can drift from `qs/`. Acceptable
while both versions must exist; it should converge when v1 is retired.

**Still hardcoded in sitB and not yet addressed:** `[TEXTURE]`, `[FACES]` and
`[SECURITY]` in the `[ADJUST]` submenu, gated on other plugins' presence. By the
same principle those belong to `[QS]faces` and `[QS]root-security`, which means
more forks or more registration calls. Not started.

## The HUD auto-attach chain, verified 2026-08-13

Took four wrong guesses before reading `quicky-hud/`. Written down so nobody
re-derives it:

```
seat  90060 (sitter arrived)   ─┐
seat  90070 (sitter list)      ─┴─►  hudadmin builds SITTERS
core  90097 (QSALIVE reply)    ────►  hudadmin sizes SITTERS from the count

hudadmin, in the 90070 handler:
    cfgAttachMode == "auto"        →  attachHUD(slot, avatar)
    cfgAttachMode == "menu"        →  only for someone in lHudWearers
                                      (the 90510 "Quicky-HUD" button
                                       triggers it there instead)

attachHUD  ──►  90280 QSPROP_ATTACH, LINK_THIS  ──►  [QS]prop rezzes + attaches
```

**`[QS]prop` is required.** hudadmin attaches nothing itself; it builds a
payload and hands it to prop, which owns the rezzing machinery. `LINK_THIS`
means prop must be in the same prim. This is a v1 dependency too, not something
v2 introduced, but it is invisible from the sitter side and cost a long hunt.

**What v2 had to fix to reach that point**, all confirmed necessary:

* `seat` emits **90070**. Without it hudadmin never finds the avatar in
  `SITTERS` and does not call `attachHUD` at all.
* `core` **announces** QSALIVE instead of only answering probes, because
  hudadmin probes at its own `state_entry` and sizes `SITTERS` from the reply.
* `core` and `seat` watch `qs:meta:0` via `linkset_data`, because v1's `boot`
  signals nothing when it finishes and they previously read the schema once and
  never again.

**Remaining gates inside hudadmin**, if an attach still fails: the licence check
(`isLicensed`), the HUD object being present in the furniture inventory
(`findObjectByPrefix`), and the six-seat cap.

## Pose position accuracy is not something single-prim seating will fix

Raised 2026-08-13, while weighing whether to chase a remaining position
deviation now or let the single-prim work absorb it. It will not absorb it, and
the reason is worth writing down because the question will come back.

AVpos positions are authored **relative to the seat prim**. With one seat prim
per avatar that frame differs per seat; with everyone on a single prim there is
one frame for all of them. An existing notecard fed to single-prim seating would
therefore place every seat but one wrongly. That is precisely why the two modes
coexist (DESIGN.md §10): furniture that ships seat prims keeps the classic
binding.

So the classic mode has to be correct **on its own terms**, because it is the
one carrying every product already sold. If v2 places poses even slightly
differently from v1, a customer updating sees every pose in every piece of
furniture shift. That is the drop-in promise, not a detail.

The most recent suspect was `resolve_bindings`, which decides which prim a seat
is measured against and had three rules wrong against v1 (seat 0.16). Whether
anything remains after that is unmeasured.

## Pose position accuracy: resolved 2026-08-13

Verified side by side against v1 on the same furniture, same avatar, same pose,
with `qs2/test/zprobe.lsl` in each copy. v2 now reports what v1 reports:

```
avatar Z 0.259000   prim Z 0.000000   target Z -0.091000
```

Two separate defects, found in that order:

1. **The sit-target compensation had been removed** on a wrong reading. Restored
   (seat 0.17). Note that the measurement did NOT show this changing the avatar's
   position - both engines placed the link identically with different targets -
   so this was faithfulness, not the visible bug.
2. **The pose frame was the seat's prim instead of the script's prim**
   (seat 0.18). This was the visible bug. Measured error on a seat bound to
   prim 2: `0.259000 - 0.136377 = 0.122623`, exactly that prim's own local Z.
   Constant per seat, identical for every pose on it, and **exactly zero for
   whichever seat sits on the script's prim** - which is why the first
   measurement, taken on prim 1, showed no difference at all.

Method worth repeating: a passive probe in BOTH copies reporting the same field.
Five rounds of reading code did not find it, because every number either engine
reported about itself was correct.

### Still open from the same pass

Two divergences found while diffing the Z paths, neither fixed:

- **The RAM tier of personal offsets is not read.** `[QS]offset` parks offsets in
  RAM when LSD is at its floor and pushes them over 90260; `core` does not
  implement that wire (stated at core.lsl's capability list). Such an offset is
  silently zero in v2. Only bites on a full LSD, and then invisibly.
- **The nudge ignores `REFERENCE`.** v1 divides the delta by `llGetLocalRot()` or
  `llGetRot()` depending on cfg field 9; `menu` adds the raw axis delta. On a
  rotated prim a Z press moves in a different direction and X/Y presses leak into
  Z. The field is parsed in boot and read nowhere.

## The couple-join, resolved 2026-08-14

Wiretapped on the v1 copy: the join everybody attributed to the base engine is
a PLUGIN broadcasting `90000 "Nice" id=""` right after the second sitter's HUD
attaches. The base scripts play solos in v1 too, exactly as the code reads. The
lesson generalises: **the plugin layer drives poses over the stock 90000 wire**
(root-RLV's WAITPOSE/DOMPOSE, the QuickyHUD SYNC, third-party plugins), and a
v2 that does not answer it silently loses whatever those plugins do.

core answers 90000/90010 since 0.12, with v1's id semantics. Confirmed working
in-world on the single-prim build: second sitter arrives, plugin broadcasts,
both couple.

In the same investigation, three more wrong-avatar bugs of one shared shape
were found and fixed: seat_start (0.20) and seat_stop (0.22) checked the
permission MASK but not the HOLDER, animating or stopping the wrong avatar
whenever a grant was not synchronous - which single-prim arrivals, seated
without a sit target, reliably are. Both park misses and retry them in
run_time_permissions, which is a fallback only.

Sit-memory shipped alongside (core 0.11 / seat 0.21): qs:cur is written for
empty channels on a SYNC, start_default consults it, it survives individual
stand-ups, and core clears it on the last vacancy gated on DFLT.

Follow-up, same session: the ETYPE-style revert listed as missing turns out to
ride the same wire. When one of the couple stands, the remaining sitter drops
back to their solo pose in-world - the plugin layer reacts to the departure and
broadcasts the solo over 90000, and core now answers it. Nothing was built for
it; answering one wire restored the whole behaviour family. Do not implement a
core-side revert on top, it would fire twice.

## The offset saga, resolved 2026-08-14

Personal offsets now save, apply on sit, and survive re-sits, verified
in-world. It took four distinct defects stacked on top of each other, which is
why every single fix "changed nothing" until the last one landed:

1. **core+offset merge shipped while the HUD saved under a garbage key.**
   hudproxy's pose cache ("p" in its sitter JSON) was empty, so its arrow path
   saved offsets under the literal JSON_INVALID character. Its own lookups used
   the same wrong key, which made the HUD internally consistent and the bug
   invisible from its side.
2. **v2's 90045 was wrong in every field hudproxy builds its tables from**:
   empty sequence field, non-slot-indexed roster, one message instead of one
   per participating seat. Fixed to be field-faithful (core 0.16).
3. **Stale hudproxy session state.** hudproxy was never reset across weeks of
   engine swapping and carried sitter entries and slot mappings from dead
   tests. An in-world script reset of the HUD scripts is part of any engine
   swap from now on - customers get this automatically via the installer.
4. **Ghost plays on empty channels.** The 90000 broadcast made core play empty
   channels in full, including 90045 with an EMPTY id, polluting hudproxy's
   tables with empty keys. v1 gates all emission on a present sitter; core does
   now too (0.17), and empty channels only record qs:cur.

core 0.17 also purges the JSON_INVALID-named QSO entries once at state_entry -
they were the jump targets whenever hudproxy's cache went empty again.

Method note for the next person: the wiretap plus logging BOTH ends of the
store (save key and lookup key, bracketed) is what cracked it. Five rounds of
code reading found nothing because three parties (core, hudproxy, the attached
HUD) each looked internally consistent.

## Priorities as of 2026-08-14

Access gating is DEFERRED by decision: nothing ships yet, so the root-security
handoff stays on the pre-release checklist instead of the build queue. Do not
re-flag it as the top gap until a release is actually planned.

Build queue: **stage 2 (ITEM, DESIGN SS11)** is next. Behind it, unchanged:
REFERENCE on the nudge, the menu leftovers (MTYPE/ETYPE, seat picker, swap
dialog), and the deferred SEQUENCE/KFM/camera set. The two untested memory
cases (brief stand-up rejoins the couple pose; full vacancy forgets) remain
cheap to verify whenever two avatars are logged in.

## Stage 2 (ITEM) in-world status, 2026-08-15

Working on the two-item test build (`#Sofa` two seats, `#Chair` one):

- `ITEM <name>` parsed, item table in `qs:item:<idx>`, SITTER numbering local
  to the item and remapped to a global channel (boot 0.03)
- prim addressed BY NAME: `#Sofa` binds the whole item to one prim, `#Sofa-1`
  one seat; legacy `#SET-slot` untouched; an unknown name warns (seat 0.25)
- a door is per prim, derived from "more than one seat bound here", so both
  build shapes coexist in one linkset (seat 0.24)
- with items declared, poses and offsets are measured from the ITEM's own prim,
  so a builder can move and rotate an item freely. Conditional on the ITEM line
  precisely because no existing notecard has one (seat 0.26)
- SYNC broadcast and pose-memory reset scoped to the item (core 0.18)
- item named in the dialog title, suppressed below two items (menu 0.18)
- **change item without standing up** (`> Sofa`), gender-aware seat pick, and a
  spoken refusal when the target item is full (seat 0.29, menu 0.20)

### Two defects worth remembering, both found by wire trace rather than reading

**A plugin broadcast wrote pose memory into empty items.** The stock 90000 P
fallback walked every channel; `start_entry` records `qs:cur`, so sitting on the
chair left a memory on both sofa seats and the next arrival there inherited it
instead of the notecard default. Recording is the couple-join mechanism and
belongs to the item-scoped S branch (core 0.20).

**The move ignored gender**, landing a male on the sofa's female seat and
playing her hidden default. Ordinary arrivals had gone through regender since
0.15. regender is deliberately not reused on the move path: it works by
swapping PRIM BINDINGS, which is right when somebody is physically on the wrong
prim and wrong for a move, where nobody moves physically (seat 0.29).

### The vehicle case is why the move exists

On a ship under way, standing up means going overboard. That ruled out an
earlier draft restricting cross-item moves to door prims, since ships are
exactly the builds with one prim per seat. Resolved without giving up the
self-healing occupancy model: the adopt pass gained one rule - an avatar
occupies exactly one seat, so a sit target naming somebody already recorded
elsewhere describes an empty seat. Classic seats are scanned free-then-adopt,
which also fixed an ordering hazard that predates the feature.

## seat is at the bytecode ceiling - DECIDE ON THE NEXT seat CHANGE

Measured 2026-08-15 on the item-test build (3 seats, 2 items), seat 0.32
with staged readings: **4378 bytes free at boot_up entry**, before any
boot work. The weight is compiled bytecode, not a boot transient and not
string literals (~2 KB total). A pose-start transient on a fuller build
can stack-heap-crash the script.

Immediate relief taken in 0.33: the dead QSS_SWAP handler + swap_seats
went (nothing sent 90414 since the seat-swap became the item move), and
the staged readings went with it. Measured on the same build: 2946 free
at ready (0.32) -> 5810 (0.33), +2.9 KB. Enough headroom for normal
operation; the decision below stays parked but is no longer urgent.

THE DECISION, parked by agreement until the next functional change to
seat, whichever comes first:

1. **A fifth script** (+64 KB headroom). Best cut: the door/arrival
   machinery (nearest_door, pick_seat, arm_door, door half of rescan) -
   newest subsystem, cleanest seam, and optional for classic builds. The
   alternative seam is the interaction set (NUDGE, MOVE, 90057).
2. **Diet in place**: 3-5 KB realistic, and the next feature starts the
   squeeze again.

Whoever touches seat next: re-measure first (one llGetFreeMemory print
at boot_up entry), numbers over guesses.

## boot cleanup: the [DUMP] pipeline moved out (0.05, 2026-08-16)

boot was the tightest script of the set and its parse transients ride on
the free rest - while the whole [DUMP] apparatus in it (readout
formatting, plugin cascade, watchdog, HTTP upload, QSDUMP discovery,
~300 lines) is creator-time only. It now lives in **[QS]dump 0.01**, an
authoring tool that ships and leaves with the adjuster:

- The only trigger is the adjuster's dialog (90098); hudproxy never
  sends it (verified across both repos), so finalised furniture had no
  dump path anyway.
- Self-removal on '/5 cleanup' via the existing QS_FINALIZE (90215)
  broadcast - no adjuster change needed.
- The wire is unchanged: 90098/90099/90020/90021/90022 and QSDUMP
  90094/90095 all as before, same prim.
- AUTOSYNC stayed in boot ON PURPOSE: hudadmin writes QPP_CFG:AUTOSYNC
  on end-user furniture and the timer fires the 90271 re-sync - that is
  runtime, not authoring. (The extraction proposal originally had it
  moving; the code said otherwise.)
- total_channels is re-derived from qs:meta:* at every dump start, so a
  re-seed between dumps cannot leave it stale.

Measured 2026-08-16 on the item-test build (Cached boot path): Mem=23412
free on 0.05, against ~7.2 KB before - the extraction bought ~16 KB.
boot went from tightest of the set to second-roomiest; the QS# card
extension (§11.1) has its byte budget. The parse path (fresh seed) was
not re-measured, but its transients ride on the same freed rest.
[QS]dump 0.02 itself: 37530 free at ready, roomiest of the set.

Free-memory table of the whole set, measured 2026-08-16/17 on the
item-test build (the ~18/20 KB figures quoted earlier for menu/core were
from the 0.16-era builds and are obsolete - menu in particular has since
grown the pad, items and the registry):

| script | free | note |
|---|---|---|
| dump 0.02 | 37530 | authoring-only |
| boot 0.05 | 23412 | after the dump extraction |
| core 0.21 | 12568 | |
| menu 0.34 | 8154 | second-tightest, watch on next growth |
| seat 0.33 | 5810 | tightest; split-or-diet parked, see above |

## The notecard is read five times over, and v2 should read it once

Found 2026-08-18 while looking for room in v1's `[QS]prop` (the answer
there was: none needed, it has 5680 free with 21 props). The detour
turned up something that belongs here instead.

In v1 **five** scripts open AVpos and walk it line by line, each picking
out its own directives: `boot` (poses, sitters, config), `faces`
(`ANIM`), `prop` (`PROP*`), `sequence` (`PLAY`/`LOOP`/`SAY`) and
`root-RLV` (`DOMPOSE`/`ONCAPTURE`/`HTEXT`/`BRAND`). `boot` even sees the
`PROP*` lines but only sets a self-check flag from them and stores
nothing, so `prop` reads the whole card again for the same lines.

This is inherited, not designed: in stock AVsitter every plugin parses
the notecard itself, and the QS forks stayed minimally invasive. v1
centralised the pose data into LSD and left the plugin directives where
stock had them.

What it costs, and why v2 is the place to fix it:

- **Boot time.** Every line is an async `dataserver` round trip, so a
  card of N lines costs 5N of them. On a large AVpos that dominates the
  boot, and boot stability is exactly why `llGetNotecardLineSync` was
  rejected (its NAK is load-dependent).
- **Bytecode.** Each of those five carries its own parser, roughly one
  to two KB, in scripts whose free memory is the recurring problem.

The v2 shape is the one `prop` already half-demonstrates: the seeder
parses once and writes a per-plugin LSD namespace (`qs:prop:*` exists
today), and the plugins read LSD instead of the card. One pass, one
parser. Since v2 rewrites the format anyway (DESIGN.md §4), the plugin
directives should be seeded the same way from the start rather than
retrofitted.

Deliberately NOT a v1 change: it is a new seed contract across five
scripts, and none of them is in trouble today.

## Attach props are not authorable in-world - v2 should fix that

Found 2026-08-20 during the prop2 work (v1 sitter repo). The in-world
authoring path creates world props only: the 90171/90173 handler in
`[QS]prop` hardcodes `prop_add(trig, 0, ...)` - type 0, always. PROP1
(auto-attach) and PROP2 (touch-attach) can only come from hand-written
notecard lines. Stock inheritance, present in `[QS]prop2` identically.

Today's workaround, documented in chat 2026-08-20: author as a world
prop, [SAVE], then hand-edit the dumped line (`PROP` -> `PROP1`, append
the attach point as field 6 - AVsitter's 40 names only, substring
match), re-save AVpos. Worn fit afterwards via QSSAVEWORN ([SAVE] while
attached, needs the objectadjust/[QS]object companion).

The v2 authoring surface should carry the type from the start:

- the add-prop flow asks World / Auto-attach / Touch-attach / Stay
  (types 0/1/2/3) before registering,
- attach types then ask for the point, ideally as a paged dialog over
  the 40 AVsitter names instead of free text - the bed-card audit found
  two silently-dead free-text points (`right forearm`,
  `right ring finger`),
- the add wire (v2's counterpart to 90171) carries `|type|point` in the
  payload.

Deliberately NOT a v1/prop2 change: it is adjuster-menu UI plus a wire
extension, and the hand-edit path works. Belongs to the qs2 adjuster
fork (see "the adjuster is forked into qs2" above).
