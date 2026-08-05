# qs/tools: creator-side utilities

Scripts a creator drops into a prim while building and removes before
handing the build out. They are not part of the running furniture: no
sitter depends on them, none of them publishes a `qs:alive:*` presence
flag, and `[QS]sitB` never renders a button for them.

Counterparts to the stock helpers in
[`avstock/Utilities/`](../../avstock/Utilities/). That directory is a
byte-identical pinned snapshot of upstream and must not be edited, so a
fork of one of those scripts lands here instead, under a `[QS]` name.

| Script | Upstream | Why it is forked |
|--------|----------|------------------|
| `[QS]AVpos-shifter.lsl` | `AVpos-shifter.lsl` | Uploads to the QuickySitter dump receiver instead of the retired avsitter.com page, warns that the AVpos notecard is only a seed on this fork, and survives a run instead of deleting itself. Full list in the file header. |

## The other upstream utilities

Not forked. `AVpos-generator` and `Anim-perm-checker` only walk prim
inventory, and `MLP-converter` only reads MLP notecards, so all three are
unaffected by where QuickySitter keeps its pose data. `Noob-detector`
posts to the same retired avsitter.com endpoint as the stock shifter did,
but nothing in the QuickySitter workflow uses it.

**`Missing-anim-finder` is not safe as-is.** It decides which animations
are unused by reading the AVpos notecard alone, then offers to delete
them. Poses added through `[NEW]` are written to `qs:p:<ch>:<i>` and
never reach the notecard, so on a piece that was built through the menus
their animations look unused and one click deletes them. Same root cause
as the shifter problem: on this fork the notecard is a seed, not the live
store. Run `[ADJUST]` > `[HELPER]` > `[DUMP]` into the notecard before
using it, or answer NO to the delete prompt. A fork that reads `qs:p:*`
directly is the proper fix and is not written yet.

## Finalization

Every script here subscribes to `QS_FINALIZE` (90215) and removes itself
when `[QS]adjuster` broadcasts it on `/5 cleanup`. That is the fork's
contract for creator-only tools, documented in
[`qs/PROTOCOL.md`](../PROTOCOL.md). A tool used in a prim that has no
`[QS]adjuster` in it never hears the broadcast and has to be deleted by
hand.
