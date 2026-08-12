# QuickySitter v2 link-message protocol, draft

**Status: draft.** Numbers in the 904xx block are provisional and not yet
reserved against `qs/PROTOCOL.md`. Companion to [DESIGN.md](DESIGN.md),
[FORMAT.md](FORMAT.md) and [REGISTRY.md](REGISTRY.md).

Written before the scripts so that four interoperating files share one contract
instead of inventing it four times.

## Scripts

| Script | Instances |
|---|---|
| `[QS]boot` | 1 |
| `[QS]core` | 1 |
| `[QS]seat` | 1 |
| `[QS]menu` | 1 |

**No per-seat script.** `seat` drives the animations itself; permission cycling
is synchronous and measured at 1.2 ms per seat (DESIGN.md §3). An earlier draft
of this document had `N x [QS]anim` and a 90400-90405 wire to talk to them.

## Addressing

Two layers, deliberately separate (DESIGN.md §7.5):

* **Names** are the storage and notecard layer: `<item>/<seat>`, for example
  `Bett/Links`. LSD keys use this.
* **Slot integers** are the wire layer, enumerated across all items in
  declaration order. Stock AVsitter plugins keep working because the legacy
  900xx messages still carry integers.

`[QS]seat` owns the mapping between the two and is the only script that needs
both.

## Static data in LSD

Written by `boot` from the notecard, read by everyone else. `boot` is the only
writer.

| Key | Value |
|---|---|
| `qs:i:count` | number of items |
| `qs:i:<n>` | `<name>\|<firstSeat>\|<seatCount>` |
| `qs:s:count` | number of seats, across all items |
| `qs:s:<n>` | `<name>\|<primName>\|<gender>\|<rlv>` |
| `qs:cfg:<item>` | item-scope tokens, packed (FORMAT.md §4) |
| `qs:cfg:verbose` | global verbosity floor, unchanged from v1 |

Seats are numbered globally in declaration order, so seat index **is** the wire
slot integer. `<primName>` is empty unless the seat carried an explicit `PRIM`
override; otherwise the seat takes the next prim named after its item.

Pose and menu keys are owned by `core` and `menu` and are specified with those
scripts.

## Shared state in LSD

Written by `seat`, read by anyone. Reading beats asking: it is what keeps the
`core` / `seat` split off the hot path.

| Key | Value |
|---|---|
| `qs:occ:<item>/<seat>` | occupant avatar key, absent when free |
| `qs:cur:<item>/<seat>` | pose id currently playing, absent when none |
| `qs:slot:<item>/<seat>` | wire slot integer for this seat |

## Messages

### Seat lifecycle, 90410-90414

| Num | Name | Direction | msg | id |
|---|---|---|---|---|
| 90410 | `QSS_OCCUPIED` | seat → all | `<item>/<seat>` | avatar |
| 90411 | `QSS_VACATED` | seat → all | `<item>/<seat>` | avatar |
| 90412 | `QSS_TOUCH` | seat → menu | `<item>` | toucher |
| 90413 | `QSS_SEATED` | seat → core | `<item>/<seat>` | avatar |
| 90414 | `QSS_SWAP` | menu → seat | `<item>/<seatA>\|<seatB>` | requester |

`QSS_OCCUPIED` and `QSS_VACATED` are broadcasts for plugins. `QSS_SEATED` is the
narrower one `core` acts on: permission has landed, pick and apply a start pose.

### Pose, 90420-90423

| Num | Name | Direction | msg | id |
|---|---|---|---|---|
| 90420 | `QSC_REQUEST` | menu → core | `<item>\|<poseId>` | requester |
| 90421 | `QSC_APPLY` | core → seat | `<seat>=<anim>=<pos>=<rot>` rows, `\|` separated | `<item>` |
| 90422 | `QSC_PLAYING` | core → all | `<item>\|<poseId>` | |
| 90423 | `QSC_RESYNC` | any → core | `<item>` | |

`QSC_APPLY` carries everything already resolved: which seats take part, which
animation each gets, and the final position and rotation after offsets. `seat`
places the sit targets, then acquires and starts every participating occupant in
that same handler. One hop, which is as much wire as today's sitB to sitA.

### Boot, 90430-90432

| Num | Name | Direction | msg | id |
|---|---|---|---|---|
| 90430 | `QSB_READY` | boot → all | | |
| 90431 | `QSB_RELOAD` | boot → all | | |
| 90432 | `QSB_WIPE` | boot → all | | |

### Menu registration, 90212 / 90216

Unchanged from v1 on purpose, see [REGISTRY.md](REGISTRY.md) §3. The receiver
moves from `sitB` to `menu`; the sender does not notice.

## Ordering contracts

**Sitting down.** `seat` sees `CHANGED_LINK` → writes `qs:occ` → `QSS_SEATED` →
`core` resolves → `QSC_APPLY` → `seat` sets sit targets, acquires, starts.

Nothing has to wait for a permission grant any more: it is taken at animation
time, not on sit.

**Changing pose.** `menu` → `QSC_REQUEST` → `core` resolves → `QSC_APPLY` +
`QSC_PLAYING`.

Inside `QSC_APPLY`, `seat` runs **two passes with one shared `llSleep(0.2)`**:
start every seat, sleep, then stop every old animation. The starts stay inside
one frame, which is the `SYNC` property, and the overlap is what stops anyone
dropping into their default pose for a frame. Per-avatar overlap, which is what
v1 does, would tear the loop apart in the middle.

**Standing up.** `seat` sees `CHANGED_LINK` → clears `qs:occ` → `QSS_VACATED`.
Permission and the animation are already gone by then, both being revoked on
standup, so the explicit stop only matters when a seat is freed while its
occupant is still sitting on it.
