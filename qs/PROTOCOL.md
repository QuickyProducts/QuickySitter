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
| `90094` | between stock `90076` and `90100` | `[QS]boot` → all plugins: QSDUMP probe ("announce yourself if DUMP-capable") |
| `90095` | same | DUMP plugin → `[QS]boot`: QSDUMP hello (id = announcer's script name) |
| `90096` | same | plugin → `[QS]sitA`: QSALIVE presence probe |
| `90097` | same | `[QS]sitA` (slot 0) → plugin: QSALIVE reply / boot-announce |
| `90098` | same | `[QS]adjuster` → `[QS]boot`: "start dump for channel" |
| `90099` | same | `[QS]boot` → self: dump tick |
| `90260` | between stock `90230` and `90298` | `[QS]offset` → `[QS]sitA`: push personal offset |
| `90261` | same | `[QS]sitA` → `[QS]offset`: request push |
| `90262` | same | `[QS]sitA` → `[QS]offset`: save personal offset |
| `90263` | same | `[QS]adjuster` → `[QS]sitA` + `[QS]offset`: drop stale customs after `[HELPER] [SAVE]` |
| `90264` | same | hudproxy → `[QS]offset`: wipe ALL personal offsets (LSD `QSO:*` + RAM `CUSTOMS`) |
| `90265` | same | `[QS]offset` → all `[QS]sitA`: clear `RAM_OVERFLOW` (broadcast invalidation paired with 90264) |
| `90266` | same | `[QS]adjuster` → `hudproxy`: `"On"` / `"Off"` — flip QuickyHUD ADJUSTMODE remotely (sent by `[HELPER]`'s "Quicky HUD" branch and by `end_helper_mode` auto-Off) |
| `90271` | same | hudproxy / any in-prim source → `[QS]sitA`: SYNC-pose Re-Sync trigger (see [§ Re-Sync trigger](#re-sync-trigger--90271)) |
| `90280` | same | hudadmin / any in-prim source → `[QS]prop`: dynamic prop attach without notecard (see [§ QSPROP_ATTACH](#qsprop_attach--90280)) |

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

### Storage tiers (owned exclusively by `[QS]offset`)

* **LSD `QSO:<short>:<slot>:<pose>`** (≥ 0.09) — persistent across script
  reset and re-rez. Used while LSD has room for at least 200 more entries
  past the `QPP_CFG:RESERVE` budget that hudprop sets. Keys are written
  unprotected: the proprietary QuickyHUD `LSD_PASS` is intentionally
  absent from this MPL-licensed source; `QPP_CFG:*` keys (license,
  reserve, migration flag) stay protected on hudproxy/hudprop's side.
  Pose offsets aren't security-sensitive, so unprotected reads/writes
  are acceptable. **Exception:** `QPP_CFG:ADJUSTMODE` is unprotected by
  design — `[QS]adjuster` reads it (capability detection via
  `llLinksetDataFindKeys`, state read for sitA's `[STOP HELP]` relabel)
  and writes it via the 90266 link-message. hudproxy migrates the key
  on init (`migrateAdjustmodeToUnprotected`), idempotent.
* **RAM `CUSTOMS` list** — volatile overflow, LRU-evicted at 200 entries.
  Used when LSD is too tight (below the `LSD_MIN_FREE_POSES` floor +
  `QPP_CFG:RESERVE`), or in legacy / stock AVsitter setups where
  there's no reserve to honor. Stride is 5: `[pose, short, slot, pos,
  rot]` per entry.

### Single source of truth

`[QS]offset` is the **sole owner** of both tiers. `[QS]sitA` holds **no
authoritative copy** — it reads LSD directly for the LSD tier, and
mirrors only the RAM tier in a session-local list (`RAM_OVERFLOW`)
populated by 90260 push. The mirror is fully replaced/cleared on
sit-down (90261 request), CLEAR (90265 broadcast), and stand-up.

This eliminates the cache-coherence problem that the previous
`MY_CUSTOMS`-as-full-cache design had: any LSD mutation in
`[QS]offset` is automatically visible to `apply_current_anim`'s next
read, no invalidation broadcast needed for LSD-tier values. Only the
small RAM-tier subset has push-based invalidation, with three
well-defined events (90260 push for save, 90263 for adjuster overwrite,
90265 for full wipe).

### Read path in `[QS]sitA.apply_current_anim`

```
1. Build key = "QSO:" + llGetSubString(MY_SITTER, 0, 7) + ":"
              + (string)SCRIPT_CHANNEL + ":" + CURRENT_POSE_NAME
2. Read LSD at key. If non-empty → parse "<pos>|<rot>", apply, done.
3. Look up CURRENT_POSE_NAME in RAM_OVERFLOW. If found → apply, done.
4. Read LSD at "QSO:<short>:<slot>:M#T!". If non-empty → apply, done.
5. Look up "M#T!" in RAM_OVERFLOW. If found → apply, done.
6. No personal offset.
```

LSD reads are Mono hashmap lookups (~50 µs); the four-read worst case
stays well under one Sim frame. Pose-specific entries always win over
`M#T!` (the all-poses fallback), regardless of which tier they're in.

### Write path

`save_offset` writes to LSD when `lsdHasRoom()` returns TRUE,
otherwise to RAM `CUSTOMS`. When the write went to RAM (not LSD),
`save_offset` also fires `90260` to the originating sitA so its
`RAM_OVERFLOW` mirror stays in sync immediately — sitA wouldn't see
the value otherwise (it only direct-reads LSD).

`push_customs_for(sitter, slot)` (90261 handler) enumerates **only the
RAM tier** and emits one `90260` per matching (user_short, slot, pose)
entry. LSD entries are not pushed because sitA reads them directly on
demand. The slot filter in the lookup ensures each sitA's
`RAM_OVERFLOW` only ever contains its own slot's data.

### RAM-tier visibility — `QPP_CFG:RAM_TIER_COUNT`

`[QS]offset` writes the current `CUSTOMS` entry count to the
unprotected LSD key `QPP_CFG:RAM_TIER_COUNT` whenever the count
changes (save, drop, wipe, eviction). hudproxy reads this key in
`getStorageReport()` so the CLEAR-confirm dialog can show how many
offsets sit in RAM tier (i.e., would be lost on script reset). Empty
or "0" means none.

The QSALIVE `offsetlsd_v1` capability bit advertised by `[QS]sitA` was
introduced with the LSD tier in 0.04 (flat key) and remains valid for
0.09's per-slot keys. Hudproxy's one-shot QPP→QSO migration falls back
to `slot 0` for legacy entries that have no slot info; users updating
the no-mod HUD typically clear their offset storage before the upgrade,
so this is rarely traversed in practice.

The four numbers below carry the link-message traffic.

| Num    | Direction                  | `msg`                | `id`              | Meaning |
|--------|----------------------------|----------------------|-------------------|---------|
| 90260  | `[QS]offset` → `[QS]sitA`  | `pose_name\|pos\|rot` | sitter UUID       | "Mirror this RAM-tier personal offset into your `RAM_OVERFLOW`." Sent once per matching RAM-tier entry when a sitter sits (in response to 90261), and once per RAM-tier `save_offset` so the writer's sitA stays in sync immediately. **LSD-tier offsets are not pushed via 90260 anymore** — sitA reads `QSO:*` directly from LSD on demand. **ZERO/ZERO payload is the delete sentinel**: `save_offset` emits it whenever it removed an entry (user adjusted back to default and saved); sitA drops the matching `RAM_OVERFLOW` entry to prevent ghost-application after the underlying store was already cleared. |
| 90261  | `[QS]sitA` → `[QS]offset`  | `(string)slot`       | sitter UUID       | "Push every RAM-tier cached offset for this (sitter, slot) pair to me." Sent on sit and on hudproxy pose change. The push only enumerates `CUSTOMS` (RAM tier); `[QS]offset` does not scan LSD on this request. |
| 90262  | `[QS]sitA` → `[QS]offset`  | `slot\|pose_name\|pos\|rot` | sitter UUID | "Save this offset for (sitter, slot, pose)." Magic name `M#T!` is the all-poses offset used by `[SAVE ALL]`; each slot can have its own M#T!. Hudproxy listens on the same broadcast (LINK_THIS) to mirror the new offset into its JSON state when the slot matches the active sitter's slot. |
| 90263  | `[QS]adjuster` → `[QS]sitA` + `[QS]offset` | `(string)sitter_slot` | pose_name (as `key`) | "The creator just overwrote this pose's default on this slot via `[HELPER] [SAVE]`. Drop every pose-specific entry on this slot that matches — `M#T!` survives, and other slots keep their offsets." sitA-side: drops the matching `RAM_OVERFLOW` entry (no-op if it was an LSD-tier offset; that one gets dropped via `[QS]offset`'s LSD-side handler). |
| 90264  | hudproxy → `[QS]offset`    | `""`                 | ignored           | "Wipe ALL personal offsets — both LSD `QSO:*` and RAM `CUSTOMS`." Triggered by the HUD settings menu's `CLEAR offset storage` confirm. Matches the `CHANGED_OWNER` cleanup behavior. `[QS]offset` follows up with a 90265 broadcast to clear all sitA `RAM_OVERFLOW` mirrors. |
| 90265  | `[QS]offset` → all `[QS]sitA` | `""`              | `NULL_KEY`        | "Clear your `RAM_OVERFLOW` mirror." Broadcast on `wipe_all_offsets` (90264 follow-up) to keep sitA's session-local RAM-tier mirror in sync. LSD-tier values don't need invalidation — the wipe is visible on next `llLinksetDataRead`. |
| 90266  | `[QS]adjuster` → `hudproxy` | `"On"` / `"Off"`     | `llGetOwner()` (unused) | "Flip QuickyHUD ADJUSTMODE remotely." Sent from the `[HELPER]` choice dialog's "Quicky HUD" button (→ `"On"`), from `[STOP HELP]` (→ `"Off"`, routed back through `[HELPER]`), and from `end_helper_mode` auto-Off (→ `"Off"`, only when adjuster's local `helper_method == 1`). hudproxy mirrors the same `sAdjustmode` + LSD write its own settings menu performs; no confirmation dialog (the user already confirmed by clicking `[HELPER]`). |

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

### 90260 late-arrival re-apply (RAM-tier only)

`run_time_permissions` in `[QS]sitA.lsl` fires `90261` (request RAM-tier
push) and `90000` (play pose) back-to-back when an avatar sits. The two
messages race two independent round-trips:

* `90261` → `[QS]offset` → `90260` (one per matching RAM-tier entry)
* `90000` → `[QS]sitB`   → `90055` → `apply_current_anim` reads LSD direct

For LSD-tier offsets the race is gone post-SSoT-refactor:
`apply_current_anim` reads the LSD value synchronously inside the
handler, so winning or losing the 90260 race no longer matters — the
LSD-tier offset is always visible immediately.

For RAM-tier offsets the race is still possible: if `90055` wins,
`apply_current_anim` reads LSD (miss), then checks `RAM_OVERFLOW`
(empty until the 90260 arrives), and lands on `DEFAULT_POSITION`.
The 90260 then populates `RAM_OVERFLOW`, and nobody re-applies — the
RAM-tier offset is silently ignored.

`[QS]sitA.lsl`'s 90260 handler resolves this by re-applying the offset
inside the handler when CURRENT still equals DEFAULT (i.e.,
apply_current_anim already ran but didn't see our entry). It uses the
same selection rule as apply_current_anim — specific pose wins over
`M#T!`, and the just-pushed RAM-tier value is checked first. Mid-session
adjustments (`X+/Y+/Z+` from the `[Adjust]` dialog) are not overridden
because they shift CURRENT away from DEFAULT, breaking the equality
check.

Since RAM-tier writes only happen when LSD is at the floor (rare in
practice), this race-fix code path is rarely traversed but kept as a
defensive measure for the edge case.

## QSDUMP — plugin announce for the DUMP cascade

`[QS]boot`'s DUMP cascade used to hardcode the participating plugin
script names (`[AV]prop`, `[AV]faces`, `[AV]camera`). Once `[AV]prop`
was forked into `[QS]prop`, that constant had to be edited too — and
any third-party DUMP-capable plugin would still be invisible to the
cascade without a boot patch. QSDUMP turns plugin discovery dynamic:
plugins announce themselves, boot collects.

| Num   | Direction                              | `msg` | `id`                | Meaning |
|-------|----------------------------------------|-------|---------------------|---------|
| 90094 | `[QS]boot` → all plugins              | `""`  | `""`                | QSDUMP probe — "if you're DUMP-capable, announce yourself now." Sent once from boot's `state_entry`. |
| 90095 | DUMP plugin → `[QS]boot`              | `""`  | `<script_name>`     | QSDUMP hello — "I respond to 90020 DUMP messages addressed to my script name." Sent unsolicited from the plugin's `state_entry` and `on_rez`, and in response to 90094. |

### Boot side

Boot maintains `list dump_plugins;` — a deduped list of announced
plugin names. The 90021 cascade iterates `dump_plugins +
[expression_script, camera_script]` per channel; the stock plugin
names stay hardcoded until those forks adopt QSDUMP too.

Boot still `llGetInventoryType`-checks each name before sending 90020,
so a stale announce (plugin script was deleted from inventory) is
silently skipped rather than hanging the cascade waiting for a 90021
echo that never comes.

### Plugin side

```lsl
integer QSDUMP_PROBE = 90094;
integer QSDUMP_HELLO = 90095;

announce_dump()
{
    llMessageLinked(LINK_SET, QSDUMP_HELLO, "", llGetScriptName());
}

state_entry() { announce_dump(); /* ... */ }
on_rez(integer s) { announce_dump(); /* ... */ }
link_message(integer sender, integer num, string msg, key id)
{
    if (num == QSDUMP_PROBE) { announce_dump(); return; }
    /* ... */
}
```

A plugin that never announces still works in stock-AVsitter furniture
(no boot → no listener); QSDUMP is purely additive on top of stock's
90020/90021/90022 contract.

### Migration status

- `[QS]prop` (≥ 0.020) — announces ✅
- `[AV]faces` — stock, still hardcoded in boot
- `[AV]camera` — stock, still hardcoded in boot

When `[AV]faces` and `[AV]camera` are forked into `[QS]faces` /
`[QS]camera`, they get QSDUMP announce and the matching constants
drop from boot.

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

## Re-Sync trigger — `90271`

Multi-avatar SYNC poses (loops with multiple sitters in shared timing —
cuddles, dances) drift between viewers over time, especially after a
viewer culls and re-acquires an avatar (camera zoom, region crossing,
draw-distance changes). The viewer restarts the looped anim locally
at `t=0` on re-acquisition, while other viewers keep their original
timeline.

`[QS]sitA` exposes a single LinkMsg that any in-prim script can send
to force every sitter slot to re-phase its main pose loop in the same
Sim frame:

| Num   | Direction                                | `msg` | `id`  | Meaning |
|-------|------------------------------------------|-------|-------|---------|
| 90271 | hudproxy / any → all `[QS]sitA` slots    | `""`  | `""`  | "Every SYNC-pose sitter, do one Stop+Start cycle on your main anim now." |

### Mechanism

On receipt of `90271`, each `[QS]sitA` instance whose current pose is
a SYNC pose (name not prefixed `P:`) and whose sitter is alive runs:

```
llStopAnimation(CURRENT_ANIMATION_FILENAME);
llSleep(0.05);
llStartAnimation(CURRENT_ANIMATION_FILENAME);
```

The 50 ms sleep is just long enough to cross a Sim-frame boundary so
Stop and Start aren't coalesced into a no-op (Sim runs at ~45 Hz /
22 ms per frame), short enough that most viewers' next render frame
falls outside the gap. Stop+Start is the only mechanism that actually
re-phases a running loop on the viewer side — the viewer determines
loop phase locally at the `Start` event.

POSE-type poses (prefixed `P:`) are solo-by-convention and don't need
re-sync — `do_resync_tick` no-ops on them.

### Policy lives on the sender side

`[QS]sitA` deliberately knows nothing about *when* to re-sync. It
just executes the trigger when asked. The sender (typically hudproxy
in QuickyHUD setups) decides:

- **Auto vs manual** (the user's HUD setting)
- **Tick interval** (e.g., every 30 s, or only on user-noticed drift)
- **Per-furniture overrides** (HUD might disable Re-Sync for solo
  furnitures, or for furnitures whose creator marked them as solo)

This split came after several iterations (sitA 0.16–0.21) tried to
own auto-tick scheduling inside sitA itself: a wall-clock-aligned
30 s timer, a notecard `RESYNC OFF` directive, and a dummy-anim
refresh trick. All three were abandoned — the dummy-anim trick
turned out to refresh skeleton state but not loop phase
(architecturally can't do what it was supposed to do), and the
auto-tick approach competed with the natural sequence timer in
sitA in ways that didn't add value over a HUD-driven trigger.
The history is preserved in `qs/TESTPLAN.md` § Design decisions.

### What hudproxy must do

When the user clicks the SYNC button on the HUD, hudproxy in the
furniture's linkset sends:

```lsl
llMessageLinked(LINK_SET, 90271, "", "");
```

That's the entire integration. Auto-tick (if hudproxy implements it)
is a `llSetTimerEvent` loop on hudproxy's side that fires the same
LinkMsg every N seconds.

### Multi-sitter timing

All `[QS]sitA` slots in the linkset receive `90271` in the same Sim
frame (LINK_SET broadcast). Each does its own Stop+Sleep+Start, with
the Sim processing them sequentially within the frame. The resulting
viewer-side restarts arrive within one Sim frame of each other —
close enough that drift between sitters is corrected to within
~50 ms.

## QSPROP_ATTACH — `90280`

`[QS]prop` is a minimally-invasive fork of stock `[AV]prop`
(`avstock/Plugins/AVprop/[AV]prop.lsl`, 2.2p04) with one new
link-message: a way to register and rez a prop **dynamically**
without writing it into the `AVpos` notecard. Used by
`[QS]hudadmin` (QuickyHUD repo, formerly `[QS]hudprop`) to attach
the Quicky-Pose-HUD on sit / on the manual "Quicky HUD" button —
work that `hudprop` previously did by maintaining its own private
copy of `[AV]prop`'s prop registry.

| Num    | Direction                                  | `msg`                                              | `id`         | Meaning |
|--------|--------------------------------------------|----------------------------------------------------|--------------|---------|
| 90280  | any in-prim source → `[QS]prop`            | `<object>\|<type>\|<point>\|<sitter>\|<post_rez_say>` | sitter UUID  | "Register this dynamic prop for the given sitter slot and rez it now. If a prior 90280 with the same `(sitter, object)` exists, update `point` + `post_rez_say` and re-rez." |

**Payload fields** (pipe-delimited, parse with `llParseString2List`):

| Field | Content |
|-------|---------|
| 0 | Object name in this prim's inventory. Must be an `INVENTORY_OBJECT`. |
| 1 | Stock `[AV]prop` type: `0` = ground prop (COPY-OK NEXT), `1` = attachment prop (COPY-TRANSFER NEXT), `2` = attachment prop personal, `3` = special. The HUD case is type `1`. |
| 2 | Attachment-point name (case-insensitive substring match into `ATTACH_POINTS` table). Empty string falls through to point `0` = "avatar center". For HUDs use e.g. `"HUD center"`. |
| 3 | Sitter slot index (0-based). Must be `< llGetListLength(SITTERS)`; out-of-range messages are silently dropped. |
| 4 | **Optional post-rez say.** Verbatim string `[QS]prop` will `llSay` on its `comm_channel` once the rezzed prop reports `REZ` back via the same channel. Empty = no extra message. Generic mechanism — `[QS]prop` doesn't interpret the content. hudadmin uses it to push `"*QUICKYTEXTURE*\|<uuid>"` to a freshly-rezzed Quicky-Pose-HUD. |

The `id` field carries the seated avatar's key; `[QS]prop` writes it
into `SITTERS[sitter]` so the subsequent `REZ`-handler can resolve
`sitter_key` for the standard `ATTACHTO|<sitter>|<rezzed>` reply
that stock `[AV]prop` already sends for type-1 props.

### Lifecycle and idempotency

The dynamic-prop entry is **stored** in the same `prop_triggers /
prop_types / prop_objects / …` parallel lists that stock loads
from `AVpos`. The trigger string is `<sitter>|<object>`, the
prop group is `<sitter>|QSDYN` (kept separate from notecard
groups). Dedup is by trigger: re-issuing 90280 for the same
`(sitter, object)` pair replaces the mutable fields (`point`,
`post_rez_say`) and re-rezzes via the existing `rez_prop(idx)`
path — no growth in the registry.

### Removal

No new linkmsg is needed for cleanup. Stock `[AV]prop`'s `90065`
(stand-up) handler already calls `remove_props_by_sitter(msg,
FALSE)`, which wipes all non-type-3 entries matching the standing
sitter — including dynamic ones. The registry rows stay, but
that's stock behavior and the dedup logic prevents accumulation
on re-sit.

### Why a parallel `prop_post_rez_say` list

The minimal way to forward HUD-specific data (texture key) without
making `[QS]prop` HUD-aware. The list is **append-only-aligned
with `prop_triggers`** — every code path that appends to
`prop_triggers` (notecard load, stock `90171`/`90173`, new 90280)
also appends one entry to `prop_post_rez_say` (empty for stock
paths). The `listen()` REZ branch reads
`prop_post_rez_say[prop_index]` and llSays it on `comm_channel` if
non-empty. Out-of-range index returns `""` gracefully — so even if
a future refactor breaks alignment, the worst case is missed
texture forwarding, not a runtime error.

### Stock-diff inventory

Total changes from stock `[AV]prop` 2.2p04:

1. **Sitter presence via QSALIVE, not script-name inventory probes.**
   Stock's `string main_script = "[AV]sitA";` and its
   `llGetInventoryType(main_script)` checks are gone. Replaced by
   `qs_alive` + `qs_sitter_count_cached`, populated by a 90096 probe
   sent in `state_entry` / `on_rez` / `changed(CHANGED_INVENTORY)`
   and a 90097 reply handler in `link_message`. `get_number_of_scripts()`
   becomes a one-liner returning the cache (default 1 until reply).
   This is a project-wide convention — script names are not stable
   across forks/renames; QSALIVE is the canonical presence API.
2. New global `list prop_post_rez_say;`.
3. One line in `dataserver` event: `prop_post_rez_say += "";`
   after `prop_points += ...` on `PROP*` notecard lines.
4. One line in `90171/90173` handler: same append, so adjuster-
   added props stay aligned.
5. Three lines in `listen()`'s REZ branch: read
   `prop_post_rez_say[prop_index]` and llSay if non-empty.
6. New `link_message` handler block for `num == 90280` (≈40 lines)
   plus a `num == QSALIVE_REPLY` handler at the top (≈15 lines).
7. Version string + header comment block.

Everything else verbatim from stock.
