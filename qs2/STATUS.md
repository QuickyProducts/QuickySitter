# QuickySitter v2 build status

## The plan, 2026-07-29

Built in LSL now, ported to SLua later (DESIGN.md banner). Two stages, so the
first one ships on its own.

### Stage 1 — drop-in replacement, nothing else changes

`sitA` + `sitB` (2N scripts) become `core` + `seat` + `menu` (3 singletons).
They read the **v1 LSD schema** that today's `boot` writes and speak the
existing 900xx wire, so the notecard, the plugins, the HUD and every other
script are untouched. A four seater goes from nine scripts to four.

Work, in order:

1. **Delete `[QS]anim`.** Permission cycling is measured (DESIGN.md §3), so the
   per-seat script never existed for a reason.
2. **`seat`** absorbs the animation driving: acquire and start every occupant in
   one handler, two passes with one shared sleep for a pose change.
3. **Re-point `seat`** at the v1 schema (`qs:cfg:<ch>`, `qs:sitter:<ch>`) instead
   of `qs:i` / `qs:s`.
4. **Re-point `core`** at `qs:p:<ch>:<i>`, and re-implement coupling as v1's
   `SYNC`-broadcast-by-name rather than a seat list read off a pose row. This is
   the largest single piece of rework.
5. **Re-point `menu`** at the `qs:nm` / `qs:nt` sidecar.
6. **Delete `[QS]boot`** from qs2. The v1 boot keeps its job.

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
| `core` | **Camera** (`llSetLinkCamera`, 90202) | absent entirely |
| `core` | **Gender** handling | `SEAT` parses a gender field, `boot` stores it, and nothing reads it. v1 picks animation variants by it. |
| `core` | **`SEQUENCE`** stepping and its timer path | parsed into `qs:x:*`, not consumed |
| `core` | **Keyframed motion** path in sit-target application | v1 pauses and resumes `llSetKeyframedMotion` around a pose change |
| `core` | Legacy 900xx emission for stock plugins | the compatibility promise of DESIGN.md §7.5 is not yet kept |
| `menu` | **HUD wire** (90100, 90101, 90271, 90299-90301) | absent entirely |
| `menu` | **Seat picker** and **swap dialog** | `seat` can swap; nothing asks it to |
| `menu` | `MTYPE` / `ETYPE` click modes, `llPassTouches` | touch always opens a menu today |
| `menu` | `[OPTIONS]` as a distinct node | registered entries land at the path they ask for, but the v1 `[OPTIONS]` grouping behaviour is not reproduced |
| `seat` | TP and region-restart resume detail | sit targets are replaced, occupants are not restored to their pose |
| `seat` | Pose re-application after a swap | rows and sit targets swap, the running animations do not follow |
| `boot` | `qs:boot:asset` key tracking | a notecard change resets on `CHANGED_INVENTORY` rather than on an asset-key change, so unrelated inventory changes also reset |
| `boot` | `LINKSETDATA_MEMFULL` handling and the storage-wipe dialog | v1 has both; v2 writes and hopes |
| `boot` | Loading progress (`llSetText`) | cosmetic, but a large notecard boots silently |
| all | `llSetMemoryLimit` | **deliberate.** The value must come from a measured worst case plus headroom (DESIGN.md open question 2). A limit guessed from the boot figure collides with the heap under load. |

## Parsed but consumed by nothing

`boot` stores these so no data is lost; no v2 script reads them yet.

`BUTTON`, `SEQUENCE`, `PROP1-3` (indexed under `qs:x:<item>:<tok>:<n>`), and the
single-valued `MTYPE`, `ETYPE`, `SWAP`, `SELECT`, `AMENU`, `ONSIT`, `TEXT`,
`ADJUST`, `DFLT`, `BRAND`, `WARN`, `KFM`, `HELPER`.

An earlier draft of the parser collapsed the repeatable ones into a single key
each, which silently kept only the last line of each kind. Fixed 2026-07-29.

## Not started

The prop subsystem, the faces plugin, RLV, the `[DUMP]` path, and the web
converter. `[QS]offset` still addresses by slot and needs the v2 address.

---

## Suggested order

1. Compile the five scripts and fix what the compiler finds. Nothing below is
   worth doing before that.
2. `[QS]anim` alone in a prim for the DESIGN.md question 1 number.
3. Access gating in `core`. It is the gap with the worst failure mode.
4. Gender, then camera, then the HUD wire.
5. Everything else.

## Found while re-pointing at the v1 schema

**`GENDERS` steers seat assignment, not animation choice.** An earlier v2 draft
had per-gender animation variants (`seat=animM/animF`) in the pose row. No such
thing exists. v1 uses the sitter's body-shape gender to pick *which free seat*
they land on ([sitA.lsl:1334]), falling back to a seat marked `-1`. That is a
`seat` concern and it is **not implemented yet**; right now an avatar keeps
whichever prim they sat on.

**A label is not a pose identity, and the v1 wire already knew that.** `menu`
must send `core` an entry *index*, not a label. Two `P` entries in different
channels with the same name are independent poses, and the "Lalou" notecard has
three such pairs including the default sit pose.

**Still missing in `core`:** `SEQUENCE` stepping, the keyframed-motion
pause/resume around a pose change, and camera. v1 drives the camera from the
notecard through `[AV]camera` rather than from the pose entry, so it needs its
own look.

**Still missing in `seat`:** gender-based seat assignment (above), and the
`llUnSit` access gate that v1 runs in `sitB`'s `changed()`.

## Who takes over the adjuster's jobs

**Nobody: `[QS]adjuster` keeps them.** It is already a separate script, already
authoring-only, already removed by `/5 cleanup`, and it writes straight to
`qs:p:<ch>:<i>`, which v2 reads unchanged. That is exactly the shape the
section-2 principle asks for, so it is left alone.

The question is the other way round: **what v2 has to provide for it.**

| Provided | Where |
|---|---|
| `[OPTIONS]` submenu, filled by 90212 | `menu`, done |
| `[ADJUST]` submenu, filled by 90213, dropped by 90216 | `menu`, done |
| Both doors shown at the root only when something is behind them | `menu`, done, mirrors v1's self-show |
| `qs:p` writes landing where the engine reads | free: same schema |

Not a sitter concern at all: `90215` `QS_FINALIZE` goes to creator-only plugins
and `90266` goes to hudproxy. Neither passes through the seat engine.

**The hole that is left: the end-user personal-offset UI.** v1 splits it across
`sitB`'s `adjust_dialog()` and `sitA`'s `adjust_pose_menu()` with the
90260/90262/90265 wire, roughly 300 lines, and in v2 it currently has no home.
Two options, neither taken yet:

* **`menu` hosts it**, which is where `sitB` had it. Simplest, restores v1
  behaviour exactly, costs `menu` the 300 lines back.
* **`[QS]offset` hosts it**, which owns the data already. Cleaner, and it is
  what DESIGN.md §6.5 proposes, but that plugin has no dialog code today.
