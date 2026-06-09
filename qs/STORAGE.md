# QuickySitter state storage

Where every piece of runtime state lives, and whether it survives a script
reset. Companion to [PROTOCOL.md](./PROTOCOL.md), which covers the
link-message protocol that moves data between these stores.

## Quick reference

| What | Where | Persistent? |
|------|-------|-------------|
| **Pose defaults** (`<pos><rot>` from AVpos) | LSD `qs:p:<ch>:<i>` — written by [`[QS]boot`](./[QS]boot.lsl) at seed and by [`[QS]adjuster`](./[QS]adjuster.lsl) on `[HELPER] [SAVE]` | ✅ yes, survives rerez |
| **Personal user offsets** (per-(user, slot, pose), incl. `M#T!` per-slot all-poses fallback, set via `[ADJUSTER] [SAVE]` / `[OFFSET ALL]`) | [`[QS]offset`](./[QS]offset.lsl) — LSD `QSO:<short>:<slot>:<pose>` when room exists past `QPP_CFG:RESERVE`, else global `CUSTOMS` list | ✅ LSD persistent (≥ 0.09), ❌ RAM volatile fallback |
| **Pose runtime state** (which pose is playing, menu navigation, speed) | [`[QS]sitB`](./[QS]sitB.lsl) per-sitter globals | ❌ volatile per session |
| **Playback state** (`CURRENT_POSITION` / `CURRENT_ROTATION`, anim filename, `MY_SITTER`) | [`[QS]sitA`](./[QS]sitA.lsl) per-sitter globals | ❌ volatile |
| **Channel settings** (MTYPE, ETYPE, SWAP, BRAND, CUSTOM_TEXT, ADJUST_MENU, ...) | LSD `qs:cfg:<ch>` (boot writes) + in-memory cache in sitA/sitB | ✅ LSD persistent, memory is cache |
| **Sitter info** (names, gender) | LSD `qs:sitter:<ch>` | ✅ |
| **Boot marker** (channel already seeded?) | LSD `qs:meta:<ch>` (per-channel) + `qs:boot:asset` (notecard asset-key, used by state_entry to skip re-parse) | ✅ |
| **Dump output state** (cache, webkey, webcount) | [`[QS]boot`](./[QS]boot.lsl) globals (since PR #8) | ❌ volatile per dump |

## Linkset Data layout

All keys are namespaced `qs:*`. `<ch>` is the sitter slot (0-based, matches
`SCRIPT_CHANNEL` in sitA/sitB).

| Key | Format | Writer | Readers |
|-----|--------|--------|---------|
| `qs:cfg:<ch>` | `\n`-separated positional values: MTYPE, ETYPE, SET, SWAP, SELECT, AMENU, OLD_HELPER_METHOD, WARN, HASKEYFRAME, REFERENCE, DFLT, BRAND, onSit, CUSTOM_TEXT (escaped), ADJUST_MENU (SEP-joined), RLVDesignations, GENDERS (CSV) | boot's `qs_cfg_pack()` | sitA, sitB, boot's `qs_dump_start` |
| `qs:sitter:<ch>` | `SEP`-joined sitter info row | boot | boot's `qs_dump_start`, sitB |
| `qs:p:<ch>:<i>` | `name\|type\|anim\|pos\|rot` (type is single char: `P`/`S`/`M`/`T`/`B`) | boot's `qs_p_write()`, adjuster's `qs_save_pose_offset` / `qs_add_pose` | sitB's `qs_pose_data()`, adjuster's `qs_find_index` / `qs_p_count`, boot's `qs_dump_tick` |
| `qs:meta:<ch>` | `"qs1"` (presence = "channel seeded") | boot | sitA, sitB (state_entry poll) |
| `qs:boot:asset` | notecard asset-key as string — written last in `finalize_boot` after all `qs:meta:<ch>` | boot | boot's `state_entry` skip-check |
| `QSO:<short>:<slot>:<pose>` | `<pos>\|<rot>` (Euler degrees, both `vector`-string) — unprotected | offset.lsl ≥ 0.09 `save_offset` (when `lsdHasRoom()`) | offset.lsl `push_customs_for`, `drop_pose_for_slot` |
| `qs:offset:alive` | `"1"` while [QS]offset is in the linkset; absent otherwise. Reset-safety: [QS]adjuster's `state_entry` deletes it, [QS]offset's `state_entry` rewrites authoritatively, [QS]adjuster's `QS_OFFSET_HELLO` handler mirrors. Gates sitA's "Personal offset saved..." confirmation in the `[ALL POSES]` / `[SAVE]` handlers. See [PROTOCOL.md § 90088](./PROTOCOL.md). | offset.lsl `state_entry` + 90097 handler; adjuster `QS_OFFSET_HELLO` handler | sitA `[ALL POSES]` / `[SAVE]` confirmation gates |
| `qs:cfg:verbose` | `"0"`–`"3"`. Project-wide verbose ladder (0 = errors only, 1 = boot banner, 2 = runtime status, 3 = debug). Singleton, not per-channel. Set from AVpos `VERBOSE n` directive during seed; every fork script reads it in `state_entry` to populate its local `verbose` global. | boot's `state_entry` (from notecard) | sitA, sitB, adjuster, faces, offset, prop, select, sequence — each in `state_entry` |
| `qs:adjuster:silent` | `"1"` while a Ready-banner has been suppressed on the last reset (so a re-entry to the same notecard doesn't re-announce). Cleared on `QS_BOOT_WIPE`. | adjuster `state_entry` (writes), boot `QS_BOOT_WIPE` (deletes) | adjuster `state_entry` (read-then-suppress) |
| `qs:hud:unlicensed` | `"1"` when [QS]hudadmin's license check failed. Singleton flag for cross-script gating of HUD-paid features ([HELPER] / [QUICKYHUD] entries hide when set). External writer (hudadmin in sibling [quicky-hud](https://github.com/QuickyProducts/QuickyHUD) repo). | hudadmin (external repo) | sitB `[OPTIONS]` / `[HELPER]` gate, adjuster license gate |
| `qs:select:btn:<i>` | `"<label>"` — display string for slot `<i>` shown in [QS]select's multi-slot picker dialog. Cached snapshot so select doesn't have to re-derive from `qs:sitter:<ch>` on every render. | select `state_entry` / `QSALIVE_REPLY` (rewrites from `qs:sitter:<ch>`) | select dialog renderer |
| `qs:prop:meta` | `"<notecard_key>\t<count>\t<warn>\t<groups_nl>"` — lazy-load index header for the prop database. Existence + matching notecard_key means a parsed prop record is current; mismatch triggers `qs:prop:*` namespace wipe + re-parse. | prop.lsl `state_entry` (after notecard parse) | prop.lsl `state_entry` (skip-re-parse check) |
| `qs:prop:<i>` | `"<trig>\t<type>\t<obj>\t<grp>\t<pos>\t<rot>\t<pt>\t<prs>"` (8 fields, prs = post_rez_say payload). One row per parsed prop entry. | prop.lsl notecard parser | prop.lsl `comm_channel` listener, `link_message` handlers |
| `qs:prop:trig:<trig>` | `"i0,i1,…"` — CSV of `qs:prop:<i>` indices matching this trigger string. | prop.lsl notecard parser | prop.lsl trigger dispatch |
| `qs:prop:sit:<sit>` | `"i0,i1,…"` — CSV of `qs:prop:<i>` indices belonging to this sitter slot. | prop.lsl notecard parser | prop.lsl sit/unsit hooks |
| `qs:prop:grp:<grp>` | `"i0,i1,…"` — CSV of `qs:prop:<i>` indices belonging to this group. | prop.lsl notecard parser | prop.lsl group dispatch |

`SEP` is U+FFFD, initialized at runtime via `llUnescapeURL("%EF%BF%BD")`
because the SL script editor mangles a literal U+FFFD on upload.

The `qs:prop:*` namespace is wiped + re-parsed on `CHANGED_INVENTORY`
when the AVpos notecard's asset-key changes. See [`[QS]prop.lsl`](./[QS]prop.lsl) header
for the lazy-load architecture rationale.

The `QSO:*` namespace is intentionally outside the `qs:*` family because
it lives outside the seed-and-forget Linkset Data layout: offset.lsl
manages it lazily across script lifetimes, and it shares the prim with
QuickyHUD's protected `QPP_CFG:*` keys without colliding.

## Why pose defaults moved to LSD (vs stock AVsitter)

Stock AVsitter holds *everything* in `[AV]sitB`'s script memory: `DATA_LIST`
(pose-anim mappings) and `POS_ROT_LIST` (positions/rotations). On `[HELPER]
[SAVE]`, stock updates only those in-memory lists — the AVpos notecard is
**not** auto-written. The `[DUMP]` button exists exactly for that reason: the
creator copy-pastes the dump output back into the notecard manually, or
loses unsaved changes on the next script reset.

QuickySitter writes pose defaults to LSD on `[HELPER] [SAVE]`. They survive
rerezes and re-imports as long as `qs:boot:asset` matches the notecard's
current asset-key (boot then skips re-seeding from the notecard). The
legacy `[DUMP]` is still there for human backup, but you no longer lose
work by forgetting to use it.

Side benefit: at scale (1000+ poses), keeping `DATA_LIST` and `POS_ROT_LIST`
in sitB memory would push it past Mono's 64 KB cap. With on-demand LSD reads
via [`qs_pose_data(idx)`](./[QS]sitB.lsl), sitB stays slim regardless of
config size.

## Personal offsets: persistent in LSD, RAM as fallback

Stock keeps `CUSTOMS` in sitA's memory (per sitter slot), volatile — lost on
script reset, rerez, and owner change. QuickySitter moved personal offsets out
into a dedicated [`[QS]offset`](./[QS]offset.lsl) script with a two-tier store:

- **LSD tier (persistent):** `QSO:<short8>:<slot>:<pose>` (plus the `M#T!`
  per-slot all-poses fallback), written whenever LSD has room past the
  `QPP_CFG:RESERVE` floor. Survives script reset and rerez; cleared on owner
  change.
- **RAM tier (volatile fallback):** a single global `CUSTOMS` LRU cache
  (cap 200), used only when the LSD tier is at its floor.

Per-user keying is by an 8-char UUID prefix (`<short8>`) with the pose name in
the key. The persistent tier is advertised to plugins via the `offsetlsd_v1`
capability in the QSALIVE reply. See the per-script breakdown below and
[PROTOCOL.md § Personal pose offsets](./PROTOCOL.md) for the 90260–90265
traffic.

## Per-script state breakdown

### [QS]boot.lsl (one instance)

- Notecard parser globals: `MTYPE`, `ETYPE`, `SET`, `SWAP`, `AMENU`,
  `SELECT`, `OLD_HELPER_METHOD`, `WARN`, `HASKEYFRAME`, `REFERENCE`, `DFLT`,
  `BRAND`, `onSit`, `CUSTOM_TEXT`, `ADJUST_MENU`, `RLVDesignations`,
  `GENDERS` — set during seed, retained for reference
- Boot orchestration: `total_channels`, `current_processing_channel`,
  `load_t0`, `notecard_query`, `notecard_lines`
- Dump streaming state: `qs_dump_ch` (-1 = idle), `qs_dump_pi`
- Dump output pipeline (since PR #8): `cache`, `webkey`, `webcount`,
  `url`, `camera_script` (the only hardcoded stock-plugin name left;
  `prop_script` and `expression_script` retired with the `[QS]prop` /
  `[QS]faces` QSDUMP migration)

### [QS]sitA.lsl (one per sitter slot)

- Per-sitter playback: `MY_SITTER`, `CONTROLLER`, `MY_CUSTOMS` (cache from
  [QS]offset), `DEFAULT_POSITION`, `DEFAULT_ROTATION`, `CURRENT_POSITION`,
  `CURRENT_ROTATION`, `CURRENT_POSE_NAME`, `CURRENT_ANIMATION_FILENAME`,
  `CURRENT_ANIMATION_SEQUENCE`, `OLD_POSE_NAME`, `OLD_ANIMATION_FILENAME`
- First-sit defaults: `FIRST_POSENAME`, `FIRST_POSITION`, `FIRST_ROTATION`,
  `FIRST_ANIMATION_SEQUENCE`, `FIRST_INDEX`
- Gender variants: `MALE_POSENAME`, `FEMALE_POSENAME`,
  `FIRST_MALE_ANIMATION_SEQUENCE`, `FIRST_FEMALE_ANIMATION_SEQUENCE`
- Settings cache (read from `qs:cfg`): `MTYPE`, `ETYPE`, `SET`, `SWAP`,
  `SELECT`, `AMENU`, `OLD_HELPER_METHOD`, `WARN`, `HASKEYFRAME`,
  `REFERENCE`, `DFLT`, `BRAND`, `onSit`, `CUSTOM_TEXT`, `ADJUST_MENU`,
  `RLVDesignations`
- Sitter list: `SITTERS`, `SITTERS_SITTARGETS`, `GENDERS`
- Dialog state: `menu_handle`, `menu_channel`, `pos_rot_adjust_toggle`,
  `increment_pointer`
- Misc: `my_sittarget`, `SCRIPT_CHANNEL`, `SET`, `SWAPPED`, `has_RLV`,
  `has_security`, `has_texture`, `speed_index`

### [QS]sitB.lsl (one per sitter slot)

- Pose runtime: `MENU_LIST` (pose names from LSD), `ANIM_INDEX`,
  `FIRST_INDEX`, `current_menu`, `menu_page`, `last_menu`, `submenu_info`
- Per-sitter dialog: `MY_SITTER`, `CONTROLLER`, `menu_channel`,
  `menu_handle`, `speed_index`
- Settings cache: same set as sitA, read once in `state_entry` from
  `qs:cfg:<ch>`
- Misc: `SCRIPT_CHANNEL`, `number_of_sitters`, `helper_mode`, `has_RLV`,
  `OLD_HELPER_METHOD`

What sitB does **not** hold (vs stock AVsitter): the per-pose
`DATA_LIST`/`POS_ROT_LIST`. Those are read on demand from LSD via
`qs_pose_data(idx)` — see § "Why pose defaults moved to LSD" above.

### [QS]offset.lsl (one instance, optional)

Two-tier store, see [§ Personal pose offsets](./PROTOCOL.md#personal-pose-offsets--qsoffset--qssita) in PROTOCOL.md for the link-message side.

- **LSD tier** (≥ 0.09, persistent): `QSO:<short>:<slot>:<pose>` keys,
  value `<pos>\|<rot>` (both `vector`-string in degrees). Unprotected
  reads/writes — no `LSD_PASS` involved (intentional, see PROTOCOL.md
  capability notes). The slot in the key lets each sitter slot keep
  its own offset for the same pose name (SYNC couple poses on multiple
  slots had a flat (user, pose) key before 0.09 and would overwrite
  each other on save).
  - `LSD_BYTES_PER_ENTRY` (80) and `LSD_MIN_FREE_POSES` (200): `save_offset`
    only writes to LSD if `(llLinksetDataAvailable() − reserved) /
    LSD_BYTES_PER_ENTRY ≥ LSD_MIN_FREE_POSES`. `reserved` reads
    `QPP_CFG:RESERVE` (set by hudprop) unprotected; missing → 0.
  - No timestamp / eviction in LSD — full keys persist until manually
    cleared, fall back to RAM if room runs out.
- **RAM tier** (volatile fallback): `CUSTOMS` flat list with stride 5:
  `[pose_name, user_short, slot, pos_offset, rot_offset, ...]`
  - `LRU_CAP` — hard cap on entries (currently 200). Picked so that
    `200 × ~150` bytes worst-case + ~12 KB script code/state stays well
    under Mono's 64 KB cap. Front-evicted by `cull_to_cap` after each
    save (single batch `llDeleteSubList`).
  - `EMERGENCY_FREE_BYTES` (3000) — `save_offset` calls
    `emergency_shrink()` *before* the `+=` and evicts one entry at a
    time until free memory ≥ this threshold or the list is empty.
    Defends against Stack-Heap Collision if the per-entry estimate
    diverges from reality (very long Unicode pose names, heap
    fragmentation from other scripts).

Diagnostics — emergency-shrink events emit at `Out(0, "WARN: …")` so
they always show (the support-feedback floor); the boot-time "Ready.
LSD room=…" banner emits at `Out(1, …)`. See the project-wide verbose
convention (AVpos `VERBOSE n` token + `qs:cfg:verbose` LSD key); default
is `VERBOSE 0` (silent except errors) — add `VERBOSE 1` to AVpos to
opt into the Ready banner.

### [QS]adjuster.lsl (one instance)

Most state is creator-tool runtime: helper-bar mode, listen channel,
sitter tracking, menu navigation. No persistent state of its own — all
LSD writes go through `qs_save_pose_offset` / `qs_add_pose` into the
shared `qs:p:<ch>:<i>` namespace.

## Reset behavior

| Trigger | Effect |
|---------|--------|
| Notecard changed (boot's `CHANGED_INVENTORY`) | boot resets, re-parses notecard, **rewrites** `qs:cfg`/`qs:sitter`/`qs:p:*`/`qs:meta:*`, then resets every sitA and sitB so they bootstrap from fresh LSD |
| Sitter-script count changed | same as above |
| Object rerez | LSD survives. boot starts; if `qs:boot:asset` matches the notecard's current asset-key, skips re-seeding entirely (live edits via `[HELPER] [SAVE]` are preserved). Manual script reset / region restart hits the same path. |
| Owner changed | offset.lsl wipes both tiers — RAM `CUSTOMS` resets and `QSO:*` LSD keys are deleted (visitors' UUIDs from the previous owner's setting shouldn't follow the prim to a new owner). `qs:*` LSD survives unless the new owner re-imports the notecard. |
| Manual reset of one sitA or sitB | that script reads from LSD on `state_entry` and rejoins the running system; offset.lsl doesn't get re-pushed customs until next sit triggers 90261 |

## See also

- [PROTOCOL.md](./PROTOCOL.md) — link-message protocol that connects these
  stores
- [`[QS]boot.lsl`](./[QS]boot.lsl) — the writer for the persistent half
- [`[QS]offset.lsl`](./[QS]offset.lsl) — the personal-offset store (LSD-persistent, RAM fallback)
