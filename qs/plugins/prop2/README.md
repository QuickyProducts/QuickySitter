# prop2 - alternative prop engine (wire v2)

Creator opt-in replacement for the prop subsystem. Ships in the box
next to the standard scripts; it is NOT an update and is never pushed
onto existing furniture.

| Where | Standard | This pair |
|-------|----------|-----------|
| Furniture prim | `[QS]prop` | `[QS]prop2` (exactly one of the two) |
| Prop root prim | `[AV]object` + optional `[QS]objectadjust` | `[QS]object` (alone) |

## Why switch

- Up to **1024 props** per AVpos (standard wire caps at 100 - a stock
  `[AV]object` decoding limit, not a memory limit).
- Props obey only the furniture that rezzed them: two furnitures
  colliding on one random channel can no longer derez each other's
  props or overwrite each other's saved positions.
- A script reset or update push while props are out no longer strands
  them in the region - the new furniture life sweeps the old channel.
- One prop-side script instead of two, with a memory limit set: a
  rezzed prop bills a fraction of the parcel script memory the stock
  pair does.

## How to switch

1. Replace `[QS]prop` with `[QS]prop2` in the furniture prim.
2. Put `[QS]object` into every prop object's root prim and remove the
   stock `[AV]object` / `[QS]objectadjust` pair there.
3. Add the line `PROP2 ON` to AVpos, above the first PROP line.

Steps 1 and 2 alone (without the AVpos line) already run on the stock
wire with the hardening active - that is the supported mixed state
while you migrate prop objects one by one. The `PROP2 ON` line is the
final switch and requires step 2 to be COMPLETE: stock `[AV]object`
cannot decode the v2 rez parameter and sits inert.

`[QS]object` must be the in-world compiled copy from the box (it is
compiled under the QuickyProducts experience for no-dialog temp-attach;
a self-compiled copy falls back to a permission dialog).

## Migration helper: [QS]propRezzer

Drop `[QS]propRezzer` into the furniture prim for the duration of the
migration (remove it afterwards). `/5 rezall` rezzes every inventory
object once - deduplicated, so a card with 88 PROP lines and 26
distinct objects rezzes 26 copies - on a grid 1.5 m above the
furniture, DORMANT (rez parameter 0: no listen, no attach, no
timeout), ready to be opened for the script swap. A chat manifest
names each object with its prop type, attach point and grid slot;
`/5 proplist` prints the manifest without rezzing. Taking the edited
copies back and replacing the inventory originals stays manual, and
so does removing leftovers - dormant props hear no cleanup command.
Ctrl+Alt+T in the viewer highlights the invisible ones.

After swapping, the wire-2 handshake watchdog is the acceptance test:
set `PROP2 ON`, click through the poses, and every prop still missing
`[QS]object` reports itself by name within ten seconds.
