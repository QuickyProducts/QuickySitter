# [QS]sitB pose-menu semantics — specification

**Status: READY TO FREEZE (not yet committed).** Built by reading the current
`[QS]sitB.lsl` (0.9951) / `[QS]sitA.lsl` (0.9952) + `[QS]boot.lsl` parser + `[QS]select.lsl`.
This is the reference the page-oriented menu rebuild must satisfy: every
behaviour below must survive, the *external contracts* (§ 7) must stay
byte-identical, the *invariants* (§ 8) are the accumulated edge-case wisdom,
§ 9 is the reason we rebuild, and § 14 pins the exact MTYPE/ETYPE/`B:`/select
semantics.

All source-checkable `[verify]` markers are now resolved against the code. The
**only** remaining `[verify]` markers (§ 12 line, § 13 line) are *in-world
behavioural* checks of the stale view-state risk after SWAP / reseed / standup
with a dialog open — these are **rebuild test items**, not blockers for
freezing the spec (the rebuild is what fixes them; the test confirms it).

---

## § 1 — Data model + marker grammar (verified)

boot parses the AVpos notecard into LSD, one entry per list line, in
**seed order**: `qs:p:<ch>:<i>` = `name|type|anim|pos|rot`. `<i>` is the
flat index = position in the channel's sequence. `MENU_LIST` (RAM today) is
**only field 0** — the prefix-bearing label.

| Notecard | MENU_LIST entry (field 0) | Meaning | Clickable endpoint? |
|---|---|---|---|
| `POSE Name`   | `P:Name`   | pose, plays anim          | yes |
| `SYNC Name`   | `Name` (no prefix) | multi-avatar sync pose | yes |
| `MENU Name`   | `M:Name*`  | submenu **section marker** | no (structure) |
| `TOMENU Name` | `T:Name*`  | submenu **entry button**   | yes (navigates) |
| `BUTTON Name` | `B:Name`   | custom button → channel    | yes (channel) |
| `SEQUENCE Name` | → `B:Name` (chan 90210) | sequence button | yes |

Source: boot [1271-1280](../[QS]boot.lsl). Note the asymmetry: `MENU`/`TOMENU`
get a trailing `*`; `SYNC` gets **no prefix** at all. The first POSE/SYNC seen
becomes `FIRST_POSENAME` (the default pose). pos/rot arrive per-entry (fields
3/4) or via a second-pass `{Name}<pos><rot>` splice.

**Invariant for the rebuild:** the grammar stays; only addressing/storage
(name→index, RAM→LSD) changes. A consumer must still distinguish the five
classes by prefix to decide its action.

---

## § 2 — RAM state variables (what lives in RAM today, and why)

| Var | Role | Rebuild note |
|---|---|---|
| `MENU_LIST` | flat list of all labels (~30 KB @570) | **the target** — should become page + LSD |
| `ANIM_INDEX` | index of currently-playing pose | stays (small) |
| `FIRST_INDEX` | index of default pose (first POSE/SYNC) | stays |
| `current_menu` | index of active submenu marker (`M:`), -1 = root | stays |
| `last_menu` | previous submenu (BACK shortcut) | stays |
| `menu_page` / `plugin_page` / `adjust_page` | paging cursors | stays |
| `in_plugin_menu` / `in_adjust_menu` | which dialog is open | stays |
| `MY_SITTER` / `CONTROLLER` | seated avatar / who's driving the menu | stays |
| `helper_mode` | helper-bar adjust mode active | stays |
| `speed_index` | -1/0/+1 Soft/Hard pose variant | stays |
| `has_RLV` / `has_security` / `has_texture` | stock capability flags (90202/90203) | **stays as-is** (not qs:alive) |
| `ADJUST_MENU` | notecard ADJUST pairs `label\|chan` | from `qs:cfg` slot 14 |
| `QSPLUG_REGISTRY` | strided-3 `[label,chan,scriptName]` plug-in buttons | stays (small) |
| `MTYPE/ETYPE/SET/SWAP/AMENU/OLD_HELPER_METHOD/DFLT` | per-channel config | from `qs:cfg` |
| `BRAND/onSit/CUSTOM_TEXT/SITTER_INFO/RLVDesignations` | display/config | from `qs:cfg`/`qs:sitter` |
| `iBooted` | this slot loaded from LSD yet | stays |

---

## § 3 — Rendering (`animation_menu`, [193-389](../[QS]sitB.lsl))

12 dialog slots, assembled from three lists then `reorder_dialog_buttons`
([178-181](../[QS]sitB.lsl), 3-per-row bottom-up layout):

- **menu_items0** (left): `[BACK]` (if `current_menu != -1` or select), `<< Softer`/`Harder >>` (if submenu type `V`).
- **menu_items1** (middle): the current page of pose/submenu buttons. Built by index-walk from `current_menu+1` ([339-358](../[QS]sitB.lsl)), stops at first non-`M:` (`jump end`), strips prefix (`T:`/`P:`/`B:` → substring(2)).
- **menu_items2** (right, control): `[NEW]`/`[DUMP]`/`[SAVE]`/`[DONE]` (helper_mode‖qh_on), `[ADJUST]` (AMENU rules & not in mode), `[OPTIONS]` (registry non-empty & root), `[SWAP]` (ASK & multi-sitter & !select), `[STOP]`/`Control...` (RLV & root), `[<<]`/`[>>]` (paging).

**Header** (`menu` string): `product+version` or `BRAND`; `"Menu for <name>"` if `CONTROLLER != MY_SITTER ‖ has_RLV`; `CUSTOM_TEXT`; `[<SITTER_INFO>]` or `[Sitter N]` if multi-sitter; current pose name + `, Soft`/`, Hard` if a `+`-variant anim exists.

- `total_items`: count of `M:`-marked items from `current_menu+1` ([243-247](../[QS]sitB.lsl)).
- `items_per_page = 12 - len(menu_items2) - len(menu_items0)`; if `total_items > items_per_page` → add `[<<]`/`[>>]`, subtract 2.
- `animation_menu(1)` returns page count (no render); `animation_menu(0)` renders + opens `llDialog`.
- `submenu_info == "V"` pads middle with `" "` for Soft/Hard layout.
- On render, root state resets `in_plugin_menu`/`in_adjust_menu` (stale-dialog-X guard, [371-383](../[QS]sitB.lsl)).

---

## § 4 — Navigation ([840-861](../[QS]sitB.lsl) + dispatch)

- **Submenu enter:** click `M:`/`T:` → `current_menu = index`, `menu_page = 0`, re-render. (90051 sent to sitA for `T:`.)
- **`[BACK]`:** if `last_menu != -1` → pop to it; else **parent search**: `findList("T:"+name-of-current)`, then backward-scan for the enclosing `M:` marker ([850-858](../[QS]sitB.lsl)). ← this backward-scan is one of the heap/CPU hotspots.
- **Paging:** `menu_page` + `[<<]`/`[>>]`; clamped in the render loop.
- **Root reset:** rendering the pose menu means back at root → submenu/dialog flags cleared.

---

## § 5 — Dispatch (`listen`, [611-873](../[QS]sitB.lsl)) — three routing layers, checked in order

1. **`in_plugin_menu`** ([617-656](../[QS]sitB.lsl)): `[<<]`/`[>>]` page, `[BACK]` → pose menu, registry-lookup (strided-3, `pi%3==0` guard) → `llMessageLinked(click_chan, label, CONTROLLER)`, unknown → bail to pose menu.
2. **`in_adjust_menu`** ([675-739](../[QS]sitB.lsl)): `[<<]`/`[>>]` page, `[BACK]` → 90005 (re-render pose menu), `[POSE]` → 90101`[POSE]` (sitA renders adjust_pose_menu), ADJUST_MENU pair (`ami%2==0`) → `llMessageLinked(chan, label, dispatch_id)` (composite `id|MY_SITTER` unless `AMENU&4`), builtins → 90100 broadcast.
3. **MENU_LIST dispatch** ([740-873](../[QS]sitB.lsl)):
   - **Pose** (`msg` or `P:msg` found): 90050 (pick) + 90000 (play) to sitA; 90005 (re-menu) unless `MTYPE` 2/4.
   - **Submenu** (`M:`/`T:` found): 90051 + navigate.
   - **Button** (`B:` found, [769](../[QS]sitB.lsl) — the `llList2List` copy hotspot): channel send — full payload format in § 14.
   - **`[BACK]`**: navigation (§ 4).
   - **`Control...`/`[STOP]`**: 90100 broadcast.
   - **Unknown**: 90101 (`label|controller|current_menu`) → adjuster `[NEW]` insertion path.

---

## § 6 — Modes + transitions

Three menu-enriching modes plus select. The **transitions** were under-specified
in the first draft — they are the critical part.

| Mode | What it adds | State held in |
|---|---|---|
| **normal** | plain pose menu | — |
| **helper_mode** | `[NEW]/[DUMP]/[SAVE]/[DONE]` in pose menu; [AV]helper-bar adjust | sitB `helper_mode` flag + adjuster rezzes bars |
| **qh_on** | same pose-menu enrichment; QuickyHUD-driven (no bars) | `QPP_CFG:ADJUSTMODE == "On"` (LSD, **not** a sitB flag) |
| **select** | root → 90009 hands menu to [QS]select seat-picker (no render) | `select_present()` (qs:alive:select ‖ legacy) |

### Transitions (all via 90100 broadcast; owner-gated where noted)

| Trigger | Rendered in | Effect |
|---|---|---|
| `[HELPER]` (owner) | adjust_dialog tail (helper_object + qs:alive:adjuster) | **enter helper_mode**: sitB toggles `helper_mode` ([1133-1140](../[QS]sitB.lsl)), adjuster `toggle_helper_mode` rezzes bars ([726-755](../[QS]adjuster.lsl)) |
| `[QUICKYHUD]` (owner) | adjust_dialog tail (ADJUSTMODE key exists + licensed + qs:alive:adjuster) | **enter qh_on**: adjuster flips `QPP_CFG:ADJUSTMODE="On"` + 90005 re-menu ([756-778](../[QS]adjuster.lsl)). helper_mode stays FALSE — qh has no dedicated submenu |
| **`[DONE]`** | pose menu (helper‖qh) | **unified exit**: sitB `helper_mode=FALSE` + opens adjust_dialog; broadcasts 90100`[DONE]`; adjuster tears down — de-rez helpers, 90266 "Off" if helper_method==1 ([sitB:812-828](../[QS]sitB.lsl), [adj:701-725](../[QS]adjuster.lsl)) |
| `[ADJUST OFF]` | pose menu (qh_on branch) | qh-only exit: adjuster flips ADJUSTMODE off + clears helper_method ([adj:780+](../[QS]adjuster.lsl)) |
| stand-up | — | auto-`end_helper_mode` (adjuster [329](../[QS]adjuster.lsl)): 90266 "Off" if helper_method==1, then cleanup; sitB CHANGED_LINK clears `helper_mode` (if !OLD_HELPER_METHOD) |

**Owner-gate invariant:** `[HELPER]`/`[QUICKYHUD]` clicks from non-owners MUST be
refused — sitB ([1133](../[QS]sitB.lsl)) AND adjuster ([726](../[QS]adjuster.lsl))
each check `llGetOwner()`. Missing either gate = the double-dialog / global-toggle
regression. The rebuild must keep both.

**`[DONE]` vs `[BACK]` (regression history):** `[DONE]` is *deliberately separate*
from `[BACK]` so a user navigating up out of a deep pose-submenu doesn't
accidentally tear down the mode ([sitB:256-279](../[QS]sitB.lsl) comment). Pre-0.992
used `[BACK]`/`[ADJUST OFF]` with asymmetric semantics that surprised users.

---

## § 7 — EXTERNAL CONTRACTS (the fixpoints — must not break)

### Inbound link_messages sitB handles
| Num | From | Meaning |
|---|---|---|
| 90000/90010/90003/90008 | sitA | play pose (by name) → `findList` → ANIM_INDEX + send_anim_info |
| 90004/90005 | sitA/self | (re-)send menu to controller |
| 90030/90031 | swap senders | swap: 90031 also tears down menu_handle + clears CONTROLLER/MY_SITTER |
| 90033 | — | close listen |
| 90045 | sitA (self-link) | pose-played broadcast; SYNC OLD_SYNC reset |
| 90077 | boot | self-check probe → reply 90078 |
| 90097 | sitA slot 0 | QSALIVE — sitter **count** (number_of_sitters) |
| 90100/90101 | self/adjuster/faces/security | menu choice routing (slot-filtered by data[0]); `[HELPER]`/`[ADJUST]`/`[ADJUST OFF]`/Soft/Hard |
| 90201 | sitA | capability-probe → reset has_RLV/security/texture |
| 90202 | [AV]root-security | RLV state (→has_RLV) + has_security=TRUE |
| 90203 | [AV]texture | has_texture=TRUE |
| 90212 | plugins | QSPLUG_REGISTER (label\|chan\|scriptName) |
| 90300/90301 | adjuster | live insert / save pose (MENU_LIST insert hotspot [1251](../[QS]sitB.lsl)) |
| 90023/90024 | boot | QS_BOOT_RELOAD (re-read LSD) / QS_BOOT_WIPE (clear, pre-boot guard) |

### Outbound link_messages sitB sends
90000+90050 (play+pick), 90051 (submenu), 90005 (re-menu), 90009 (→select), 90055 (anim info→sitA), 90100/90101 (choice/adjust back-route), 90078/QS_SITB_HELLO (boot self-check reply, 90077 probe). Complete set — verified by grep of every `llMessageLinked` in sitB (no other nums emitted).

### Other contracts
- **AVpos notecard format** — boot owns the parse (§ 1 grammar). Unchanged.
- **Plugin API**: QSPLUG_REGISTER (90212, [OPTIONS]), ADJUST_MENU notecard pairs (90100/own-chan), capability discovery (90201/90202/90203).
- **qs:alive presence** (since 0.9951): faces/adjuster/select read on-demand for `[FACES]`/`[HELPER]`/`[QUICKYHUD]`/select gating. See project memory + PROTOCOL.md § qs:alive.
- **sitA split**: sitA owns sit-state + pose playback + adjust_pose_menu ([POSE]); sitB owns menu rendering + dispatch. 90055/90101/90005 cross the boundary.

---

## § 8 — Invariants + edge cases (accumulated wisdom — the rebuild must preserve)

- **ANIM_INDEX / FIRST_INDEX** are indices into the flat sequence; standup resets `ANIM_INDEX = FIRST_INDEX` ([909](../[QS]sitB.lsl)).
- **SYNC**: a SYNC pose (no prefix) playing; 90045 carries OLD_SYNC, sitB resets to FIRST_INDEX when the playing pose matches OLD_SYNC ([1049-1053](../[QS]sitB.lsl)). sitA coupling verified in § 11 (`IS_SYNC = llSubStringIndex(name,"P:")!=0`).
- **Multi-sitter**: `SCRIPT_CHANNEL` = slot; one sitB per slot; `number_of_sitters` (QSALIVE-cached) gates `[Sitter N]`/`[SWAP]`. **Slot filter** on 90100/90101 (`data[0]==SCRIPT_CHANNEL` or `"X"` wildcard, [1118](../[QS]sitB.lsl)) — without it every slot reacts to one broadcast.
- **RLV**: `has_RLV` + `RLVDesignations` (per-slot char; `D` = dominant). `[STOP]`/`Control...` render only when `has_RLV && (RLVDesignations[slot]=="D" ‖ CONTROLLER!=MY_SITTER)` ([322-328](../[QS]sitB.lsl)); `Control...` is suppressed in helper_mode. Both route out on **90100** slot-tagged ([865](../[QS]sitB.lsl)) → [AV]root-control/RLV. Also drives the "Menu for" header.
- **changed(CHANGED_LINK)** ([876-918](../[QS]sitB.lsl)): pre-boot eject (slot-0 only, !iBooted → unsit + chat hint); standup (no avatar → speed_index=0, helper_mode off, MY_SITTER="", ANIM_INDEX=FIRST_INDEX); sit. **Perm note**: TRIGGER_ANIMATION auto-revokes before CHANGED_LINK runs — standup cleanup must not be gated behind a perm check (memory: lsl-perm-revoke-on-standup).
- **Swap** (90030/90031): 90031 (quiet, HUD) tears down menu_handle + clears controller; 90030 (loud) leaves dialog for user dismissal.
- **MTYPE/ETYPE/SET/SWAP/AMENU**: per-channel behaviour switches. ETYPE==2 → unsit on non-`P:` pose ([1035-1043](../[QS]sitB.lsl)); MTYPE 2/4 → no menu re-send after pose pick. Full value matrix in § 14.

---

## § 9 — Heap hotspots (why we rebuild)

At 570 poses MENU_LIST is ~30 KB ≈ half the 64 KB Mono budget → sitB runs ~96% full:
- [1251](../[QS]sitB.lsl) `llListInsertList` (NEW) — rebuilds whole list → transient 2× MENU_LIST.
- [769](../[QS]sitB.lsl) `llList2List(MENU_LIST, current_menu+1, 99999)` (submenu B: click / back parent-search) — copies most of the list.
- `llListFindList(MENU_LIST, …)` chain in dispatch — O(n) CPU per click (not heap, but laggy at 570).

---

## § 10 — What the page-oriented rebuild must deliver

1. **RAM = O(visible page + nav depth)**, not O(poses). Only the current page (~12 labels+indices) + the submenu nav stack in RAM.
2. **Index addressing**, not name lookup, for click dispatch (page-map: button position → index). Avoids both the RAM list and the O(n) LSD scan.
3. **Navigation via explicit hierarchy** (submenu parent/children), not backward-scan over a flat list.
4. **Length** from a count key the rebuild must **add** (e.g. boot writes `qs:cfg:slots`) — confirmed absent in boot today, so this is new work — not `llGetListLength(MENU_LIST)`.
5. **Insert (NEW)** as an LSD re-key, not a RAM list rebuild.
6. All of § 7 (contracts) byte-identical; all of § 8 (invariants) preserved; verified against TESTPLAN's existing TCs.

---

## § 11 — sitA side of the contract (verified)

**qs:cfg slot map** (boot `qs_cfg_pack` [349-359](../[QS]boot.lsl)):
`0`MTYPE `1`ETYPE `2`SET `3`SWAP `4`SELECT `5`AMENU `6`OLD_HELPER_METHOD
`7`WARN `8`HASKEYFRAME(KFM) `9`REFERENCE(LROT) `10`DFLT `11`BRAND `12`onSit
`13`CUSTOM_TEXT(\n-esc) `14`ADJUST_MENU(SEP-joined) `15`RLVDesignations
`16`GENDERS(CSV). sitB reads 0-3,5,6,11-15; the rest is sitA-only.

**90055 = the core handoff** (sitB→sitA, sitA [1136-1156](../[QS]sitA.lsl)).
`id` = `name|animSeq|pos|rot|broadcast|speed`. sitA stores CURRENT_POSE_NAME/
SEQUENCE/POSITION/ROTATION + speed_index, then `apply_current_anim(broadcast)`
+ `set_sittarget`. **This is how every pose actually plays** — sitB owns the
*selection* (index→name), sitA owns the *playback*.

**90101 is a shared LINK_SET broadcast**, not point-to-point (slot-filtered
by data[0]): sitA [1086-1131](../[QS]sitA.lsl) picks `[POSE]`→adjust_pose_menu,
`[SWAP]`→90030, Harder/Softer→90005 re-menu; **sitB** picks `[HELPER]`/
`[ADJUST]`/`[ADJUST OFF]`/speed; **adjuster** picks the `[NEW]`-insert (unknown
label + current_menu). Any rebuild must keep sitB emitting the unknown-label
90101 and handling its own subset.

**90050/90051** (sitB→…, [748](../[QS]sitB.lsl)/[761](../[QS]sitB.lsl)): **no
QS-internal receiver** — stock-AVsitter "pose pick"/"submenu" contract, kept
for stock-plugin compat (camera etc.). Must keep emitting.

**SYNC playback** (apply_current_anim [505-528](../[QS]sitA.lsl)):
`IS_SYNC = llSubStringIndex(name,"P:") != 0` — a pose **without** the `P:`
prefix is SYNC (matches § 1). On a SYNC→other change sitA puts the old name
in `OLD_SYNC` and broadcasts it as 90045 field 5; sitB resets to FIRST_INDEX
when its playing pose == OLD_SYNC. `P:` is stripped for display, SYNC names
aren't. Re-sync trigger 90271 (Stop+Start cycle) is sitA-owned.

**MTYPE / ETYPE** (stock semantics): MTYPE gates touch-pass
(`llPassTouches(MTYPE>2)` [sitA:218](../[QS]sitA.lsl)) + menu re-send (sitB
skips on 2/4); ETYPE==2 = exclusive (unsit on non-`P:` pose,
[sitB:1035](../[QS]sitB.lsl)); ETYPE ignored on swap-play (90010). Full value
table in § 14.

**sitA-owned, NOT sitB** (the split the rebuild must respect): sit-state,
pose playback (`apply_current_anim`), `adjust_pose_menu` (Position/Rotation/
X+/Y+/Z+ — the `[POSE]` handoff), sittargets, personal offsets (QSO/
RAM_OVERFLOW), swap execution, SYNC re-sync.

This resolves the `[verify]` markers in § 1, § 7, § 8 (SYNC coupling, 90101
direction, 90050/90051 target, 90055 payload, qs:cfg slots).

## § 12 — SWAP (the hard part — multiple embedded regression fixes)

SWAP is the most-patched path; every fix below is a real bug that shipped and
got corrected. The rebuild must preserve all of them. Two channels:

- **90030** (loud): pose-menu `[SWAP]`, [QS]select picker — **with** post-swap menu reopen.
- **90031** (quiet, QS_SWAP_QUIET): HUD — hudproxy quick-swap, hudadmin picker, [QS]debug — **no** reopen (`bSilentSwap`).

**sitA swap-handler** ([969-1020](../[QS]sitA.lsl)):
- Slot filter: only `one==SCRIPT_CHANNEL ‖ two==SCRIPT_CHANNEL` react.
- `SWAPPED=TRUE`, `bSilentSwap=(num==90031)`, then `llRequestPermissions(reused_key)`.
- **Fix — MY_SITTER cleared only on the involved slots** ([987-997](../[QS]sitA.lsl)): the pre-fix unconditional wipe broke "SYNC pose change only affects one sitter" after a swap-to-self via the seat picker.
- **Fix — SITTERS swapped up-front** ([1017-1019](../[QS]sitA.lsl)): without it CHANGED_LINK re-claims the avatar on slot 0, racing the destination slot's run_time_permissions → both slots claim the same avatar → wrong sit-position.

**sitA run_time_permissions** ([1404-1453](../[QS]sitA.lsl)):
- `SWAPPED` → `lnk=90010` (play **ignoring ETYPE**) instead of 90000.
- **Reopen gated on `!MTYPE && !bSilentSwap`** ([1441](../[QS]sitA.lsl)): loud 90030 reopens the pose menu; quiet 90031 stays silent (the HUD already gave the user feedback via its own dialog).

**sitB swap-handling** ([1086-1103](../[QS]sitB.lsl)) — **the "dialog must not react after a HUD swap" case (verified present):**
- On **90031**: `llListenRemove(menu_handle)` — a pose dialog still on-screen can't fire **stale clicks** against the now-empty CONTROLLER/MY_SITTER. LSL can't close the dialog window (stays visible until the user X's it / it times out), but dropping the listen neutralizes it.
- On **both** 90030/90031: `CONTROLLER = MY_SITTER = ""`.
- **90030 deliberately does NOT listen-remove** — stock paths dismiss the dialog via the user's own click; the orphaned listen is harmless and left alone for stock parity.

### SWAP is asynchronous — it arrives in ANY menu state (the core difficulty)

A 90031 swap can land while sitB is in **any** state: pose dialog open,
`in_plugin_menu`, `in_adjust_menu`, helper_mode/qh_on, mid-paging, deep in a
submenu. The current handler ([1099-1101](../[QS]sitB.lsl)) clears **only**
`menu_handle` (listen) + `CONTROLLER`/`MY_SITTER`. It does **not** reset the
menu *view-state*: `current_menu`, `helper_mode`, `menu_page`,
`in_adjust_menu`/`in_plugin_menu`. animation_menu's root-render clears the
two `in_*_menu` flags ([371-383](../[QS]sitB.lsl)) but **not**
`current_menu`/`helper_mode`/`menu_page`. And 90031 does **no** reopen
(`bSilentSwap`), so nothing re-renders until the *new* occupant touches.

**→ Potential stale view-state `[verify in-world]`:** after a HUD swap, the
slot's new occupant may open the menu into the *previous* occupant's submenu
(`current_menu`) or helper_mode. This is the likely root of the recurring
SWAP trouble — the view-state isn't fully reset on the async swap.

**Rebuild requirements (this is why SWAP is the hard part):**
1. The swap *execution* is sitA-owned and barely touches MENU_LIST.
2. Make the slot's reaction a **single atomic view-state reset on swap** —
   the page-oriented design helps: a compact view-state block (current page +
   nav stack + mode) is trivially clearable, unlike today's scattered globals.
3. Consider a **swap-in-progress lock**: ignore/queue menu clicks between
   swap-start and the new occupant's first render, so a click can't act on a
   half-swapped state. (The listen-remove is today's partial version of this.)
4. Preserve the 90031 listen-teardown + the 90030/90031 asymmetry exactly.

(Swap also drove the 6-sitter heap pressure on the *HUD* side — separate issue.)

## § 13 — Concurrency: async events vs. open menu state (the recurring pattern)

Both review findings (mode transitions §6, SWAP §12) are instances of one
class: **an event mutates the slot's data or occupant while a menu/dialog is
open.** Each must leave a consistent view-state.

| Async event | What it invalidates | Current sitB reset | Gap |
|---|---|---|---|
| **SWAP** (90031) | occupant (MY_SITTER) | listen-remove + CONTROLLER/MY_SITTER="" ([1099-1101](../[QS]sitB.lsl)) | current_menu / helper_mode / in_*_menu NOT reset (§12) |
| **Notecard reseed** (90024→90023) | MENU_LIST + **all indices** | current_menu/last_menu/menu_page=0 + MENU_LIST cleared then reloaded ([953-981](../[QS]sitB.lsl)) | in_plugin_menu / in_adjust_menu / helper_mode / open `menu_handle` NOT reset |
| **Stand-up** (CHANGED_LINK) | occupant | MY_SITTER="", ANIM_INDEX=FIRST_INDEX, helper_mode off (if !OLD_HELPER_METHOD) ([901-910](../[QS]sitB.lsl)) | current_menu / paging / in_*_menu NOT reset |
| **Live edit** (90300 insert) | one entry + indices ≥ insert_at | **SHIFT** not reset: MENU_LIST insert + `++current_menu/last_menu/FIRST_INDEX/ANIM_INDEX` if ≥ insert_at ([1251-1255](../[QS]sitB.lsl)) | menu_page / in_*_menu / open listen not shifted |
| **Region-crossing** | — | none (no on_rez / CHANGED_REGION handler) — rezzed object keeps state across the sim border | not a menu concern; SYNC drift handled separately via 90271 |

**Why it mostly works today — and why the rebuild changes that:** dispatch is
**name-based** (`llListFindList(MENU_LIST, label)`). A stale click after a
reseed re-looks-up the label in the *new* list → correct pose if the name
still exists, harmless `unknown→90101` if not. **The name-based addressing is
self-correcting.** The page-oriented rebuild's **index addressing is NOT** — a
stale click carrying an old index would hit the wrong *new* pose. The heap win
of index addressing costs the self-correction.

**Rebuild requirement:** one central **invalidate-on-async-change** routine
(clear the view-state block + remove the open listen), triggered by reseed,
SWAP, and stand-up alike. The compact page-oriented view-state makes this a
single clear; a short **input lock** until the next render closes the
click-race. This is the same `[verify]`-grade stale-state risk as §12 — worth
an in-world check (reseed / swap / standup with a dialog open).

## § 14 — MTYPE / ETYPE values + `B:` / select details (verified from code)

The avstock copy ships **no** `[AV]sitA/sitB`, so the QS code branches are the
authority here (not an external table). Values below are exactly what the code does.

**MTYPE** (per-channel "menu type", default 0) — touch handling, menu re-display, swap reopen:

| MTYPE | touch opens menu¹ | passes touch² | re-menu after pose pick³ | loud-swap reopen⁴ |
|---|---|---|---|---|
| 0 (default) | yes | no | yes | yes |
| 1 | yes | no | yes | no |
| 2 | yes | no | **no** | no |
| 3 | no | **yes** | yes | no |
| 4 | no | **yes** | **no** | no |

¹ sitA touch_end [738](../[QS]sitA.lsl): menu opens on touch only when `SCRIPT_CHANNEL==0 && !has_security && MTYPE<3`.
² sitA [218](../[QS]sitA.lsl): `llPassTouches(MTYPE>2)`.
³ sitB [750](../[QS]sitB.lsl): re-send 90005 unless MTYPE 2 or 4.
⁴ sitA [1464](../[QS]sitA.lsl): reopen only if `!MTYPE` (==0) and not a silent swap.

**ETYPE** (per-channel "exit type", default 1) — end-of-pose behaviour:

| ETYPE | SYNC auto-reset to FIRST¹ | unsit on non-`P:` entry² |
|---|---|---|
| 0 | no | no |
| 1 (default) | yes | no |
| 2 (exclusive) | yes | **yes** |

¹ sitB [1047-1054](../[QS]sitB.lsl): on the 90045 self-broadcast, if `OLD_SYNC == playing pose` → `ANIM_INDEX=FIRST_INDEX`. ETYPE 0 skips it.
² sitB [1035-1043](../[QS]sitB.lsl): ETYPE 2 only — if the played entry (and `num!=90010`) is **not** `P:` → `llUnSit(MY_SITTER)`.
90010 (swap-play) **ignores ETYPE** entirely (sitA [1445](../[QS]sitA.lsl), stock 90010 contract).

**`B:` button send** (sitB [769-792](../[QS]sitB.lsl)): the button's **field-2**
(the "anim" slot of its LSD entry) is `SEP`-split into `button_data`:
- `[0]` = `n` = integer **channel** to send on (SEQUENCE → 90210, see § 1).
- `[1]` = optional **msg override**; if non-empty replaces the label as the sent string.
- `[2]` = optional **id target**: `<C>`→CONTROLLER, `<S>`→MY_SITTER; absent + `CONTROLLER!=MY_SITTER` → id = `CONTROLLER|MY_SITTER`.

Send: `llMessageLinked(LINK_SET, n, msg, id)`. Lookup is scoped to the current
submenu (`llList2List(MENU_LIST, current_menu+1, 99999)`) — the § 9 copy hotspot.
This is the **one intentional** `llParseStringKeepNulls` — the positional fields
are meaningful, so empties must be kept (contrast the project-wide KeepNulls caveat).

**select handoff (90009)** — stock-compatible (`llMessageLinked(LINK_SET,90009,"",<avatar>)`):
- **render-time** (sitB [197](../[QS]sitB.lsl)): when `(animation_menu_function==-1 ‖ len(MENU_LIST)<2) && !helper_mode && select_present()` → the menu *is* the seat-picker; sitB hands off instead of rendering.
- **`[BACK]` at root** (sitB [837](../[QS]sitB.lsl)): `current_menu==-1 && select_present()` → 90009.
- [QS]select [381-383](../[QS]select.lsl): `num==90009 → menu(id)` renders the seat picker to the avatar in `id`. select uses **only** `id`; the msg field (CONTROLLER vs "") is ignored.
