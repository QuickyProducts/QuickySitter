# QuickySitter link-message protocol additions

Stock AVsitter's link-message numbers are unchanged. This document covers the
**fork-specific** numbers QuickySitter adds on top — the 9026x range for
personal-offset traffic and 9009x for the `[DUMP]` streaming protocol.

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

## `[DUMP]` — entirely in `[QS]boot`

`[DUMP]` used to live in `[QS]adjuster.lsl`. Adjuster is the prim's busiest
script (menu state, helper-bar state, listen, HTTP upload, sitter tracking)
and the dump function plus its 90022 echo backlog Stack-Heap-Collisioned on
real configs after ~6 pose entries.

Ownership now lives entirely in [`[QS]boot.lsl`](./[QS]boot.lsl) — boot
writes the `qs:cfg` / `qs:sitter` / `qs:p:*` keys during seed, so reading
them back to dump is a natural fit, and boot is mostly idle after boot
completes. Both producer (streaming the LSD into 90022 messages) and
receiver (formatting them into AVpos lines, chat output, HTTP upload to
the AVsitter settings service) live there. Adjuster's involvement is
exactly one line: the `[DUMP]` dialog handler sends `90098` to kick the
chain.

| Num   | Direction                | `msg`             | `id` | Meaning |
|-------|--------------------------|-------------------|------|---------|
| 90098 | `[QS]adjuster` → `[QS]boot` | `(string)channel` | `""` | "Start streaming this channel's dump." Sent on `[DUMP]` for channel 0; boot's own 90021 cascade re-sends it for each subsequent channel. |
| 90099 | `[QS]boot` → self        | `(string)channel` | `""` | "Process the next pose entry for the channel currently being dumped." Self-trigger between ticks — gives boot's event loop a chance to drain queued 90022 echoes between iterations. |

State lives in two boot globals: `qs_dump_ch` (the channel being streamed,
`-1` when idle) and `qs_dump_pi` (next entry index). Only one channel streams
at a time.

`90021` and `90022` are stock-AVsitter numbers (not fork-specific) but their
**handlers** moved to boot along with the dump pipeline:

- `90021` (channel-done signal): boot probes plugin scripts (`[AV]prop` /
  `[AV]faces` / `[AV]camera`) for the current channel via 90020, advances to
  the next channel via 90098, or — when no more channels — calls `web(TRUE)`
  to flush the cache and shouts the upload URL to the owner.
- `90022` (one dump line): boot's handler does the format substitution
  (`S:P:` → `POSE`, `S:M:` → `MENU`, `{pose}<pos><rot>` formatted via
  `FormatFloat`, etc.) and pipes the result through `Readout_Say`. Sources
  are boot's own `qs_dump_start`/`qs_dump_tick` and the plugin scripts woken
  by the 90020 cascade.

## sitB's 90301 handler — payload-forward, no LSD re-read

`[QS]sitB.lsl`'s 90301 handler used to call `send_anim_info(FALSE)`, which
re-reads pos/rot from LSD via `qs_pose_data(ANIM_INDEX)`. Two race conditions
would intermittently snap the avatar back to the previously saved position
(observed roughly 1 in 5 `[HELPER] [SAVE]` clicks):

1. **LSD-read race.** `qs_save_pose_offset` writes LSD *after* the 90301 is
   queued. Normally the writer's event finishes before sitB processes the
   message, but timing made the read return the pre-write value occasionally.
2. **`ANIM_INDEX` mismatch.** `send_anim_info` uses `ANIM_INDEX` (the slot
   currently playing on this sitter), but the 90301 carries the *saved* slot.
   When they diverged — including transient `ANIM_INDEX = -1` after a 90045
   sync-conflict reset — sitB sent empty 90055s or data for a different pose,
   and sitA applied the wrong default.

The handler now forwards pos/rot **directly from the 90301 payload** to sitA,
avoiding both races, and only fires when `index == ANIM_INDEX` (the saved pose
is the one this sitter is playing). The anim sequence is still read from LSD
because saving doesn't change it.
