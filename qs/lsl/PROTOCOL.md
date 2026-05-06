# QuickySitter link-message protocol additions

Stock AVsitter's link-message numbers are unchanged. This document covers the
**fork-specific** numbers QuickySitter adds on top, all in the 9026x range.

## Personal pose offsets — `[QS]offset` ↔ `[QS]sitA`

QuickySitter moves personal (per-user) pose offsets out of `[AV]sitA`'s inline
`CUSTOMS` list into a dedicated [`[QS]offset`](./[QS]offset.lsl) script with an
LRU cache. The four numbers below carry that traffic.

| Num    | Direction                  | `msg`                | `id`              | Meaning |
|--------|----------------------------|----------------------|-------------------|---------|
| 90260  | `[QS]offset` → `[QS]sitA`  | `pose_name\|pos\|rot` | sitter UUID       | "Apply this personal offset for the avatar on this sitter slot." Sent once per matching `CUSTOMS` entry when a sitter sits. |
| 90261  | `[QS]sitA` → `[QS]offset`  | `""`                 | sitter UUID       | "Push every cached offset for this sitter to me." Sent on sit. |
| 90262  | `[QS]sitA` → `[QS]offset`  | `pose_name\|pos\|rot` | sitter UUID       | "Save this offset to the cache." Magic name `M#T!` is the all-poses offset used by `[SAVE ALL]`. |
| 90263  | `[QS]adjuster` → `[QS]sitA` + `[QS]offset` | `(string)sitter_slot` | pose_name (as `key`) | "The creator just overwrote this pose's default via `[HELPER] [SAVE]`. Drop every pose-specific entry that matches — `M#T!` survives." |

### Why 90263 exists

In stock AVsitter, pressing `[SAVE]` in the helper-bar adjuster only updates
the pose default in memory; the currently seated avatar is **not** repositioned
live, so the stale `[pose, user_short]` CUSTOMS entries never get a chance to
re-apply on top of the new default.

QuickySitter's `[QS]sitB.lsl` 90301 handler (line 632) deliberately calls
`send_anim_info(FALSE)` so the seated avatar reflects the new default
immediately — better UX, but it routes through `apply_current_anim` in
`[QS]sitA.lsl`, which adds `MY_CUSTOMS[pose_name]` to the new default. Result:
visible "snap" by the old offset vector.

90263 is sent by `[QS]adjuster` **before** 90301 in the `[SAVE]` loop, so sitA
processes the customs eviction ahead of the 90055 chain that re-applies the
pose. The seated avatar lands on the helper-bar position; future re-sits start
from the new default with no carry-over offset (which would be relative to a
default that no longer exists).

`M#T!` (all-poses personal offset) is intentionally preserved — it isn't tied
to the saved pose name, and the user's intent ("I always sit X cm forward")
still applies after a default change.

### Senders & handlers

- Sent from: [`[QS]adjuster.lsl`](./[QS]adjuster.lsl) `[SAVE]` handler
- Handled in: [`[QS]sitA.lsl`](./[QS]sitA.lsl) (filtered on `SCRIPT_CHANNEL`)
  and [`[QS]offset.lsl`](./[QS]offset.lsl) (drops matching entries across all
  user_shorts)
