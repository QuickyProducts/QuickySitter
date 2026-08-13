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
