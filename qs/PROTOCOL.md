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
| `90023` | between stock `90022` and `90050` | `[QS]boot` → all: emitted at the end of the seed cascade. `[QS]sitB` re-reads MENU_LIST from LSD on receipt, eliminating the manual-reset step after a notecard re-save. |
| `90024` | same | `[QS]boot` → all: emitted BEFORE the LSD wipe + `llResetScript` on a notecard re-save. `[QS]sitA` flips `boot_done = FALSE` and `[QS]sitB` flips `iBooted = FALSE` + clears MENU_LIST so their pre-boot guards re-engage during the re-seed window (would otherwise serve stale data until the matching `90023` arrives at the end of `finalize_boot`). |
| `90031` | same | Quiet sibling of stock `90030` (swap sitters). Identical payload (msg = source slot, id = target slot) and `[QS]sitA` runs the same swap logic, but it sets the per-swap `bSilentSwap` flag so the post-swap pose-menu reopen in `run_time_permissions` is suppressed. Used by HUD-driven swap senders (`[QS]hudadmin` SWAP-picker, `[QS]hudproxy` 2-slot quick-swap) and stress-test senders (`[QS]debug`) that don't want to thrust a fresh pose dialog on top of the user's existing UI context. Stock 90030 senders (pose-menu `[SWAP]` click, `[QS]select` seat picker) keep stock-AVsitter reopen behavior. `[QS]prop` (≥ 1.001) handles 90031 with the same cleanup as 90030 — removes both slots' props including the worn Quicky-HUD, so the old HUD detaches (and restores the RLV hover height) before the 90070-driven re-attach rezzes its successor. |
| `90077` | between stock `90076` and `90090` | `[QS]boot` → `[QS]sitB`: boot self-check probe ("is the menu pipeline present?"). Sent once from boot's `state_entry`. See [§ Boot self-check](#boot-self-check--90077--90078). |
| `90078` | same | `[QS]sitB` → `[QS]boot`: boot self-check reply. Sent in response to `90077`. |
| `90079` | between stock `90076` and `90088` | `[QS]boot` → all presence plugins: `QS_ALIVE_CENSUS`. Broadcast on a plugin add/remove (`changed(CHANGED_INVENTORY)` with the notecard asset key unchanged) and at the end of every `finalize_boot`. Each plugin re-writes its `qs:alive:<name>` LSD flag in response; a removed plugin can't, so its flag stays cleared. See [§ qs:alive](#qsalive--lsd-presence-flags). |
| `90088`–`90092` | (retired 0.9951) | Former presence HELLO broadcasts (`QS_OFFSET_HELLO` / `QS_PROP_HELLO` / `QS_FACES_HELLO` / `QS_ADJUSTER_HELLO` / `QS_SELECT_HELLO`). Replaced by `qs:alive:*` LSD flags read on demand — see [§ qs:alive](#qsalive--lsd-presence-flags). Numbers left reserved (not reused) so a stale stock/older plugin sending them is harmlessly ignored. |
| `90093` | same | bidirectional hudproxy presence (`QS_HUDPROXY_HELLO`). `[QS]adjuster` → hudproxy: msg `"PROBE"`, id `""`. hudproxy → `[QS]adjuster`: msg `"HELLO"`, id `<script_name>` (sent unsolicited on hudproxy's state_entry and as reply to `"PROBE"`). adjuster arms a 1 s timer after sending PROBE; if no HELLO arrives → hudproxy has been removed from the linkset → delete the stale `QPP_CFG:ADJUSTMODE` LSD key so sitB stops showing `[QUICKYHUD]` and stops rendering the qh_on-enriched pose menu. See [§ HUDPROXY presence](#hudproxy-presence--90093). |
| `90094` | between stock `90076` and `90100` | `[QS]boot` → all plugins: QSDUMP probe ("announce yourself if DUMP-capable") |
| `90095` | same | DUMP plugin → `[QS]boot`: QSDUMP hello (id = announcer's script name) |
| `90096` | same | plugin → `[QS]sitA`: QSALIVE presence probe |
| `90097` | same | `[QS]sitA` (slot 0) → plugin: QSALIVE reply / boot-announce |
| `90098` | same | `[QS]adjuster` → `[QS]boot`: "start dump for channel". `id` is the mode marker (`"quiet"` → web-only output, anything else → stock-style loud chat). |
| `90099` | same | `[QS]boot` → self: dump tick |
| `90212` | between stock `90211` and `90230` | plugin → `[QS]sitB`: `QSPLUG_REGISTER` — register a button into the `[OPTIONS]` top-level menu. msg = `<label>\|<click_chan>\|<scriptName>`, id = `""`. sitB dedupes by scriptName so a plugin reset overwrites instead of duplicates. Click dispatched directly to `<click_chan>` (msg = label, id = controller key) — no adjuster hop. See [§ QSPLUG_REGISTER](#qsplug_register--dynamic-options-menu). |
| `90213` | same free band | plugin → `[QS]sitB`: `QSADJ_REGISTER` — register a button into the `[ADJUST]` submenu (not `[OPTIONS]`). msg = `<label>\|<click_chan>\|<scriptName>\|<flags>`, id = `""`. `flags` bit 0 = owner-only (render + dispatch gated to `llGetOwner()`, like `[QUICKYHUD]`). sitB dedupes by scriptName; click dispatched to `<click_chan>` with the same `<controller>\|<sitter>` composite-id rule as the notecard `ADJUST` line. sitB ≥ 1.04. See [§ QSADJ_REGISTER](#qsadj_register--dynamic-adjust-submenu). |
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
| 90097  | `[QS]sitA` → plugin    | `<product>\|<ver>\|<sitters>\|<caps>`    | `""` | Presence reply. Also broadcast unsolicited by slot 0 after every LSD (re)load — fresh boot, own reset, notecard re-seed. |

**Reply payload** (pipe-delimited, parse with `llParseString2List` — see
[MEMORY.md note on KeepNulls](../../.claude/projects/.../feedback_lsl_parse_nulls.md)):

| Field | Content                                                              |
|-------|----------------------------------------------------------------------|
| 0     | Product token. Always `QuickySitter` for this fork. Future forks (or upstream) may set their own.|
| 1     | Version string. Mirrors the global `version` in [`[QS]sitA.lsl`](./[QS]sitA.lsl). |
| 2     | Sitter-slot count, identical to `get_number_of_scripts()`. Plugins can use this directly instead of running the legacy inventory loop. |
| 3     | Capability CSV. Substring-match for individual features. Initial set: `customs90260` (personal-offset cache, see [§ Personal pose offsets](#personal-pose-offsets--qsoffset--qssita)), `dump90098` (DUMP cascade, see [§ DUMP](#dump--entirely-in-qsboot)), `offsetlsd_v1` (offset.lsl ≥ 0.04 supports persistent LSD storage at `QSO:<short>:<slot>:<pose>`; gates plugin migrations from older volatile-only releases). |

### Who answers, when, and on which link

- Only the **slot-0** `[QS]sitA` answers `90096` (`if (SCRIPT_CHANNEL == 0)`),
  so a multi-sitter prim sends exactly one `90097` per probe — plugins
  don't have to deduplicate.
- Both probe and reply use `LINK_SET` so plugins in child prims see
  them.
- Slot 0 emits one unsolicited `90097` at the end of every
  `qs_load_from_lsd()` — reached from `state_entry` when the linkset is
  already seeded (own reset), and from boot's `QS_BOOT_RELOAD` broadcast
  on a fresh boot and on every notecard re-seed. Plugins that came up
  before sitA missed any earlier replies; this lets them latch onto QS
  without having to send a probe themselves. Plugins that come up
  *after* sitA still get an answer via the normal probe path.

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
`90097` on its own reset and after every notecard re-seed (each ends in
a fresh LSD load), but the plugin can also pull on demand.

## qs:alive — LSD presence flags

Plugin presence ("is `[QS]faces` installed?") used to be pushed via HELLO
link-messages (90088–90092) that the consumer cached. That had two costs:
a boot-time broadcast storm (every plugin announced, and re-announced on
every QSALIVE reply — an N×M cascade that pressured the heap during the
heap-critical boot window), and fragility — a broadcast that arrives while
the receiver is still loading is silently lost (see the `state running`
note in [`[QS]sequence.lsl`](./[QS]sequence.lsl)).

Presence is now a set of **LSD flags**, read synchronously on demand. An
`llLinksetDataRead` can't be "missed" like an event, so the boot race is
gone, and the flags live in linkset storage rather than script heap.

### Keys

| Key | Owner | Read by |
|-----|-------|---------|
| `qs:alive:faces` | `[QS]faces` | `[QS]sitB` (`[FACES]`), `[QS]adjuster` (`[FACE]`) |
| `qs:alive:prop` | `[QS]prop` | `[QS]adjuster` (`[PROP]`), `[QS]boot` (self-check) |
| `qs:alive:select` | `[QS]select` | `[QS]sitB` (`select_present()`) |
| `qs:alive:rlv` | `[QS]root-RLV` | `[QS]sitB` (`rlv_present()` → `Control...` gate) |
| `qs:alive:adjuster` | `[QS]adjuster` | `[QS]sitB` (`[HELPER]`/`[QUICKYHUD]`) |
| `qs:offset:alive` | `[QS]offset` | `[QS]sitA`, hudproxy (cross-repo) |

`qs:offset:alive` keeps its pre-existing name (not `qs:alive:offset`)
because hudproxy in the QuickyHUD repo already reads it.

### Lifecycle

- **Publish:** each plugin writes its flag (`"1"`) early in `state_entry`,
  before its notecard load, so the flag is up long before any consumer
  reads it (consumers read at menu-build time — a user action seconds
  after boot).
- **Read:** consumers read on demand at menu-build time and never cache —
  caching would re-introduce the boot race.
- **Re-census (`QS_ALIVE_CENSUS`, 90079):** `[QS]boot` broadcasts this on
  a plugin add/remove and at the end of every `finalize_boot`. On
  add/remove boot first wipes all `qs:alive:*` + `qs:offset:alive`, then
  broadcasts — synchronously, so survivors' re-writes are strictly later
  events (no clear-vs-rewrite race). A removed plugin can't re-write, so
  its flag stays cleared: that is the removal detection (it replaced
  sitB's old per-name inventory probe). The `finalize_boot` broadcast
  re-stamps the flags after a full LSD reset (wipe-retry path) and
  re-confirms any plugin that became ready only after its own
  `state_entry` write.

### Relationship to QSALIVE (90096/90097)

QSALIVE stays — but only for the **sitter count / version / caps** payload
plugins need for SITTERS list-sizing. Presence is no longer part of it;
the 90097 reply no longer triggers any presence re-announce.

## QSPLUG_REGISTER — dynamic [OPTIONS] menu

Adding a top-level menu entry for a plugin used to require editing
`[QS]sitA` and/or `[QS]sitB`: a new capability flag, a new HELLO
channel (90089/90090/90091/90093 etc.), a new `if` clause in a menu
builder, and often a back-routing handler in `[QS]adjuster`. That's
fine for the fork-owned plugins but a high bar for third-party
extensions.

QSPLUG_REGISTER is the plug-and-play alternative. A plugin announces
its button at runtime via one link-message; `[QS]sitB` exposes a new
top-level `[OPTIONS]` button (parallel to `[ADJUST]`) that opens a
dedicated dialog listing every registered plugin. Clicks dispatch
straight back to the plugin's chosen channel. No sitA / adjuster
edits, no builtin-mix in the dialog.

**Self-hiding:** `[OPTIONS]` only appears in the pose menu when the
registry is non-empty. A furniture with no plug-and-play plugins
installed looks identical to pre-0.908.

| Num    | Direction              | `msg`                                | `id`             | Meaning |
|--------|------------------------|--------------------------------------|------------------|---------|
| 90212  | plugin → `[QS]sitB`    | `<label>\|<click_chan>\|<scriptName>`| `""`             | "Add this button to the `[OPTIONS]` menu." |
| `<click_chan>` | `[QS]sitB` → plugin | `<label>` | `<controller-key>` | "User clicked your button." Fired when the avatar picks the button in the `[OPTIONS]` dialog. |

**Announce payload** (pipe-delimited, parse with `llParseString2List`):

| Field | Content |
|-------|---------|
| 0     | Button label as shown in the dialog, e.g. `[MYPLUGIN]`. Convention: bracket-wrapped uppercase for parity with built-in buttons. |
| 1     | Click channel — the LinkMessage `num` sitB fires on click. Pick a number outside the fork-reserved ranges in this document (90212–90229 is a free band; 90232–90259 is another). Plugin authors should document their picks to avoid collisions. |
| 2     | `llGetScriptName()` of the announcing script. Used as dedupe key: a re-announce (on reset / inventory change / QSALIVE-reply) overwrites the existing registry slot instead of appending a duplicate. |

### sitB side

sitB caches registrations in a strided-3 RAM list `QSPLUG_REGISTRY =
[label, click_chan, scriptName, ...]`. When the registry is non-empty,
sitB renders `[OPTIONS]` in the pose menu's right-column buttons
(next to `[ADJUST]`). Clicking `[OPTIONS]` opens a dedicated dialog
that lists every registered label with automatic paging
(`[<<]`/`[>>]`) when more than ~10 plugins are installed.

When the user clicks a registered button, sitB sends
`llMessageLinked(LINK_SET, click_chan, label, controller_key)`. The
plugin receives that in its own `link_message` handler and reacts as
it sees fit — no message round-trip through sitA or adjuster.

**Label collision with AVpos content:** an AVpos item named
`[OPTIONS]` (e.g. a legacy `BUTTON [OPTIONS]|<chan>` wired to an
external plugin) takes precedence on click — sitB's page-content
dispatch runs before the built-in `[OPTIONS]` handler (since sitB
1.001), the same precedence every other built-in button has. The
plugin entry still renders alongside it, so the pose menu then shows
two `[OPTIONS]` buttons that both dispatch to the AVpos item, making
the plugin dialog unreachable. Avoid the `[OPTIONS]` label in AVpos
notecards on furniture that also carries QSPLUG_REGISTER plugins.

### Adoption pattern for plugin authors

```lsl
integer QSPLUG_REGISTER = 90212;
integer MY_CLICK_CHAN   = 90234;  // pick a free number, document it

register_button()
{
    llMessageLinked(LINK_SET, QSPLUG_REGISTER,
        "[MYPLUGIN]|" + (string)MY_CLICK_CHAN + "|" + llGetScriptName(),
        "");
}

default
{
    state_entry()       { register_button(); }
    changed(integer c)  { if (c & CHANGED_INVENTORY) register_button(); }

    link_message(integer s, integer num, string msg, key id)
    {
        if (num == 90097) { register_button(); return; } // re-announce on sitA reset
        if (num == MY_CLICK_CHAN)
        {
            // id = controller key, msg = label
            // ... your handler ...
            return;
        }
    }
}
```

### Limits and v1 scope

- **`[OPTIONS]` and `[ADJUST]` are registry targets; the main strip
  is not.** `[OPTIONS]` is the QSPLUG_REGISTER target (this section);
  the `[ADJUST]` submenu is the QSADJ_REGISTER target (next section,
  sitB ≥ 1.04). The pose menu's main button strip (`[NEW]`, `[DUMP]`,
  etc.) is still not a registry target — those need a direct sitB
  patch. The legacy notecard `ADJUST` line remains a boot-time
  equivalent of a QSADJ_REGISTER entry (but without the owner-gate
  flag — it always renders for any sitter).
- **No active staleness probe in v1.** If a plugin script crashes
  silently between announces, its label stays in the registry until
  sitB resets (which re-issues a 90097 broadcast, prompting all
  surviving plugins to re-announce). `CHANGED_INVENTORY` in the
  plugin → re-announce is the recommended path; script removal is
  not detected actively. v2 may add a probe channel mirroring
  HUDPROXY's 90093 pattern.
- **Order = announce order.** First plugin to register gets the first
  slot in the `[OPTIONS]` dialog. No priority field in v1.
- **Click `id` is the controller key only.** sitA's legacy
  `<controller>|<sitter>` composite (used by the 90101 ADJUST_MENU
  dispatch when `AMENU & 4` is unset) is not emulated. Plugins that
  need the sitter key can request it via QSALIVE or via the
  sitter-list LSD keys (`qs:sitter:<ch>`).

## QSADJ_REGISTER — dynamic [ADJUST] submenu

The sibling of QSPLUG_REGISTER for the `[ADJUST]` submenu instead of
the top-level `[OPTIONS]` menu. Use it for owner/setup tools that
belong next to `[TEXTURE]` / `[HELPER]` / `[QUICKYHUD]` rather than in
the plug-and-play `[OPTIONS]` list. Available since sitB 1.04.

A plugin announces its button at runtime; sitB renders it in the
`[ADJUST]` dialog and dispatches clicks straight back to the plugin's
channel — no sitA / adjuster edits. It replaces the legacy AVpos
`ADJUST <label>|<chan>` line: the creator no longer hand-edits the
AVpos, and (unlike that line) the entry carries an owner-gate flag.

**Self-show:** when a registered entry visible to the current
controller exists, `[ADJUST]` appears on the root pose menu even if
`AMENU` is off — parallel to `[OPTIONS]`'s self-hide. Owner-only
entries don't trigger the self-show for a non-owner.

| Num    | Direction              | `msg`                                         | `id` | Meaning |
|--------|------------------------|-----------------------------------------------|------|---------|
| 90213  | plugin → `[QS]sitB`    | `<label>\|<click_chan>\|<scriptName>\|<flags>`| `""` | "Add this button to the `[ADJUST]` submenu." |
| `<click_chan>` | `[QS]sitB` → plugin | `<label>` | `<controller>` or `<controller>\|<sitter>` | "User clicked your button." Composite id when `AMENU & 4` is unset, same as the notecard `ADJUST` line. |

**Announce payload** — fields 0–2 are identical to QSPLUG_REGISTER
(label, click channel, scriptName-as-dedupe-key). Field 3 is new:

| Field | Content |
|-------|---------|
| 3     | `flags` — integer bitfield. Bit 0 (`1`) = **owner-only**: sitB renders and dispatches the entry only when the controller is `llGetOwner()`, exactly like `[QUICKYHUD]`. `0` = visible to any seated avatar (parity with notecard `ADJUST` entries and QSPLUG_REGISTER buttons). |

**Owner-gate caveat (legacy coexistence).** The gate is sitB-side. If a
furniture also keeps the legacy `ADJUST <label>|<chan>` notecard line with
the SAME label, that line is ungated and its `ADJUST_MENU` dispatch runs
first — so an owner-only registry entry is defeated by a coexisting legacy
line. Remove the legacy line when adopting an owner-only registry entry,
and (defense-in-depth) have the plugin re-check `llGetOwner()` in its own
click handler.

**sitB side.** sitB caches registrations in a strided-4 RAM list
`ADJUST_DYN = [label, click_chan, scriptName, flags, ...]`, deduped by
scriptName. `adjust_dialog` renders the notecard `ADJUST_MENU` entries
first, then the visible `ADJUST_DYN` labels (skipping any label already
present in `ADJUST_MENU`, so a legacy AVpos line + the registry don't
double up). The owner gate is enforced both at render and at click
dispatch. `ADJUST_DYN` is RAM only — never written to or rebuilt from
`qs:cfg`, so a boot re-seed leaves it intact; a sitB reset clears it,
and the plugin re-announces on the next 90097 (QSALIVE reply), the
same recovery path QSPLUG_REGISTER uses.

**Adoption pattern** — identical to QSPLUG_REGISTER (`register_*` on
`state_entry` / `on_rez` / `CHANGED_INVENTORY` / 90097) but on channel
90213 with the trailing `flags` field, e.g.
`"[MYTOOL]|" + (string)MY_CLICK_CHAN + "|" + llGetScriptName() + "|1"`
for an owner-only tool.

## HUDPROXY presence — 90093

QuickyHUD's `[QS]hudproxy` writes the `QPP_CFG:ADJUSTMODE` LSD key
unprotected on its `state_entry`. `[QS]sitB` gates QuickyHUD-aware UI
on the key's existence/value (both pieces moved from sitA in the 0.910
ADJUST-dialog refactor):
- the `[QUICKYHUD]` button in the Adjust dialog, rendered if the key
  exists.
- the enriched main pose menu (`[NEW]`/`[DUMP]`/`[ADJUST OFF]`)
  if `value == "On"`.

**Problem:** LSD outlives script removal. If the creator removes
hudproxy + hudadmin from the linkset after first install, the LSD key
persists with whatever value it last had. sitB keeps showing
`[QUICKYHUD]` (clicks no-op because nobody handles 90266) and
stays stuck in the qh_on-enriched menu forever if the key happened to
be `"On"` at removal time — including a non-functional `[ADJUST OFF]`
button.

**Fix:** 90093 active-presence probe.

| Num | Direction | msg | id | Meaning |
|-----|-----------|-----|----|---------|
| 90093 | `[QS]adjuster` → hudproxy | `"PROBE"` | `""` | "Are you still there?" |
| 90093 | hudproxy → `[QS]adjuster` | `"HELLO"` | `<script_name>` | Presence reply. Also broadcast unsolicited from hudproxy's `state_entry`. |

### adjuster side

```lsl
integer QS_HUDPROXY_HELLO = 90093;
integer hudproxy_present;

state_entry()
{
    hudproxy_present = FALSE;
    llMessageLinked(LINK_SET, QS_HUDPROXY_HELLO, "PROBE", "");
    llSetTimerEvent(1.0);
    // ...
}

link_message(integer s, integer num, string msg, key id)
{
    if (num == QS_HUDPROXY_HELLO && msg == "HELLO")
    {
        hudproxy_present = TRUE;
        llSetTimerEvent(0.0);
        return;
    }
    // ...
}

timer()
{
    llSetTimerEvent(0.0);
    if (!hudproxy_present)
        llLinksetDataDelete("QPP_CFG:ADJUSTMODE");
}
```

`changed(CHANGED_INVENTORY)` already calls `llResetScript()` in
adjuster, so a script removal triggers a fresh `state_entry` → re-probe
automatically. No separate inventory-change probe path needed.

### hudproxy side

```lsl
integer QS_HUDPROXY_HELLO = 90093;

state_entry()
{
    // ... existing init ...
    llMessageLinked(LINK_SET, QS_HUDPROXY_HELLO, "HELLO", llGetScriptName());
}

link_message(integer s, integer num, string str, key id)
{
    if (num == QS_HUDPROXY_HELLO && str == "PROBE")
    {
        llMessageLinked(LINK_SET, QS_HUDPROXY_HELLO, "HELLO", llGetScriptName());
        return;
    }
    // ...
}
```

### Self-message suppression

LSL suppresses self-delivery of `llMessageLinked` to the same script,
so adjuster's own `"PROBE"` doesn't loop back into its 90093 handler.
The `msg == "HELLO"` discriminator is defensive — if a future
QuickyHUD script also writes to 90093, only HELLO messages set the
flag.

## Boot self-check — 90077 / 90078

`[QS]boot` verifies the minimum base scripts are present in the linkset
right after seeding. Two failure modes get surfaced as `llOwnerSay`
errors so the creator catches a missing-script install before the first
sit attempt instead of seeing a silent no-menu / no-animation furniture:

1. **Hard-fail:** `[QS]sitA` or `[QS]sitB` missing — no animation or no
   menu. Sets `llSetText` red so the prim is visibly broken in-world.
2. **Conditional warn:** `AVpos` has `PROP*` directives but `[QS]prop`
   is not installed — props won't be rezzed.

Adjuster presence is deliberately **not** checked. `[QS]sitB` already
gates the `[HELPER]` / `[QUICKYHUD]` menu items on the `qs:alive:adjuster`
LSD flag, so an end-user (read-only) install just doesn't expose the Adjust
path — nothing is broken from the user's view.

| Num    | Direction              | `msg`  | `id`       | Meaning |
|--------|------------------------|--------|------------|---------|
| 90077  | `[QS]boot` → `[QS]sitB` | `""`  | `""`       | Probe — "is the menu pipeline present?" Sent once from boot's `state_entry`. |
| 90078  | `[QS]sitB` → `[QS]boot` | `""`  | `""`       | Hello — reply to 90077. One reply per probe is enough; boot's handler only sets a flag. |

### Boot side

```lsl
integer QS_SITB_PROBE = 90077;
integer QS_SITB_HELLO = 90078;
integer sita_seen;
integer sitb_seen;
integer has_prop_in_notecard;
integer selfcheck_pending;

state_entry()
{
    // ... existing seed setup ...
    llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");  // sitA via 90097
    llMessageLinked(LINK_SET, QS_SITB_PROBE, "", "");  // sitB via 90078
}

link_message(integer s, integer num, string msg, key id)
{
    if (num == QSALIVE_REPLY) { sita_seen = TRUE; return; }
    if (num == QS_SITB_HELLO) { sitb_seen = TRUE; return; }
    // ...
}

finalize_boot()
{
    // ... existing seed-finalize ...
    selfcheck_pending = TRUE;
    llSetTimerEvent(1.0);  // 1s window for replies; AUTOSYNC armed after
}

timer()
{
    if (selfcheck_pending)
    {
        selfcheck_pending = FALSE;
        llSetTimerEvent(0);
        self_check_report();
        arm_autosync();
        return;
    }
    // ... existing AUTOSYNC tick ...
}
```

`PROP*` detection rides on the existing notecard parser: one extra
`if (command == "PROP1" || command == "PROP2" || command == "PROP3")`
branch in `dataserver` sets `has_prop_in_notecard = TRUE`. The
`[QS]prop` presence check reuses `dump_plugins` (populated by QSDUMP
announces — see [§ QSDUMP](#qsdump--plugin-announce-for-the-dump-cascade))
so no extra probe is needed.

### sitB side

```lsl
integer QS_SITB_PROBE = 90077;
integer QS_SITB_HELLO = 90078;

link_message(integer s, integer num, string msg, key id)
{
    if (num == QS_SITB_PROBE)
    {
        llMessageLinked(LINK_SET, QS_SITB_HELLO, "", "");
        return;
    }
    // ...
}
```

No state_entry broadcast — the boot self-check is one-shot at boot
time, sitB is the responder. If `[QS]boot` is missing or reset later,
nothing happens (no probe → no reply, no error). This is intentional:
the self-check is for **install verification**, not runtime presence.

### sitA reuses QSALIVE, not a separate probe

`[QS]sitA` (slot 0) already broadcasts `90097` at the end of every
`qs_load_from_lsd()` (see
[§ QSALIVE](#qsalive--presence-probe-for-plugin-discovery)). Boot
just listens. No new probe number for sitA.

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
| 90260  | `[QS]offset` → `[QS]sitA` + `[QS]hudproxy` | `pose_name\|pos\|rot` | sitter UUID       | "Mirror this RAM-tier personal offset into your local cache." Sent once per matching RAM-tier entry when a sitter sits (in response to 90261), and once per RAM-tier `save_offset` so the writer's sitA stays in sync immediately. **LSD-tier offsets are not pushed via 90260** — sitA reads `QSO:*` directly from LSD on demand (via `lookup_personal_offset`); hudproxy does the same in `lookupEffectiveOffset`. **ZERO/ZERO payload is the delete sentinel**: `save_offset` emits it whenever it removed an entry; sitA drops the matching `RAM_OVERFLOW` entry, hudproxy drops the matching `ramMirror` entry. Both receivers filter pushes that don't target their tracked sitter (sitA by slot, hudproxy by sitter UUID in JSON entry). |
| 90261  | `[QS]sitA` → `[QS]offset`  | `(string)slot`       | sitter UUID       | "Push every RAM-tier cached offset for this (sitter, slot) pair to me." Sent on sit and on hudproxy pose change. The push only enumerates `CUSTOMS` (RAM tier); `[QS]offset` does not scan LSD on this request. |
| 90262  | `[QS]sitA` + `[QS]hudproxy` → `[QS]offset`  | `slot\|pose_name\|pos\|rot` | sitter UUID | "Save this offset for (sitter, slot, pose)." Magic name `M#T!` is the all-poses offset used by `[OFFSET ALL]`; each slot can have its own M#T!. **M#T! arrivals trigger a stock-AVsitter wipe**: before storing the new M#T! value, `[QS]offset` deletes every existing per-pose entry for this (sitter, slot) — both LSD and RAM tiers — and emits ZERO/ZERO 90260's to invalidate sitA's RAM_OVERFLOW + hudproxy's ramMirror. Without this, pre-existing per-pose entries keep winning over M#T! in `apply_current_anim` and `[OFFSET ALL]` only applies to never-adjusted poses. Hudproxy now also sends 90262 on every X+/Y+/Z+ click (immediate persist), replacing the old auto-save-on-pose-change `poseBufPush` pattern. Hudproxy does **not** mirror 90262 back into local state — the SSoT lives in `[QS]offset`, hudproxy reads fresh from there. |
| 90263  | `[QS]adjuster` → `[QS]sitA` + `[QS]offset` | `(string)sitter_slot` | pose_name (as `key`) | "The creator just overwrote this pose's default on this slot via `[HELPER] [SAVE]`. Drop every pose-specific entry on this slot that matches — `M#T!` survives, and other slots keep their offsets." sitA-side: drops the matching `RAM_OVERFLOW` entry (no-op if it was an LSD-tier offset; that one gets dropped via `[QS]offset`'s LSD-side handler). |
| 90264  | hudproxy → `[QS]offset`    | `""`                 | ignored           | "Wipe ALL personal offsets — both LSD `QSO:*` and RAM `CUSTOMS`." Triggered by the HUD settings menu's `CLEAR offset storage` confirm. Matches the `CHANGED_OWNER` cleanup behavior. `[QS]offset` follows up with a 90265 broadcast to clear all sitA `RAM_OVERFLOW` mirrors. |
| 90265  | `[QS]offset` → all `[QS]sitA` + `[QS]hudproxy` | `""`              | `NULL_KEY`        | "Clear your RAM-tier mirror." Broadcast on `wipe_all_offsets` (90264 follow-up) to keep sitA's `RAM_OVERFLOW` and hudproxy's `ramMirror` in sync with the underlying wipe. LSD-tier values don't need invalidation — the wipe is visible on next `llLinksetDataRead`. |
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
[camera_script]` per channel; the camera script name stays hardcoded
until `[QS]camera` is forked and adopts QSDUMP.

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

- `[QS]prop` — announces QSDUMP ✅; publishes the `qs:alive:prop` LSD flag
  so `[QS]adjuster` can gate the `[PROP]` menu item without an inventory
  probe (the old `QS_PROP_HELLO` 90089 broadcast was retired in 0.9951).
- `[QS]faces` — announces QSDUMP ✅; publishes the `qs:alive:faces` LSD flag
  so `[QS]sitB` can gate its `[FACES]` menu item and `[QS]adjuster` its
  `[FACE]` action without an inventory probe (the old `QS_FACES_HELLO` 90090
  broadcast was retired in 0.9951).
- `[AV]camera` — stock, hardcoded in boot's cascade. No `[QS]camera`
  fork planned: stock [AV]camera's only name-bound code
  (`get_number_of_scripts` via `main_script="[AV]sitA"`) is dead code
  (never called anywhere in the file), and all working paths are
  protocol-based and script-name-agnostic. The `camera_script` literal
  in boot stays as legitimate AVsitter-protocol surface.

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
| 90098 | `[QS]adjuster` → `[QS]boot` | `(string)channel` | mode marker | "Start streaming this channel's dump." Sent on `[DUMP]` for channel 0; boot's own 90021 cascade re-sends it for each subsequent channel (re-emits use `id=""` to leave the mode flag untouched). The `id` field on the initial trigger (msg == "0") is a mode marker: `"quiet"` flips boot's `dump_quiet` global so every `Readout_Say` call (banners included) feeds the web cache silently. The only chat lines in quiet mode are the live-view URL shouted by the 90022 V:-handler the moment the webkey is generated (`[DUMP] Live view: <url>`), plus an end-of-cascade `[DUMP] Done — link finalized.` (success) or `[DUMP] Upload failed — link may be incomplete.` (any non-200 from the QS endpoint anywhere in the cascade — `dump_failed` flag set by `http_response`). The live-view URL is clickable immediately: settings.php serves partial content with an HTTP `Refresh: 3` header until the `.done` marker lands, so the browser polls and the owner watches AVpos content grow in real time. Any other value in id (`""` from the helper `[DUMP]` path) keeps stock-style loud chat output with the URL shouted only at end-of-cascade. Endpoint selection follows the mode: loud → stock `avsitter.com/settings.php` (third-party, uncontrolled TTL), quiet → self-hosted `url_qs` (QuickyProducts infra, flat-file PHP receiver under `qs/php/`). Routing: adjuster's `[DUMP]` handler picks the marker from `helper_mode` + `QPP_CFG:ADJUSTMODE` — `[HELPER]` entry → loud, `[QUICKYHUD]` entry → quiet. boot's 90098 handler also rejects initial triggers while a cascade is already running (`qs_dump_ch != -1`) to prevent two clicks from clobbering `webkey`/`cache`/`qs_dump_pi` mid-stream. |
| 90099 | `[QS]boot` → self        | `(string)channel` | `""` | "Process the next pose entry for the channel currently being dumped." Self-trigger between ticks — gives boot's event loop a chance to drain queued 90022 echoes between iterations. |

State lives in two boot globals: `qs_dump_ch` (the channel being streamed,
`-1` when idle) and `qs_dump_pi` (next entry index). Only one channel streams
at a time.

`90021` and `90022` are stock-AVsitter numbers (not fork-specific) but their
**handlers** moved to boot along with the dump pipeline:

- `90021` (channel-done signal): boot probes plugin scripts (announced
  plugins in `dump_plugins`, plus the hardcoded `camera_script`) for the
  current channel via 90020, advances to the next channel via 90098, or
  — when no more channels — calls `web(TRUE)` to flush the cache and
  shouts the upload URL to the owner.
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

Forces every SYNC-pose sitter to re-phase its main pose loop, correcting
cross-viewer drift on multi-avatar loops. Any in-prim script may send it;
sending is one line:

```lsl
llMessageLinked(LINK_SET, 90271, "", "");
```

| Num   | Direction                                | `msg` | `id`  | Meaning |
|-------|------------------------------------------|-------|-------|---------|
| 90271 | hudproxy / any → all `[QS]sitA` slots    | `""`  | `""`  | "Every SYNC-pose sitter, do one Stop+Start cycle on your main anim now." |

`do_resync_tick()` in `[QS]sitA` applies the trigger only when **all** of
these hold — otherwise it no-ops, so a broadcast is always safe:

- current pose is a SYNC pose (name not prefixed `P:`)
- `PERMISSION_TRIGGER_ANIMATION` is granted
- sitter is alive (`llGetAgentSize != ZERO_VECTOR`)
- `CURRENT_ANIMATION_FILENAME` is non-empty

`[QS]sitA` owns none of the *when*/*how-often* policy — that lives entirely
on the sender. Mechanism (the 50 ms Stop+Start rationale), sender-side
policy, and the sitA 0.16–0.21 iteration history are documented in the
private QuickyHUD repo (`docs/resync-90271.md`) and `qs/test/TESTPLAN.md`
(TC-029).

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
