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
| `[QS]anim` | N, one per seat |

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

### Animator, 90400-90405

Specified in `[QS]anim.lsl`. Summary:

| Num | Name | Direction | msg | id |
|---|---|---|---|---|
| 90400 | `QSA_CENSUS` | seat → all | | |
| 90401 | `QSA_HELLO` | anim → seat | handle | |
| 90402 | `QSA_BIND` | seat → anim | handle | avatar |
| 90403 | `QSA_READY` | anim → seat | handle | avatar |
| 90404 | `QSA_PLAY` | seat → all | `h=anim\|h=anim` | |
| 90405 | `QSA_RELEASE` | seat → anim | handle | |

`QSA_PLAY` is one broadcast rather than one message per animator, so that every
participating animator calls `llStartAnimation` in the same sim frame. That is
the whole `SYNC` property.

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
places the sit targets and emits one `QSA_PLAY`. One hop, which is as much wire
as today's sitB to sitA.

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

**Sitting down.** `seat` sees `CHANGED_LINK` → writes `qs:occ` → `QSA_BIND` →
`QSA_READY` → `QSS_SEATED` → `core` resolves → `QSC_APPLY` → `seat` sets sit
targets → `QSA_PLAY`.

A `QSA_PLAY` arriving before `QSA_READY` is dropped by the animator, not queued.
`seat` must not emit it early.

**Changing pose.** `menu` → `QSC_REQUEST` → `core` resolves → `QSC_APPLY` →
`QSA_PLAY` + `QSC_PLAYING`.

**Standing up.** `seat` sees `CHANGED_LINK` → `QSA_RELEASE` → clears `qs:occ` →
`QSS_VACATED`. Permission and the animation are already gone by then, since both
are revoked on standup; the release is bookkeeping so the animator can be
reassigned.
