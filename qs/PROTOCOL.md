# QuickySitter link-message protocol additions

Stock AVsitter's link-message numbers are unchanged. This document covers the
**fork-specific** numbers QuickySitter adds on top — the 9026x range for
personal-offset traffic and 9009x for the `[DUMP]` streaming protocol.

## AVsitter compatibility matrix

Cross-reference with the stock AVsitter2 link-message reference vendored
in [`avstock/avsitter2_link_message_reference.md`](../avstock/avsitter2_link_message_reference.md)
(pinned to a specific upstream commit — see [`avstock/README.md`](../avstock/README.md)
for the SHA and how to bump it).
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
| `90096` | between stock `90076` and `90100` | plugin → `[QS]sitA`: QSALIVE presence probe |
| `90097` | same | `[QS]sitA` (slot 0) → plugin: QSALIVE reply / boot-announce |
| `90098` | same | `[QS]adjuster` → `[QS]boot`: "start dump for channel" |
| `90099` | same | `[QS]boot` → self: dump tick |
| `90260` | between stock `90230` and `90298` | `[QS]offset` → `[QS]sitA`: push personal offset |
| `90261` | same | `[QS]sitA` → `[QS]offset`: request push |
| `90262` | same | `[QS]sitA` → `[QS]offset`: save personal offset |
| `90263` | same | `[QS]adjuster` → `[QS]sitA` + `[QS]offset`: drop stale customs after `[HELPER] [SAVE]` |
| `90270` | same | `[QS]sitA` → companion-anim plugins: SYNC-pose Re-Sync tick (see [§ Re-Sync broadcast](#re-sync-broadcast--90270)) |

A stock-AVsitter plugin sending or receiving in these ranges would have
collided with whatever it's reserved for in stock — but the stock reference
shows these slots as unused, so we're safe.

### Compat direction

- **Stock plugin in QuickySitter furniture:** ✅ works unchanged.
- **QuickySitter scripts in stock-AVsitter furniture:** ❌ doesn't work without modification — sitA/sitB expect `qs:cfg`/`qs:sitter`/`qs:p:*` LSD keys that boot writes during seed; stock furniture has no `[QS]boot`. This is intentional, not a goal of the fork.

## QSALIVE — presence probe for plugin discovery

Stock AVsitter plugins detect "is sitA in this prim?" and "how many sitter
slots?" with `llGetInventoryType("[AV]sitA")` and a
`while (llGetInventoryType("[AV]sitA " + (string)i) == INVENTORY_SCRIPT)`
loop. QuickySitter's main script is `[QS]sitA` (see [`qs/[QS]root.lsl`](./[QS]root.lsl)
and [`qs/[QS]select.lsl`](./[QS]select.lsl) for why we forked the name),
so plugins that probe only the stock name see `INVENTORY_NONE` and bail
even though sitA is sitting right next to them.

Plugins that want first-class QuickySitter support can use the QSALIVE
link-message handshake instead. It's modeled on the stock 90201/90202
plugin-discovery probe but in the opposite direction (sitA is the
*responder*, not the asker).

| Num    | Direction              | `msg`                                    | `id` | Meaning |
|--------|------------------------|------------------------------------------|------|---------|
| 90096  | plugin → `[QS]sitA`    | `""`                                     | `""` | "Anyone here? Identify yourself." |
| 90097  | `[QS]sitA` → plugin    | `<product>\|<ver>\|<sitters>\|<caps>`    | `""` | Presence reply. Also broadcast unsolicited from slot 0's `state_entry` once boot finishes. |

**Reply payload** (pipe-delimited, parse with `llParseString2List` — see
[MEMORY.md note on KeepNulls](../../.claude/projects/.../feedback_lsl_parse_nulls.md)):

| Field | Content                                                              |
|-------|----------------------------------------------------------------------|
| 0     | Product token. Always `QuickySitter` for this fork. Future forks (or upstream) may set their own.|
| 1     | Version string. Mirrors the global `version` in [`[QS]sitA.lsl`](./[QS]sitA.lsl). |
| 2     | Sitter-slot count, identical to `get_number_of_scripts()`. Plugins can use this directly instead of running the legacy inventory loop. |
| 3     | Capability CSV. Substring-match for individual features. Initial set: `customs90260` (personal-offset cache, see [§ Personal pose offsets](#personal-pose-offsets--qsoffset--qssita)), `dump90098` (DUMP cascade, see [§ DUMP](#dump--entirely-in-qsboot)), `offsetlsd_v1` (offset.lsl ≥ 0.04 supports persistent LSD storage at `QSO:<short>:<pose>`; gates plugin migrations from older volatile-only releases). |

### Who answers, when, and on which link

- Only the **slot-0** `[QS]sitA` answers `90096` (`if (SCRIPT_CHANNEL == 0)`),
  so a multi-sitter prim sends exactly one `90097` per probe — plugins
  don't have to deduplicate.
- Both probe and reply use `LINK_SET` so plugins in child prims see
  them.
- On boot, slot 0 emits one unsolicited `90097` at the end of
  `state_entry` (after `boot_done = TRUE`). Plugins that came up before
  sitA missed any earlier replies; this lets them latch onto QS without
  having to send a probe themselves. Plugins that come up *after* sitA
  still get an answer via the normal probe path.

### Adoption pattern for plugin authors

```lsl
integer QS_ALIVE   = FALSE;
integer QS_SITTERS = 0;

probe_qs()
{
    llMessageLinked(LINK_SET, 90096, "", "");
    llSetTimerEvent(1.0); // fallback after 1s
}

default
{
    state_entry()
    {
        probe_qs();
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == 90097)
        {
            // llParseString2List, NOT KeepNulls — see qs/MEMORY note.
            list d = llParseString2List(msg, ["|"], []);
            QS_ALIVE   = (llList2String(d, 0) == "QuickySitter");
            QS_SITTERS = (integer)llList2String(d, 2);
            llSetTimerEvent(0.0);
            // ... wire up plugin state knowing sitA is here ...
        }
    }

    timer()
    {
        llSetTimerEvent(0.0);
        if (!QS_ALIVE)
        {
            // Fallback: stock inventory probe. Try the QS name first
            // (cheap), then the AV name for backward compat with stock
            // furniture.
            if (llGetInventoryType("[QS]sitA") == INVENTORY_SCRIPT
             || llGetInventoryType("[AV]sitA") == INVENTORY_SCRIPT)
            {
                // ... legacy slot-count loop here ...
            }
        }
    }
}
```

`changed(CHANGED_INVENTORY)` is a good place to re-run `probe_qs()` if
the plugin needs to react to sitter-count changes — slot 0 will re-emit
`90097` on its own reset (state_entry runs again), but the plugin can
also pull on demand.

## Personal pose offsets — `[QS]offset` ↔ `[QS]sitA`

QuickySitter moves personal (per-user, per-slot) pose offsets out of
`[AV]sitA`'s inline `CUSTOMS` list into a dedicated [`[QS]offset`](./[QS]offset.lsl)
script with a two-tier store. The slot is in the key because SYNC couple
poses share a pose name across multiple slots, but each slot has its own
DEFAULT (sit-target offset relative to root); a flat (user, pose) key
would let a save on slot 1 overwrite a save on slot 0 for the same pose
name.

* **LSD `QSO:<short>:<slot>:<pose>`** (≥ 0.09) — persistent across script
  reset and re-rez. Used while LSD has room for at least 200 more entries
  past the `QPP_CFG:RESERVE` budget that hudprop sets. Keys are written
  unprotected: the proprietary QuickyHUD `LSD_PASS` is intentionally
  absent from this MPL-licensed source; `QPP_CFG:*` keys (license,
  adjustmode, reserve) stay protected on hudproxy/hudprop's side. Pose
  offsets aren't security-sensitive, so unprotected reads/writes are
  acceptable.
* **RAM `CUSTOMS` list** — volatile fallback, LRU-evicted at 200 entries.
  Used when LSD is too tight, or in legacy / stock AVsitter setups where
  there's no `QPP_CFG:RESERVE` to honor. Stride is 5: `[pose, short,
  slot, pos, rot]` per entry.

`save_offset` writes to LSD when `lsdHasRoom()` returns TRUE, otherwise
to CUSTOMS. `push_customs_for(sitter, slot)` enumerates **both** stores
and emits one `90260` per matching (user_short, slot) entry — the slot
filter ensures each sitA's per-instance MY_CUSTOMS only ever contains
its own slot's data, so `apply_current_anim`'s lookup needs no slot
awareness on the receiver side. LSD entries win when the same pose
appears in both — shouldn't happen in practice, but the dedupe protects
against stale RAM after `lsdHasRoom()` flips at runtime.

The QSALIVE `offsetlsd_v1` capability bit advertised by `[QS]sitA` was
introduced with the LSD tier in 0.04 (flat key) and remains valid for
0.09's per-slot keys. Hudproxy's one-shot QPP→QSO migration falls back
to `slot 0` for legacy entries that have no slot info; users updating
the no-mod HUD typically clear their offset storage before the upgrade,
so this is rarely traversed in practice.

The four numbers below carry the link-message traffic.

| Num    | Direction                  | `msg`                | `id`              | Meaning |
|--------|----------------------------|----------------------|-------------------|---------|
| 90260  | `[QS]offset` → `[QS]sitA`  | `pose_name\|pos\|rot` | sitter UUID       | "Apply this personal offset for the avatar on this sitter slot." Sent once per matching cache entry when a sitter sits. The slot was already filtered by 90261's request so the payload doesn't repeat it. |
| 90261  | `[QS]sitA` → `[QS]offset`  | `(string)slot`       | sitter UUID       | "Push every cached offset for this (sitter, slot) pair to me." Sent on sit and on hudproxy pose change. |
| 90262  | `[QS]sitA` → `[QS]offset`  | `slot\|pose_name\|pos\|rot` | sitter UUID | "Save this offset for (sitter, slot, pose)." Magic name `M#T!` is the all-poses offset used by `[SAVE ALL]`; each slot can have its own M#T!. Hudproxy listens on the same broadcast (LINK_THIS) to mirror the new offset into its JSON state when the slot matches the active sitter's slot. |
| 90263  | `[QS]adjuster` → `[QS]sitA` + `[QS]offset` | `(string)sitter_slot` | pose_name (as `key`) | "The creator just overwrote this pose's default on this slot via `[HELPER] [SAVE]`. Drop every pose-specific entry on this slot that matches — `M#T!` survives, and other slots keep their offsets." |
| 90264  | hudproxy → `[QS]offset`    | `""`                 | ignored           | "Wipe ALL personal offsets — both LSD `QSO:*` and RAM `CUSTOMS`." Triggered by the HUD settings menu's `CLEAR offset storage` confirm. Matches the `CHANGED_OWNER` cleanup behavior. |

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

### 90260 late-arrival re-apply

`run_time_permissions` in `[QS]sitA.lsl` fires `90261` (request customs push)
and `90000` (play pose) back-to-back when an avatar sits. The two messages
race two independent round-trips:

* `90261` → `[QS]offset` → `90260` (one per matching CUSTOMS entry)
* `90000` → `[QS]sitB`   → `90055` → `apply_current_anim` reads `MY_CUSTOMS`

If `90055` wins, `apply_current_anim` runs against an empty `MY_CUSTOMS`
and lands the avatar on `DEFAULT_POSITION` even though the offset push is
on its way. The 90260 then arrives, populates `MY_CUSTOMS`, and nobody
re-applies — the saved offset is silently ignored every time the user
loses the race. This is observable as `[Adjust][SAVE]` "doing nothing"
across stand/re-sit cycles.

`[QS]sitA.lsl`'s 90260 handler resolves this by re-applying the offset
inside the handler when CURRENT still equals DEFAULT (i.e., apply_current_anim
already ran but didn't see our entry). It uses the same selection rule as
apply_current_anim — specific pose wins over `M#T!`. Mid-session adjustments
(`X+/Y+/Z+` from the `[Adjust]` dialog) are not overridden because they shift
CURRENT away from DEFAULT, breaking the equality check.

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

## Re-Sync broadcast — 90270

For SYNC poses (multi-avatar synchronized loops, name *without* `P:` prefix),
`[QS]sitA.lsl` periodically restarts the running animation to fight
Interest-List drift between viewers — the well-known
"camera-zoom-causes-desync" problem in SL where a viewer that culled an
avatar restarts the looped anim locally at `t=0` on re-acquisition while
other viewers keep their original timeline. See
[`TESTPLAN.md`](./TESTPLAN.md) for the failure-mode analysis and Test Cases
TC-021/TC-022.

| Num   | Direction                                | `msg`              | `id`        | Meaning |
|-------|------------------------------------------|--------------------|-------------|---------|
| 90270 | `[QS]sitA` → companion-anim plugins      | `CURRENT_POSE_NAME` | sitter UUID | "Re-sync your loop for this sitter — I just did Stop+Start on the body anim." |

### Mechanism — main-anim Stop+Start

`[QS]sitA` periodically does a brief `Stop` → short `Sleep` → `Start`
cycle on the **main pose animation**. Loop phase is determined
viewer-locally at the `Start` event, so this is the only mechanism
that actually re-phases the running loop on every viewer in sync.

The Sleep is intentionally short (50 ms): long enough to cross a
Sim-frame boundary so the two ops aren't coalesced into a no-op
(Sim runs at ~45 Hz / 22 ms per frame), short enough that most
viewers' next render frame falls outside the gap.

#### Tested-and-rejected: dummy-anim refresh

A previous iteration (sitA 0.17–0.19) used a low-priority dummy
animation named `SYNC`: brief `Start` → `Sleep` → `Stop` of the
dummy, leaving the main pose anim untouched. The theory (from SL
folklore around external sync tools) was that the dummy cycle would
force the viewer to push an animation-state update, re-evaluating the
running main loop's phase along the way.

In multi-avatar testing the trick refreshes skeleton state but does
**not** re-phase the main loop — the main animation never leaves the
viewer's active set, so its local time-zero is preserved and drift
continues. Architecturally, only direct Stop+Start of the loop in
question can re-phase it. The dummy approach is documented here so
the next person who reads the trick on an SL forum and considers
re-introducing it has the empirical result.

### Trigger architecture

Each `[QS]sitA` instance runs its own re-sync timer aligned to a shared
**wall-clock anchor** (multiples of `RESYNC_INTERVAL` since `llGetTime`
epoch). Without any leader-election or root-broadcast coordination, all
sitA instances in the same linkset compute the same next-anchor and fire
their timers in the same Sim frame — viewers receive every sitter's
Stop+Start in roughly the same network frame, snapping the loops back into
phase together. This is robust against an absent `[QS]root`, sitter
churn, and individual sitA resets.

Re-sync only fires for **single-frame SYNC poses** (`SEQUENCE_LEN <= 2`
and pose name not starting with `P:`). Multi-frame sequences keep the
existing sequencing timer to avoid the
re-sync-during-frame-wechsel race (TESTPLAN TC-023). POSE-type poses
(prefixed `P:`) are solo by convention and don't need re-sync.

Hardcoded constants in `[QS]sitA.lsl`:

- `RESYNC_INTERVAL` = 30.0 s — period between ticks
- `RESYNC_DELAY` = 0.05 s — gap between Stop and Start (≥ 1 Sim frame
  to defeat coalescing, < 1 viewer-render frame at 30 FPS to minimise
  the visible gap)
- `RESYNC_PLAY_FIRST` = 2.0 s — earliest re-sync after pose apply

### What 90270 means for plugin authors

Companion-anim plugins (`[AV]faces`, `[AV]prop`, custom face/prop scripts)
should listen for `90270` and, **for the matching `id` (sitter UUID)**,
do their own Stop+Start cycle on whatever loop they currently play, so
their loop phase resets in the same Sim frame as the body. The
`msg` payload (`CURRENT_POSE_NAME`) is provided as context — plugins
can ignore it, or use it to verify the pose hasn't changed mid-tick.

A plugin that ignores 90270 still works correctly; its companion anims
just won't re-sync, which manifests as face/prop drift relative to the
body. Body-only re-sync is the minimum viable feature.

### Disabling per-furniture

Add `RESYNC OFF` to the AVpos notecard. `[QS]boot` parses this directive
into the `RESYNC` field (index 17) of `qs:cfg:<ch>` (see STORAGE.md);
`[QS]sitA` reads it on `state_entry`. Default when the directive is absent
is enabled. The dump pipeline emits `RESYNC OFF` only when explicitly
disabled, so dumps from default-enabled setups don't grow a new line.
