# QuickySitter link-message protocol additions

Stock AVsitter's link-message numbers are unchanged. This document covers the
**fork-specific** numbers QuickySitter adds on top — the 9026x range for
personal-offset traffic and 9009x for the `[DUMP]` streaming protocol.

## AVsitter compatibility matrix

Cross-reference with the [stock AVsitter2 link-message reference](https://github.com/AVsitter/AVsitter/blob/master/AVsitter2/avsitter2_link_message_reference.md).
QuickySitter aims to keep the contract that **plugin scripts** (`[AV]prop`,
`[AV]faces`, `[AV]camera`, `[AV]sequence`, `[AV]favs`) and **notecard
consumers** see identical to stock — drop a stock plugin into a QuickySitter
furniture and it should work unchanged.

### Stock numbers used unchanged

`90000`-`90014`, `90030` (SWAP), `90033`, `90045` (pose-played broadcast),
`90050`/`90051` (menu pose pick), `90055`/`90056` (anim info), `90057`
(helper move), `90060`/`90065`/`90070` (sit/unsit/permissions),
`90075`/`90076` (oldschool helper), `90100`/`90101` (menu choice),
`90150`-`90211`, `90230`, `90298`-`90300`, `90401`-`90500`. From a sender's
perspective the contracts match stock.

### Stock numbers whose **handler script** moved

| Num | Stock home | QuickySitter home | Why |
|-----|-----------|-------------------|-----|
| `90020` | sent to scripts asking for `[DUMP]` | sent **from `[QS]boot`** instead of adjuster | `[DUMP]` ownership moved to boot ([details below](#dump--entirely-in-qsboot)) |
| `90021` | handled by `[AV]adjuster` | handled by **`[QS]boot`** | same — boot owns the cascade |
| `90022` | handled by `[AV]adjuster` | handled by **`[QS]boot`** | same — boot owns the receiver |

Plugins still send `90022`/`90021` to `LINK_THIS` exactly like in stock; the
listener just lives in a different script in the same prim, so they don't
notice.

### Stock numbers with subtler semantic changes

| Num | Change |
|-----|--------|
| `90301` | sitB's handler is stricter: only refreshes the seated avatar when `index == ANIM_INDEX` (saved pose is the playing one), and forwards pos/rot **directly from the 90301 payload** instead of re-reading LSD. Sender contract (`name\|pos\|rot\|`) is unchanged. Stock plugins don't send 90301 — it was sitA→sitB internal — so this is invisible externally. See [§ sitB's 90301 handler](#sitbs-90301-handler--payload-forward-no-lsd-re-read). |

### Stock numbers no longer routed in QuickySitter

| Num | Status |
|-----|--------|
| `90302` ("sitA sends initial notecard settings to sitB") | Removed. sitB reads `qs:cfg:<ch>` from LSD directly in `state_entry` instead. Incoming 90302 is silently ignored. |
| `90020` → sitB | sitB is no longer a `[DUMP]` source (boot owns the dump). Incoming 90020 to sitB is silently ignored. |

### Fork-specific numbers (in stock-unused ranges)

| Num | Range neighbour | Use |
|-----|-----------------|-----|
| `90098` | between stock `90076` and `90100` | `[QS]adjuster` → `[QS]boot`: "start dump for channel" |
| `90099` | same | `[QS]boot` → self: dump tick |
| `90260` | between stock `90230` and `90298` | `[QS]offset` → `[QS]sitA`: push personal offset |
| `90261` | same | `[QS]sitA` → `[QS]offset`: request push |
| `90262` | same | `[QS]sitA` → `[QS]offset`: save personal offset |
| `90263` | same | `[QS]adjuster` → `[QS]sitA` + `[QS]offset`: drop stale customs after `[HELPER] [SAVE]` |

A stock-AVsitter plugin sending or receiving in these ranges would have
collided with whatever it's reserved for in stock — but the stock reference
shows these slots as unused, so we're safe.

### Compat direction

- **Stock plugin in QuickySitter furniture:** ✅ works unchanged.
- **QuickySitter scripts in stock-AVsitter furniture:** ❌ doesn't work without modification — sitA/sitB expect `qs:cfg`/`qs:sitter`/`qs:p:*` LSD keys that boot writes during seed; stock furniture has no `[QS]boot`. This is intentional, not a goal of the fork.

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
