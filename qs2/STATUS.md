# QuickySitter v2 build status

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
