/*
 * [QS]sitB - QuickySitter memory script - needs [QS]sitA to work
 *
 * Fork of [AV]sitB from AVsitter2 (MPL 2.0).
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Original work: Copyright © the AVsitter Contributors (http://avsitter.github.io)
 * AVsitter™ is a trademark. For trademark use policy see:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string product = "QuickySitter™";
string version = "0.9958";

// Verbose convention applies (see [QS]boot header for the full ladder).
// sitB diverges from the project trio: Out/OutForce helpers are dropped
// because this script has exactly one diagnostic call site (memory()
// banner) and the helper bytecode (~300 B) competed with the (now-retired)
// MENU_LIST on
// extreme-text furniture (1000+ poses). Verbose check inlined at the
// memory() call below; AVpos `VERBOSE n` → qs:cfg:verbose LSD still
// controls it (read in state_entry).
integer verbose = 0;
string BRAND;
integer OLD_HELPER_METHOD;
// main_script global removed in 0.032: it was hardcoded "[QS]sitA"
// plus an unused channel-suffix mutation, dead since stock parity.
// The count loop in qs_load_from_lsd now derives the sitA basename
// from this script's own name (sitB → sitA replacement).
integer SET;
integer ETYPE;
integer MTYPE;
integer SWAP;
integer AMENU;
integer SCRIPT_CHANNEL;
// QSALIVE-driven sitter count cache (replaces the legacy "sitB → sitA"
// derived inventory probe). Slot-0 sitA sends an unsolicited 90097 on
// its own state_entry; we cache the count from the payload's field 2.
// Default 1 = solo behavior until the reply lands, which matches the
// safest mis-render direction (multi-sitter UI elements stay hidden).
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;
integer qs_alive      = FALSE;
integer number_of_sitters = 1;

// QS_BOOT_WIPE — broadcast by [QS]boot BEFORE its LSD wipe + reset
// when a notecard re-save invalidates the seeded state. We flip
// iBooted back to FALSE and clear the page state so menu opens / sit
// attempts hit the pre-boot guard instead of serving stale data.
// finalize_boot fires QS_BOOT_RELOAD (90023) when the re-seed
// completes.
integer QS_BOOT_WIPE      = 90024;

// QS_BOOT_RELOAD — broadcast by [QS]boot at the end of its seed cascade.
// Triggers a fresh qs_load_from_lsd() so a notecard re-save doesn't
// require a manual reset to pick up the new pose data. Resets menu
// navigation back to root since the old indices may no longer be valid.
// Since 0.905 also doubles as the initial wake-up: state_entry no
// longer sleep-polls qs:meta:<ch> — if it's absent we just return,
// QS_BOOT_RELOAD will fire qs_load_from_lsd() when boot finishes.
integer QS_BOOT_RELOAD    = 90023;

// QS_SITB_PROBE / QS_SITB_HELLO — boot self-check handshake. [QS]boot
// probes in its state_entry to verify the menu pipeline is present; we
// reply on receipt. See qs/PROTOCOL.md § QS_SITB_PROBE.
integer QS_SITB_PROBE     = 90077;
integer QS_SITB_HELLO     = 90078;

// QSPLUG_REGISTER — plug-and-play plugin-button registration. Plugin
// sends "<label>|<click_chan>|<scriptName>" on this channel (see
// PROTOCOL.md § QSPLUG_REGISTER). We cache strided 3 and dedupe by
// scriptName so a re-announce on reset / inventory change overwrites
// instead of duplicating. When the registry is non-empty, the
// animation_menu builder shows an [OPTIONS] top-level button (parallel
// to [ADJUST]); the dialog opened by [OPTIONS] lists every registered
// label and dispatches clicks straight to the plugin's click_chan.
// Internal vars keep "plugin" naming because they describe the
// plug-and-play mechanism; the user-facing label is just friendlier.
integer QSPLUG_REGISTER   = 90212;
list    QSPLUG_REGISTRY;        // [label, click_chan, scriptName, ...]
integer in_plugin_menu;         // TRUE while [OPTIONS] dialog is open;
                                // flips listen() to plugin-flavored routing
integer plugin_page;            // pagination state for [OPTIONS] dialog

// ADJUST submenu — migrated from sitA in 0.909 (Phase 2 of the
// sitB-as-UI refactor). sitA used to inline the builder in its 90101
// link_message handler and render via its own dialog(); sitB now owns
// rendering, click-dispatch, and the [AV]root-security/[QS]faces
// 90101[ADJUST] back-route. has_texture / has_security are LINK_SET-fed
// (90202/90203) — sitA keeps its own has_security for non-menu purposes
// (llPassTouches + L1454 dispatch), so both scripts maintain parallel
// copies. ADJUST_MENU comes from qs:cfg slot 14 (notecard ADJUST line,
// label|chan pairs). Plugin presence (faces / adjuster / select) is read
// on-demand from qs:alive:* LSD flags — no cached flags, no HELLO
// listeners, no removal-probe (boot's CENSUS handles removal centrally).
// See qs/PROTOCOL.md § qs:alive.
list    ADJUST_MENU;
integer has_texture;
integer has_security;
integer in_adjust_menu;         // TRUE while ADJUST dialog is open
integer adjust_page;            // pagination state for ADJUST dialog
string  helper_object = "[AV]helper";

// Set TRUE once qs_load_from_lsd() has run. Slot-0 sitB uses this in
// changed(CHANGED_LINK) to eject pre-boot sit attempts with a chat hint
// (sitA is gated on the same flag but isn't the one ejecting — keeping
// the loop here off sitA's heap-tight script).
integer iBooted;
string CUSTOM_TEXT;
string SITTER_INFO;
// Page-oriented menu state (0.9954, MENU_LIST retired — the ~30 KB flat label
// list that crashed sitB at scale). RAM is now O(visible page + nav depth):
//   page_map  = the current dialog's clickable [label, flatIdx] pairs (strided
//               2); rebuilt every render, used by dispatch (find label -> idx).
//   nav_stack = the submenu marker indices the user navigated through, the BACK
//               path (replaces last_menu + the tree-scan).
//   SLOTS     = this channel's entry count (boot's qs:cfg:slots:<ch>).
// Labels + anim/pos/rot come from qs:p:<ch>:<i> on demand; submenu structure
// (child counts, TOMENU targets) from the qs:nm/qs:nt sidecar boot writes.
// DATA_LIST/POS_ROT_LIST were already on-demand for the same reason — keeping
// sitB under the 64 KB Mono cap at scale (1000+ poses).
list page_map;
list nav_stack;
integer SLOTS;
integer helper_mode;
// has_RLV (0.9958) retired: RLV-plugin presence is now read on demand from the
// qs:alive:rlv LSD flag via rlv_present(), not the 90202 payload (see below).
integer ANIM_INDEX;
integer FIRST_INDEX = -1;
integer menu_handle;
integer menu_channel;
integer current_menu = -1;
// last_menu retired (0.9954) — BACK now pops nav_stack, which records the full
// navigated path (more faithful than one level + a tree-scan; see MENU_SPEC §4).
// (global submenu_info removed — was shadowed by the same-named local
// in animation_menu and never read outside that scope.)
integer menu_page;
key MY_SITTER;
key CONTROLLER;
string RLVDesignations;
string onSit;
integer speed_index;
// SEP = U+FFFD. Initialized at runtime via llUnescapeURL because the
// SL script editor mangles a literal U+FFFD to 0x20 (space) on upload,
// which silently splits anim names containing spaces.
string SEP;

// Read pose data straight from LSD by integer index. Returns the parsed
// list [name, type, anim, pos, rot]; "" if the index is out of range.
list qs_pose_data(integer idx)
{
    string val = llLinksetDataRead("qs:p:" + (string)SCRIPT_CHANNEL + ":" + (string)idx);
    if (val == "") return [];
    return llParseStringKeepNulls(val, ["|"], []);
}

send_anim_info(integer broadcast)
{
    list pp = qs_pose_data(ANIM_INDEX);
    string anim = llList2String(pp, 2);
    string pos  = llList2String(pp, 3);
    string rot  = llList2String(pp, 4);
    llMessageLinked(LINK_THIS, 90055, (string)SCRIPT_CHANNEL,
        llDumpList2String([
            llList2String(pp, 0),
            anim,
            pos,
            rot,
            broadcast,
            speed_index
        ], "|"));
}

memory()
{
    // Inlined Out(1, …) — see verbose-block header comment for rationale.
    if (verbose >= 1)
        llOwnerSay(llGetScriptName() + "[" + version + "] "
            + (string)SLOTS + " Items Ready, Mem="
            + (string)(65536 - llGetUsedMemory()));
}

// Bottom-up button reorder — LSL renders dialog buttons bottom-row first,
// left-to-right within each row. Used by animation_menu / plugin_dialog /
// adjust_dialog; consolidated here to avoid duplicating the 4-line slice
// pattern at three sites (~80 B bytecode win).
list reorder_dialog_buttons(list buttons)
{
    return llList2List(buttons, -3, -1)
         + llList2List(buttons, -6, -4)
         + llList2List(buttons, -9, -7)
         + llList2List(buttons, -12, -10);
}

// QS-side presence is the qs:alive:select LSD flag, read on-demand;
// falls back to the [AV]select inventory probe so a stock-AVsitter
// furniture (no QS broadcaster) still gets detected.
integer select_present()
{
    return llLinksetDataRead("qs:alive:select") != ""
        || llGetInventoryType("[AV]select") == INVENTORY_SCRIPT;
}

// RLV-plugin presence: the qs:alive:rlv flag published by [QS]root-RLV, read
// on-demand. Falls back to the stock "[AV]root-RLV" inventory probe so a
// stock-AVsitter furniture (no QS broadcaster) is still detected. Replaces the
// old has_RLV variable, which depended on [AV]root-security's 90202 probe of
// the script name "[AV]root-RLV" — that name-probe fails once RLV is the
// QS-renamed fork, so the Control... gate would never fire on a QS rig.
integer rlv_present()
{
    return llLinksetDataRead("qs:alive:rlv") != ""
        || llGetInventoryType("[AV]root-RLV") == INVENTORY_SCRIPT;
}

integer animation_menu(integer animation_menu_function)
{
    if ((animation_menu_function == -1 || SLOTS < 2) && (!helper_mode) && select_present())
    {
        llMessageLinked(LINK_SET, 90009, CONTROLLER, MY_SITTER);
    }
    else
    {
        string menu = product + version;
        if (BRAND != "")
            menu = BRAND;
        if (CONTROLLER != MY_SITTER || rlv_present())
        {
            menu += "\n\nMenu for " + llKey2Name(MY_SITTER);
        }
        menu += "\n\n";
        if (CUSTOM_TEXT != "")
        {
            menu += CUSTOM_TEXT + "\n";
        }
        if (SITTER_INFO != "")
        {
            menu += "[" + llList2String(llParseStringKeepNulls(SITTER_INFO, [SEP], []), 0);
            menu += "]";
        }
        else if (number_of_sitters > 1)
        {
            menu += "[Sitter " + (string)SCRIPT_CHANNEL + "]";
        }
        list cur_pose = qs_pose_data(ANIM_INDEX);          // [name,type,anim,pos,rot]
        string animation_file = llList2String(llParseStringKeepNulls(llList2String(cur_pose, 2), [SEP], []), 0);
        string CURRENT_POSE_NAME;
        if (FIRST_INDEX != -1)
        {
            CURRENT_POSE_NAME = llList2String(cur_pose, 0);
            menu += " [" + llList2String(llParseString2List(CURRENT_POSE_NAME, ["P:"], []), 0);
            if (llGetInventoryType(animation_file + "+") == INVENTORY_ANIMATION)
            {
                if (speed_index < 0)
                {
                    menu += ", Soft";
                }
                else if (speed_index > 0)
                {
                    menu += ", Hard";
                }
            }
            menu += "]";
        }
        // Active section's child count straight from the sidecar (boot's
        // qs:nm), O(1) — replaces the old forward-walk to the next M: marker.
        // current_menu == -1 reads the root section's count.
        integer total_items = (integer)llLinksetDataRead("qs:nm:" + (string)SCRIPT_CHANNEL + ":" + (string)current_menu);
        integer i;
        list menu_items0;
        list menu_items2;
        // qh_on lifted from L245 → here so the [DONE] add-in below can
        // reference it without re-reading LSD.
        integer qh_on = (llLinksetDataRead("QPP_CFG:ADJUSTMODE") == "On");
        if (current_menu != -1 || select_present())
        {
            // [BACK] = pose-submenu navigation (stock semantics).
            // Mode-exit lives on [DONE] (added in menu_items2 below
            // when helper_mode / qh_on) — keeping these separate so
            // [BACK] in deep pose-submenus doesn't accidentally tear
            // down ADJUSTMODE every time the user navigates up a
            // level.
            menu_items0 += "[BACK]";
        }
        string submenu_info;
        if (current_menu != -1)
        {
            submenu_info = llList2String(qs_pose_data(current_menu), 2);
        }
        // QuickyHUD ADJUSTMODE mirrors helper_mode's main-menu
        // enrichment: while the HUD is in adjust state, the user gets
        // [NEW]/[DUMP]/[SAVE] in the pose menu plus a dedicated [DONE]
        // exit button (since 0.9932). Earlier 0.992 used [BACK] for
        // the exit but that clashed with the pose-submenu navigation
        // [BACK] in deeper menus — clicking [BACK] to navigate up
        // also tore down ADJUSTMODE. [DONE] is the unified exit:
        // ends helper_mode / qh_on AND opens the adjust submenu (one
        // click). Pre-0.992 [ADJUST]/[ADJUST OFF] swap had asymmetric
        // semantics (helper's [ADJUST] meant "off and back to adjust
        // submenu"; qh's [ADJUST OFF] meant "off, stay in pose menu")
        // which surprised users — [DONE] resolves that consistently.
        // [SAVE] is needed in both modes despite ADJUSTMODE auto-saving
        // sitter pose offsets via the 90055 → qs_save_pose_offset path:
        // [PROP] in-world drag has no HUD-driven auto-save and the
        // 90101[SAVE] → PROPSEARCH broadcast in [QS]prop is the only
        // way prop positions get persisted ([QS]prop.lsl:736 explicitly
        // tells the user "Position your prop and click [SAVE]."). The
        // pose-offset re-write under qh_on is idempotent — same value.
        if (helper_mode || qh_on)
        {
            menu_items2 += "[NEW]";
            if (CURRENT_POSE_NAME != "")
            {
                menu_items2 = menu_items2 + "[DUMP]" + "[SAVE]";
            }
            menu_items2 += "[DONE]";
        }
        else if (llSubStringIndex(submenu_info, "V") != -1)
        {
            menu_items0 = menu_items0 + "<< Softer" + "Harder >>";
        }
        if (AMENU == 2 || (AMENU == 1 && current_menu == -1) || llSubStringIndex(submenu_info, "A") != -1)
        {
            // [ADJUST] is the entry button when neither mode is active.
            // In helper_mode / qh_on, [BACK] (added above) carries the
            // exit+navigate semantics — no [ADJUST]/[ADJUST OFF] here.
            if (!helper_mode && !qh_on)
                menu_items2 += "[ADJUST]";
        }
        // [OPTIONS] — top-level entry into the plug-and-play plugin menu.
        // Self-hides when the registry is empty so furniture without any
        // QSPLUG_REGISTER-using plugins looks identical to pre-0.908.
        // Only on the root menu (current_menu == -1) — submenus stay clean.
        if (current_menu == -1 && llGetListLength(QSPLUG_REGISTRY))
        {
            menu_items2 += "[OPTIONS]";
        }
        if (llSubStringIndex(onSit, "ASK") && ((current_menu == -1 && SWAP == 1) || SWAP == 2 || llSubStringIndex(submenu_info, "S") != -1) && (number_of_sitters > 1 && !select_present()))
        {
            menu_items2 += "[SWAP]";
        }
        if (current_menu == -1)
        {
            if (rlv_present() && (llGetSubString(RLVDesignations, SCRIPT_CHANNEL, SCRIPT_CHANNEL) == "D" || CONTROLLER != MY_SITTER))
            {
                menu_items2 += "[STOP]";
                if (!helper_mode)
                {
                    menu_items2 += "Control...";
                }
            }
        }
        integer items_per_page = 12 - llGetListLength(menu_items2) - llGetListLength(menu_items0);
        if (items_per_page < total_items)
        {
            menu_items2 = menu_items2 + "[<<]" + "[>>]";
            items_per_page -= 2;
        }
        // Build the visible page by reading qs:p for the window
        // [section_start + page*ipp, +ipp), bounded by the section's child
        // count (section_end = the next M: marker — replaces the old jump-end).
        // page_map records displayed-label -> flat index for dispatch.
        list menu_items1;
        page_map = [];
        integer section_end = current_menu + 1 + total_items;
        integer page_start = current_menu + 1 + menu_page * items_per_page;
        integer page_stop = page_start + items_per_page;
        i = page_start;
        while (i < page_stop && i < section_end)
        {
            string m = llList2String(qs_pose_data(i), 0); // field 0 = prefixed label
            string disp;
            if (llListFindList(["T:", "P:", "B:"], [llGetSubString(m, 0, 1)]) == -1)
                disp = m;                                 // SYNC (no prefix) shown raw
            else
                disp = llGetSubString(m, 2, 99999);       // strip the 2-char prefix
            menu_items1 += disp;
            page_map += [disp, i];
            ++i;
        }
        if (animation_menu_function == 1)
        {
            return (total_items + items_per_page - 1) / items_per_page - 1;
        }
        if (submenu_info == "V")
        {
            while (llGetListLength(menu_items1) < items_per_page)
            {
                menu_items1 += " ";
            }
        }
        // Rendering the pose menu means the user is back at the root —
        // any sub-menu state left over from a dialog-X-close
        // ([OPTIONS] or ADJUST submenu was open, user closed via the
        // dialog's X button instead of [BACK]) must clear here. Without
        // this, the next click in the freshly-rendered pose menu lands
        // in the stale in_plugin_menu / in_adjust_menu branch in listen()
        // and gets misrouted (the "Unknown click — bail back" safety
        // path), which the user sees as a phantom first-click being
        // eaten.
        in_plugin_menu = FALSE;
        plugin_page = 0;
        in_adjust_menu = FALSE;
        adjust_page = 0;
        llListenRemove(menu_handle);
        menu_handle = llListen(menu_channel, "", CONTROLLER, "");
        menu_items0 = menu_items0 + menu_items1 + menu_items2;
        llDialog(CONTROLLER, menu, reorder_dialog_buttons(menu_items0), menu_channel);
    }
    return 0;
}

// Re-derive this channel's nav sidecar (qs:nm child counts, qs:nt TOMENU
// targets, qs:cfg:slots) from qs:p — the same derivation [QS]boot does at seed
// (its qs_close_section + tomenu_pending). Used after a live [NEW] insert
// (90300): the adjuster issues one or more qs_insert_pose *before* its 90300s
// (a SUBMENU is a TOMENU + MENU pair = two inserts), so a per-insert index
// shift can't track the finished layout — rebuilding from qs:p always can, and
// it wires the new TOMENU->MENU link in the same pass. O(entries), edit-time only.
qs_rebuild_sidecar()
{
    string ch = (string)SCRIPT_CHANNEL;
    llLinksetDataDeleteFound("^qs:n[mt]:" + ch + ":", "");
    integer open_marker = -1;
    list tomenu_pending;                 // strided [key, tomenuIdx]
    integer i = 0;
    string v;
    while ((v = llLinksetDataRead("qs:p:" + ch + ":" + (string)i)) != "")
    {
        list pp = llParseStringKeepNulls(v, ["|"], []);
        string t = llList2String(pp, 1);
        if (t == "M")
        {
            llLinksetDataWrite("qs:nm:" + ch + ":" + (string)open_marker, (string)(i - open_marker - 1));
            open_marker = i;
            string mkey = llGetSubString(llList2String(pp, 0), 2, 99999);
            integer pend = llListFindList(tomenu_pending, [mkey]);
            if (pend != -1)
            {
                llLinksetDataWrite("qs:nt:" + ch + ":" + (string)llList2Integer(tomenu_pending, pend + 1), (string)i);
                tomenu_pending = llDeleteSubList(tomenu_pending, pend, pend + 1);
            }
        }
        else if (t == "T")
            tomenu_pending += [llGetSubString(llList2String(pp, 0), 2, 99999), i];
        ++i;
    }
    llLinksetDataWrite("qs:nm:" + ch + ":" + (string)open_marker, (string)(i - open_marker - 1));
    SLOTS = i;
    llLinksetDataWrite("qs:cfg:slots:" + ch, (string)i);
}

// QuickySitter: read this channel's data straight from Linkset Data instead
// of waiting for [QS]boot to dispatch 90300/90301/90302 messages. Boot is
// the only script that writes LSD during seed; it resets sitB after the
// seed finishes so this state_entry runs with populated LSD. The runtime
// 90300/90301 handlers stay for adjuster live-edits.
qs_load_from_lsd()
{
    page_map = [];
    nav_stack = [];
    FIRST_INDEX = ANIM_INDEX = -1;

    string cfg = llLinksetDataRead("qs:cfg:" + (string)SCRIPT_CHANNEL);
    list p = llParseStringKeepNulls(cfg, ["\n"], []);
    MTYPE             = (integer)llList2String(p, 0);
    ETYPE             = (integer)llList2String(p, 1);
    SET               = (integer)llList2String(p, 2);
    SWAP              = (integer)llList2String(p, 3);
    // slot 4 (SELECT) consumed by [QS]select, not used here
    AMENU             = (integer)llList2String(p, 5);
    OLD_HELPER_METHOD = (integer)llList2String(p, 6);
    BRAND             = llList2String(p, 11);
    onSit             = llList2String(p, 12);
    CUSTOM_TEXT       = llDumpList2String(llParseStringKeepNulls(llList2String(p, 13), ["\\n"], []), "\n");
    // ADJUST_MENU — label|chan|label|chan|... pairs from the notecard
    // ADJUST line. ParseString2List drops empties: boot writes "" when
    // the AVpos has no ADJUST line, and KeepNulls would turn that into
    // [""] which trips llDialog's "all buttons must have label strings".
    // Migrated from sitA 0.909 (Phase 2 of the sitB-as-UI refactor).
    ADJUST_MENU       = llParseString2List(llList2String(p, 14), [SEP], []);
    RLVDesignations   = llList2String(p, 15);

    SITTER_INFO = llLinksetDataRead("qs:sitter:" + (string)SCRIPT_CHANNEL);

    // Page-oriented load (0.9954): no MENU_LIST. The entry count comes from
    // the boot-written sidecar; the default pose (FIRST_INDEX) is the first
    // POSE/SYNC entry, found by a short scan that stops at the first hit (the
    // default sits near the top). Entries are read transiently here, never
    // held — that is the whole point of the rebuild (RAM = O(page), not O(N)).
    SLOTS = (integer)llLinksetDataRead("qs:cfg:slots:" + (string)SCRIPT_CHANNEL);
    integer i = 0;
    string val;
    while (FIRST_INDEX == -1 && (val = llLinksetDataRead("qs:p:" + (string)SCRIPT_CHANNEL + ":" + (string)i)) != "")
    {
        string type = llList2String(llParseStringKeepNulls(val, ["|"], []), 1);
        if (type == "P" || type == "S")
            FIRST_INDEX = ANIM_INDEX = i;
        ++i;
    }

    // number_of_sitters is now QSALIVE-cached (see link_message handler
    // for QSALIVE_REPLY). No inventory probe needed — slot-0 sitA owns
    // the canonical count via its own get_number_of_scripts().

    // Unsolicited HELLO broadcast — symmetric to sitA's qs_alive_reply()
    // at the end of its own qs_load_from_lsd(). Lets boot's self-check
    // see us via the same garantierten "all scripts armed by now" timing
    // (we're called either from state_entry with qs:meta already there,
    // or from the QS_BOOT_RELOAD handler well after boot's state_entry).
    // The 90077 probe-response handler stays for post-boot detection
    // (e.g. boot reset without sitB reset). Slot-0 only to avoid N-fold
    // chat-spam-equivalent on the LinkMessage bus.
    if (!SCRIPT_CHANNEL)
        llMessageLinked(LINK_SET, QS_SITB_HELLO, "", "");
}

// [OPTIONS] dialog — pure plugin-button list with paging. Called when
// the user clicks [OPTIONS] in the pose menu (gated on QSPLUG_REGISTRY
// non-empty by animation_menu). Click routing happens in listen() while
// in_plugin_menu is TRUE: registry-lookup dispatches direct to the
// plugin's click_chan; [<<]/[>>] re-render this dialog; [BACK] returns
// to the pose menu. See PROTOCOL.md § QSPLUG_REGISTER.
plugin_dialog()
{
    integer total = llGetListLength(QSPLUG_REGISTRY) / 3;
    if (total == 0)
    {
        // Defensive: registry emptied between [OPTIONS] click and here.
        in_plugin_menu = FALSE;
        animation_menu(0);
        return;
    }
    integer items_per_page = 11; // 12 dialog slots minus [BACK]
    integer pages = 1;
    if (total > items_per_page)
    {
        items_per_page -= 2; // [<<] + [>>]
        pages = (total + items_per_page - 1) / items_per_page;
    }
    if (plugin_page >= pages) plugin_page = 0;
    integer start = plugin_page * items_per_page;
    integer end = start + items_per_page;
    if (end > total) end = total;
    list page;
    integer i = start;
    while (i < end)
    {
        page += llList2String(QSPLUG_REGISTRY, i * 3);
        ++i;
    }
    list nav = ["[BACK]"];
    if (pages > 1) nav += ["[<<]", "[>>]"];
    list buttons = nav + page;
    llListenRemove(menu_handle);
    menu_channel = ((integer)llFrand(0x7FFFFF80) + 1) * -1;
    menu_handle = llListen(menu_channel, "", CONTROLLER, "");
    string text = product + " " + version + "\n\nOptions:";
    if (pages > 1) text += " (" + (string)(plugin_page + 1) + "/" + (string)pages + ")";
    llDialog(CONTROLLER, text, reorder_dialog_buttons(buttons), menu_channel);
}

// ADJUST submenu — migrated from sitA's inlined options_menu() in 0.909
// (Phase 2 sitB-as-UI refactor). Renders builtins gated by capability
// flags + notecard ADJUST_MENU pairs + tail (HELPER/QUICKYHUD/POSE),
// auto-pages when total > 12 buttons (fixes the silent-truncation bug
// in sitA's pre-0.910 dialog() that dropped overflow buttons). Click
// routing lives in listen() under in_adjust_menu, plus a 90101[ADJUST]
// receiver in link_message for external back-routes ([AV]root-security,
// [QS]faces). See PROTOCOL.md.
adjust_dialog()
{
    list builtins;
    if (has_texture)   builtins += "[TEXTURE]";
    if (llLinksetDataRead("qs:alive:faces") != "") builtins += "[FACES]";
    if (has_security)  builtins += "[SECURITY]";

    list dyn;
    integer i;
    integer n = llGetListLength(ADJUST_MENU);
    while (i < n) { dyn += llList2String(ADJUST_MENU, i); i += 2; }

    list tail;
    if (llGetInventoryType(helper_object) == INVENTORY_OBJECT && llLinksetDataRead("qs:alive:adjuster") != "")
        tail += "[HELPER]";
    // [QUICKYHUD] — owner-only entry, gated on the unprotected
    // QPP_CFG:ADJUSTMODE LSD key (same probe sitA used pre-0.910).
    // HUDPROXY presence cleanup (90093) keeps the key from going stale
    // after the HUD is removed.
    //
    // License gate (0.9935+): hudadmin writes `qs:hud:unlicensed` = "1"
    // when its protected isLicensed() check fails (Creator build with
    // no LSD token). Suppress [QUICKYHUD] in that case — the HUD
    // pipeline shouldn't be advertised for an unlicensed build.
    // Customer builds (LICENSE_SALT == 0 in hudadmin) and licensed
    // Creator builds never set the key, so the gate is a no-op for
    // the normal flow. Inverted polarity, see hudadmin's
    // ensureLicenseFlag header for the full rationale.
    if (CONTROLLER == llGetOwner() && llLinksetDataRead("qs:alive:adjuster") != ""
        && llGetListLength(llLinksetDataFindKeys("^QPP_CFG:ADJUSTMODE$", 0, 1))
        && llLinksetDataRead("qs:hud:unlicensed") != "1")
        tail += "[QUICKYHUD]";

    if (!llGetListLength(builtins) && !llGetListLength(dyn) && !llGetListLength(tail))
    {
        // Empty submenu — fall back to pose menu (parity with sitA
        // pre-0.910 L1109-1112).
        in_adjust_menu = FALSE;
        animation_menu(0);
        return;
    }
    tail += "[POSE]";

    integer fixed = 1 + llGetListLength(builtins) + llGetListLength(tail); // [BACK] + builtins + tail
    integer items_per_page = 12 - fixed;
    integer total = llGetListLength(dyn);
    integer pages = 1;
    if (items_per_page > 0 && total > items_per_page)
    {
        items_per_page -= 2; // [<<]/[>>]
        if (items_per_page < 1) items_per_page = 1;
        pages = (total + items_per_page - 1) / items_per_page;
    }
    if (adjust_page >= pages) adjust_page = 0;
    list page;
    if (items_per_page > 0)
    {
        integer start = adjust_page * items_per_page;
        page = llList2List(dyn, start, start + items_per_page - 1);
    }
    list nav = ["[BACK]"];
    if (pages > 1) nav += ["[<<]", "[>>]"];
    list buttons = nav + builtins + page + tail;

    llListenRemove(menu_handle);
    menu_channel = ((integer)llFrand(0x7FFFFF80) + 1) * -1;
    menu_handle = llListen(menu_channel, "", CONTROLLER, "");
    string text = product + " " + version + "\n\nAdjust:";
    if (pages > 1) text += " (" + (string)(adjust_page + 1) + "/" + (string)pages + ")";
    llDialog(CONTROLLER, text, reorder_dialog_buttons(buttons), menu_channel);
}

default
{
    state_entry()
    {
        SEP = llUnescapeURL("%EF%BF%BD");
        // Pick up the boot-written verbose level before any Out() call.
        string vstr = llLinksetDataRead("qs:cfg:verbose");
        if (vstr != "") verbose = (integer)vstr;
        SCRIPT_CHANNEL = (integer)llGetSubString(llGetScriptName(), llSubStringIndex(llGetScriptName(), " "), 99999);
        // QSALIVE probe — slot-0 sitA replies with the real sitter count
        // (handled in link_message below). Reply lands well before the
        // first user-driven animation_menu call, which is the first reader
        // of number_of_sitters.
        qs_alive = FALSE;
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
        // Event-driven boot. If boot already seeded this channel, load now;
        // otherwise just stay idle — QS_BOOT_RELOAD (90023) will dispatch
        // qs_load_from_lsd() when boot finishes. No sleep-poll, so the
        // furniture stays event-responsive even before boot finishes.
        // Pre-boot sit attempts are handled in changed(CHANGED_LINK) below.
        iBooted = FALSE;
        if (llLinksetDataRead("qs:meta:" + (string)SCRIPT_CHANNEL) != "")
        {
            qs_load_from_lsd();
            memory();
            iBooted = TRUE;
        }
    }

    listen(integer listen_channel, string name, key id, string msg)
    {
        string channel;
        // While the [OPTIONS] dialog is open, route clicks via the plugin
        // registry. Checked first so a page-item collision (e.g. a pose
        // happens to be named "[BACK]") never hijacks plugin-menu nav.
        if (in_plugin_menu)
        {
            if (msg == "[<<]" || msg == "[>>]")
            {
                if (msg == "[<<]")
                {
                    if (--plugin_page < 0) plugin_page = 0;
                }
                else
                {
                    ++plugin_page; // upper bound clamped in plugin_dialog
                }
                plugin_dialog();
                return;
            }
            if (msg == "[BACK]")
            {
                in_plugin_menu = FALSE;
                plugin_page = 0;
                animation_menu(0);
                return;
            }
            // Registry is strided 3 (label, click_chan, scriptName).
            // (pi % 3) == 0 guards against a pos-2 scriptName accidentally
            // matching when an avatar clicks a label that equals some
            // other plugin's script name.
            integer pi = llListFindList(QSPLUG_REGISTRY, [msg]);
            if (pi != -1 && (pi % 3) == 0)
            {
                llMessageLinked(LINK_SET,
                    llList2Integer(QSPLUG_REGISTRY, pi + 1), msg, CONTROLLER);
                return;
            }
            // Unknown click — bail back to the pose menu rather than
            // silently swallow (could be a stale registry race).
            in_plugin_menu = FALSE;
            plugin_page = 0;
            animation_menu(0);
            return;
        }
        // [OPTIONS] top-level entry. Gated in animation_menu on a non-empty
        // registry, but check here defensively too.
        if (msg == "[OPTIONS]")
        {
            if (!llGetListLength(QSPLUG_REGISTRY))
            {
                animation_menu(0);
                return;
            }
            in_plugin_menu = TRUE;
            plugin_page = 0;
            plugin_dialog();
            return;
        }
        // While the ADJUST submenu is open, route via the migrated dispatcher
        // (used to live in sitA's listen handler pre-0.910). Pose-menu paging
        // uses menu_page, ADJUST paging uses adjust_page — both [<<]/[>>]
        // handlers below check in_adjust_menu first to disambiguate.
        if (in_adjust_menu)
        {
            if (msg == "[<<]" || msg == "[>>]")
            {
                if (msg == "[<<]")
                {
                    if (--adjust_page < 0) adjust_page = 0;
                }
                else
                {
                    ++adjust_page; // upper bound clamped in adjust_dialog
                }
                adjust_dialog();
                return;
            }
            if (msg == "[BACK]")
            {
                in_adjust_menu = FALSE;
                adjust_page = 0;
                // Same path sitA used pre-0.910 (sitA L713): 90005 sends
                // the user back to the pose menu via the standard menu
                // dispatcher in 90004/90005.
                llMessageLinked(LINK_SET, 90005, "",
                    (string)CONTROLLER + "|" + (string)MY_SITTER);
                return;
            }
            if (msg == "[POSE]")
            {
                // Position/Rotation adjust dialog (adjust_pose_menu) still
                // lives in sitA — its CURRENT_POSITION + sit_using_prim_params
                // are sit-state. sitA 0.910's 90101[POSE] handler renders it.
                in_adjust_menu = FALSE;
                adjust_page = 0;
                llMessageLinked(LINK_SET, 90101,
                    llDumpList2String([SCRIPT_CHANNEL, "[POSE]", CONTROLLER, current_menu], "|"),
                    MY_SITTER);
                return;
            }
            // ADJUST_MENU notecard pair? Strided 2 (label, channel) — only
            // even indices are labels. The (ami % 2) == 0 guard prevents a
            // channel-as-string from collision-matching some other label.
            integer ami = llListFindList(ADJUST_MENU, [msg]);
            if (ami != -1 && (ami % 2) == 0)
            {
                in_adjust_menu = FALSE;
                adjust_page = 0;
                key dispatch_id = id;
                if (id != MY_SITTER && !(AMENU & 4))
                    dispatch_id = (key)((string)id + "|" + (string)MY_SITTER);
                llMessageLinked(LINK_SET,
                    llList2Integer(ADJUST_MENU, ami + 1), msg, dispatch_id);
                return;
            }
            // Built-in conditional buttons ([TEXTURE]/[FACES]/[SECURITY]/
            // [HELPER]/[QUICKYHUD]): broadcast on 90100 — adjuster +
            // external plugins ([AV]texture / [AV]root-security) listen
            // there with their label strings. Same payload format sitA
            // used in its pre-0.910 catch-all (L810).
            in_adjust_menu = FALSE;
            adjust_page = 0;
            llMessageLinked(LINK_SET, 90100,
                (string)SCRIPT_CHANNEL + "|" + msg + "|" + (string)MY_SITTER
                + "|" + (string)OLD_HELPER_METHOD, id);
            return;
        }
        // Page-oriented dispatch (0.9954): the clicked label maps to a flat
        // qs:p index via page_map (built in animation_menu). Re-validate against
        // current LSD before acting — the page can go stale under an open dialog
        // (reseed / live-insert / swap); on mismatch we re-render and drop the
        // click rather than act on a stale index (MENU_SPEC § 5 / § 13).
        integer pmi = llListFindList(page_map, [msg]);
        if (pmi != -1 && !(pmi & 1))
        {
            integer click_idx = llList2Integer(page_map, pmi + 1);
            list e = qs_pose_data(click_idx);              // [name,type,anim,pos,rot]
            string elabel = llList2String(e, 0);
            string etype  = llList2String(e, 1);
            string disp;
            if (llListFindList(["T:", "P:", "B:"], [llGetSubString(elabel, 0, 1)]) == -1)
                disp = elabel;                             // SYNC (no prefix) shown raw
            else
                disp = llGetSubString(elabel, 2, 99999);
            if (disp != msg)
            {
                animation_menu(0);                         // stale page — re-render, drop click
                return;
            }
            if (etype == "P" || etype == "S")
            {
                if (etype == "P") channel = (string)SCRIPT_CHANNEL; // POSE targets this slot; SYNC ("") broadcasts
                ANIM_INDEX = click_idx;                    // tier-1: set directly, no inbound name lookup
                llMessageLinked(LINK_THIS, 90050, (string)channel + "|" + msg + "|" + (string)SET, MY_SITTER);
                llMessageLinked(LINK_THIS, 90000, msg, channel);
                if (MTYPE != 2 && MTYPE != 4)
                {
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([id, MY_SITTER], "|"));
                }
                return;
            }
            if (etype == "T")
            {
                // qs:nt -> target MENU index, O(1) (replaces the M:/T: name-pair
                // findList). Push current_menu so [BACK] returns here.
                integer target = (integer)llLinksetDataRead("qs:nt:" + (string)SCRIPT_CHANNEL + ":" + (string)click_idx);
                // 90051 channel field = this slot (matches the pre-rebuild path,
                // where the bare-name findList miss set channel = SCRIPT_CHANNEL).
                llMessageLinked(LINK_SET, 90051, (string)SCRIPT_CHANNEL + "|" + llGetSubString(msg, 0, -2) + "|" + (string)SET, MY_SITTER);
                menu_page = 0;
                nav_stack += [current_menu];
                current_menu = target;
                animation_menu(0);
                return;
            }
            if (etype == "B")
            {
                list button_data = llParseStringKeepNulls(llList2String(e, 2), [SEP], []);
                if (llList2String(button_data, 1) != "")
                {
                    msg = llList2String(button_data, 1);
                }
                integer n = llList2Integer(button_data, 0);
                if (llGetListLength(button_data) > 2)
                {
                    id = llList2String(button_data, 2);
                    if (id == "<C>")
                        id = CONTROLLER;
                    if (id == "<S>")
                        id = MY_SITTER;
                }
                else if (CONTROLLER != MY_SITTER)
                {
                    id = llDumpList2String([CONTROLLER, MY_SITTER], "|");
                }
                llMessageLinked(LINK_SET, n, msg, id);
                return;
            }
        }
        if (msg == "[>>]" || msg == "[<<]")
        {
            if (msg == "[<<]")
            {
                if (--menu_page == -1)
                {
                    menu_page = animation_menu(1);
                }
            }
            else
            {
                if (++menu_page > animation_menu(1))
                {
                    menu_page = 0;
                }
            }
            animation_menu(0);
        }
        else if (msg == "[DONE]")
        {
            // Mode-exit (since 0.9932): clean exit from helper_mode or
            // ADJUSTMODE that also opens the adjust submenu. Separate
            // from [BACK] navigation so deep pose-submenu users can
            // still navigate up without accidentally tearing down the
            // mode. adjuster handles the actual tear-down (de-rez
            // helpers, 90266 Off) via the 90100[DONE] broadcast below.
            menu_page = 0;
            helper_mode = FALSE;
            llMessageLinked(LINK_SET, 90100,
                llDumpList2String([SCRIPT_CHANNEL, "[DONE]", CONTROLLER, OLD_HELPER_METHOD], "|"),
                id);
            in_adjust_menu = TRUE;
            adjust_page = 0;
            adjust_dialog();
            return;
        }
        else if (msg == "[BACK]")
        {
            menu_page = 0;
            if (current_menu == -1)
            {
                if (select_present())
                {
                    llMessageLinked(LINK_SET, 90009, "", id);
                }
                return;
            }
            // Pop the navigated back-path (replaces last_menu + the tree-scan
            // over the flat list). nav_stack records the exact path in, so this
            // is the faithful inverse of the T: navigation that pushed it.
            if (llGetListLength(nav_stack))
            {
                current_menu = llList2Integer(nav_stack, -1);
                nav_stack = llDeleteSubList(nav_stack, -1, -1);
            }
            else
            {
                current_menu = -1;
            }
            animation_menu(0);
        }
        else if (msg == "Control..." || msg == "[STOP]")
        {
            llMessageLinked(LINK_SET, 90100, llDumpList2String([SCRIPT_CHANNEL, msg, MY_SITTER], "|"), id);
        }
        else
        {
            // Unknown click (not a page item, not a control button) — route to
            // adjuster's [NEW] insert. current_menu (field 3) lets it insert at
            // the end of the user's current submenu, not the LSD tail. Older
            // adjusters (< 0.904) ignore the extra field.
            llMessageLinked(LINK_SET, 90101, llDumpList2String([SCRIPT_CHANNEL, msg, CONTROLLER, current_menu], "|"), MY_SITTER);
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_LINK)
        {
            // Pre-boot guard — boot's still seeding (or missing entirely)
            // and sitA's globals are zeroed. Eject any avatar attempting
            // to sit with a chat hint so they retry once we're ready.
            // Only slot-0 sitB runs the eject loop; otherwise every sitB
            // would call llUnSit / llRegionSayTo N times for one sit attempt.
            if (!iBooted && !SCRIPT_CHANNEL)
            {
                integer p = llGetNumberOfPrims();
                while (p > 0)
                {
                    key k = llGetLinkKey(p);
                    if (llGetAgentSize(k) != ZERO_VECTOR)
                    {
                        llRegionSayTo(k, 0, llGetObjectName()
                            + ": still loading, please try again in a moment.");
                        llUnSit(k);
                    }
                    --p;
                }
                return;
            }
            if (llGetAgentSize(llGetLinkKey(llGetNumberOfPrims())) == ZERO_VECTOR)
            {
                speed_index = 0;
                if (!OLD_HELPER_METHOD)
                {
                    helper_mode = FALSE;
                }
                MY_SITTER = "";
                ANIM_INDEX = FIRST_INDEX;
            }
            else
            {
                if (OLD_HELPER_METHOD)
                {
                    helper_mode = FALSE;
                }
            }
        }
        // No CHANGED_INVENTORY handling needed: plugin presence is read
        // on-demand from qs:alive:* (always current), and boot's CENSUS
        // handles removal detection centrally. See qs/PROTOCOL.md § qs:alive.
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        integer one = (integer)msg;
        integer two = (integer)((string)id);
        integer index;
        list data;
        if (num == QSALIVE_REPLY)
        {
            // Slot-0 sitA reports the real sitter count. Use it as the
            // canonical number_of_sitters source.
            list d = llParseString2List(msg, ["|"], []);
            if (llList2String(d, 0) == "QuickySitter")
            {
                qs_alive = TRUE;
                number_of_sitters = (integer)llList2String(d, 2);
            }
            return;
        }
        // [QS]select / faces / adjuster presence is no longer cached from
        // HELLO broadcasts — it's published to qs:alive:* LSD flags and
        // read on-demand by select_present() / adjust_dialog(). See
        // qs/PROTOCOL.md § qs:alive.
        if (num == QS_SITB_PROBE)
        {
            // Boot self-check probe — reply once. One HELLO per probe is
            // enough; boot's handler only sets a flag.
            llMessageLinked(LINK_SET, QS_SITB_HELLO, "", "");
            return;
        }
        if (num == QS_BOOT_WIPE)
        {
            // Notecard re-save: boot is about to wipe LSD and reseed.
            // Drop iBooted so the slot-0 pre-boot eject re-engages on
            // any sit attempt during the re-seed window. Clear the page
            // state AND the open dialog/listen so a stale menu can't be
            // rendered or clicked between the wipe and QS_BOOT_RELOAD
            // (MENU_SPEC § 13 — full view-state invalidation). helper_mode
            // is deliberately kept: the occupant is unchanged and may still
            // be mid-adjust.
            iBooted = FALSE;
            page_map = [];
            nav_stack = [];
            current_menu = -1;
            menu_page = 0;
            in_plugin_menu = FALSE;
            plugin_page = 0;
            in_adjust_menu = FALSE;
            adjust_page = 0;
            llListenRemove(menu_handle);
            return;
        }
        if (num == QS_BOOT_RELOAD)
        {
            // Boot finished re-seeding LSD. Re-read the page state and reset
            // menu navigation — old indices point into the stale list.
            // Also marks iBooted TRUE so the slot-0 pre-boot eject guard
            // disengages (covers both initial wake-up and re-seeds).
            qs_load_from_lsd();
            current_menu = -1;
            nav_stack = [];
            menu_page = 0;
            iBooted = TRUE;
            return;
        }
        if (num == QSPLUG_REGISTER)
        {
            // PROTOCOL.md § QSPLUG_REGISTER. ParseString2List (not
            // KeepNulls) — see memory note on KeepNulls regressions.
            list pp = llParseString2List(msg, ["|"], []);
            string label = llList2String(pp, 0);
            integer chan = (integer)llList2String(pp, 1);
            string sName = llList2String(pp, 2);
            if (label == "" || chan == 0 || sName == "")
            {
                // Malformed announce — ignore. Plugin author bug, not ours.
                return;
            }
            // Dedupe by scriptName so a re-announce on plugin reset /
            // inventory change overwrites instead of appending a duplicate.
            integer ri = 0;
            integer rn = llGetListLength(QSPLUG_REGISTRY);
            while (ri < rn && llList2String(QSPLUG_REGISTRY, ri + 2) != sName)
                ri += 3;
            if (ri < rn)
                QSPLUG_REGISTRY = llListReplaceList(QSPLUG_REGISTRY,
                    [label, chan, sName], ri, ri + 2);
            else
                QSPLUG_REGISTRY += [label, chan, sName];
            return;
        }
        if (num == 90000 || num == 90010 || num == 90003 || num == 90008)
        {
            // Resolve the pose name to a flat index without MENU_LIST. Tier-1:
            // if ANIM_INDEX already holds it (self-play set it at click, or a
            // replay), reuse — O(1). Otherwise scan qs:p (no LSD reverse-map;
            // kept lean). The scan fires only for plays this sitter did NOT
            // originate (cross-sitter SYNC, external favs) — see
            // MENU_REBUILD_PLAN § 6; high pose-count and high SYNC-frequency
            // never coincide, so it is cheap whenever it runs.
            index = -1;
            string curnm;
            if (ANIM_INDEX != -1) curnm = llList2String(qs_pose_data(ANIM_INDEX), 0);
            if (curnm == msg)
                index = ANIM_INDEX;                       // SYNC name already current
            else if (curnm == "P:" + msg)
            {
                index = ANIM_INDEX;                       // POSE already current
                if (num == 90008) num = 90000;
            }
            else
            {
                integer j;
                for (j = 0; j < SLOTS && index == -1; ++j)
                {
                    string nm0 = llList2String(qs_pose_data(j), 0);
                    if (nm0 == msg)
                        index = j;                        // SYNC
                    else if (nm0 == "P:" + msg)
                    {
                        index = j;                        // POSE
                        if (num == 90008) num = 90000;
                    }
                }
            }
            if (id) // OSS::if (osIsUUID(id) && id != NULL_KEY)
            {
                // do nothing
            }
            else if (id != "")
            {
                // assumed numeric - replace it with a "*" so we can test for it
                id = "*";
            }
            if ((id == "" || id == MY_SITTER || (id == "*" && two == SCRIPT_CHANNEL) || num == 90008) && (index != -1 || msg == ""))
            {
                ANIM_INDEX = index;
                integer broadcast = TRUE;
                send_anim_info(broadcast);
                return;
            }
            if (ETYPE == 2)
            {
                if (num != 90010 && llGetSubString(llList2String(qs_pose_data(ANIM_INDEX), 0), 0, 1) != "P:")
                {
                    if (MY_SITTER != "")
                    {
                        llUnSit(MY_SITTER);
                    }
                }
            }
            return;
        }
        if (num == 90045 && sender == llGetLinkNumber() && (ETYPE == 1 || ETYPE == 2))
        {
            string OLD_SYNC = llList2String(llParseStringKeepNulls(msg, ["|"], data), 5);
            if (OLD_SYNC != "" && llList2String(qs_pose_data(ANIM_INDEX), 0) == OLD_SYNC)
            {
                ANIM_INDEX = FIRST_INDEX;
                send_anim_info(TRUE);
            }
            return;
        }
        if (num == 90033)
        {
            llListenRemove(menu_handle);
            return;
        }
        if (num == 90004 || num == 90005)
        {
            data = llParseStringKeepNulls(id, ["|"], data);
            if (llList2Key(data, -1) == MY_SITTER)
            {
                key lastController = CONTROLLER;
                CONTROLLER = llList2Key(data, 0);
                // Restore a named submenu (90005 carrying a submenu name in
                // msg); empty msg = plain re-render. Scan qs:p for the M:
                // marker only when a name is given (no MENU_LIST).
                index = -1;
                if (msg != "")
                {
                    string want = "M:" + msg + "*";
                    integer j;
                    for (j = 0; j < SLOTS && index == -1; ++j)
                        if (llList2String(qs_pose_data(j), 0) == want) index = j;
                }
                if (num == 90004)
                {
                    current_menu = -1;
                    nav_stack = [];
                    menu_page = 0;
                }
                else if (index != -1)
                {
                    nav_stack = [];          // restored directly -> BACK goes to root
                    menu_page = 0;
                    current_menu = index;
                    msg = "";
                }
                animation_menu((integer)msg);
            }
            return;
        }
        if ((num == 90030 || num == 90031) && (one == SCRIPT_CHANNEL || two == SCRIPT_CHANNEL))
        {
            // QS_SWAP_QUIET only (90031): tear down our menu_handle so
            // any pose dialog the user may have left open on this slot
            // can't fire stale clicks against a now-empty CONTROLLER /
            // MY_SITTER. Stock 90030 paths typically dismissed their
            // dialog via the user's own button click (pose-menu [SWAP]
            // / seat-picker pick), so the listen orphans there are
            // harmless and best left untouched to keep stock parity.
            // LSL can't actively close the dialog window — that stays
            // visually on-screen until the user X's it out or it times
            // out — but removing the listen prevents wrong-controller
            // actions if the user clicks it.
            if (num == 90031)
                llListenRemove(menu_handle);
            // View-state reset (MENU_SPEC § 12/§ 13): the occupant just changed,
            // so the previous occupant's submenu / paging / mode must not carry
            // over to whoever opens this slot next. Without this a swap-in user
            // could land in the old user's submenu or a torn-down helper mode.
            // 90030 (loud) reopens at root via sitA; 90031 (quiet) stays silent
            // until the new occupant touches, then renders a clean root menu.
            current_menu = -1;
            nav_stack = [];
            menu_page = 0;
            helper_mode = FALSE;
            in_plugin_menu = FALSE;
            in_adjust_menu = FALSE;
            CONTROLLER = MY_SITTER = "";
            return;
        }
        if (num == 90100 || num == 90101)
        {
            // reuse msg to save a local
            msg = llList2String((data = llParseStringKeepNulls(msg, ["|"], data)), 1);
            // Slot filter (since 0.991): 90100/90101 broadcasts carry the
            // originating slot in data[0] (set by senders in [QS]sitB
            // self-catch-all, [QS]adjuster, [QS]faces back-route, etc.).
            // Without this guard, every sitB instance in a multi-sit prim
            // reacts to every broadcast — user-reported symptom: clicking
            // [ADJUST] on the slot-0 menu spawned a second adjust dialog
            // for slot 1 too. "X" is a wildcard used by [QS]select for
            // cross-slot routing (e.g. [QUICKYHUD] entry); accept it so
            // those paths still fan out to all sitB instances.
            string sSlot = llList2String(data, 0);
            if (sSlot != "X" && (integer)sSlot != SCRIPT_CHANNEL) return;
            if (msg == "[HELPER]")
            {
                // Non-owner gate — MUST match adjuster's [HELPER] click
                // handler ([QS]adjuster.lsl, "Only the owner can rez
                // the helpers..." dialog). Without this guard, sitB
                // flips helper_mode and opens animation_menu(0) even
                // though adjuster refused — user sees BOTH the "Only
                // the owner" dialog AND the helper sub-menu, plus
                // helper_mode toggles globally for everyone seated.
                // Same regression-hotspot warning as adjuster's gate:
                // any future change here MUST preserve this owner check.
                // data[2] is the controller key (the avatar who clicked
                // [HELPER] in the ADJUST submenu); compared to
                // llGetOwner() of the furniture prim.
                if (llList2Key(data, 2) != llGetOwner()) return;
                menu_page = 0;
                helper_mode = !helper_mode;
                if (llList2Key(data, 2) == MY_SITTER && !OLD_HELPER_METHOD)
                {
                    animation_menu(0);
                }
            }
            if (msg == "[ADJUST]")
            {
                helper_mode = FALSE;
                menu_page = 0;
                // Migrated from sitA's inlined options_menu in 0.909.
                // Triggers from three paths: (1) sitB's own listen catch-all
                // (user clicks [ADJUST] in pose menu — broadcasts 90101 here),
                // (2) [AV]root-security back_to_adjust after a security
                // sub-dialog, (3) [QS]faces faces.lsl:336 back-route.
                // data[2] is the controller key — empty in some back-routes
                // (root-security Z72), so we keep the existing CONTROLLER
                // when the payload is blank.
                string ctrl_str = llList2String(data, 2);
                if (ctrl_str != "") CONTROLLER = (key)ctrl_str;
                in_adjust_menu = TRUE;
                adjust_page = 0;
                adjust_dialog();
            }
            if (msg == "[ADJUST OFF]")
            {
                // QuickyHUD ADJUSTMODE-off toggle from main pose menu.
                // Adjuster owns the actual 90266 dispatch + helper_method
                // state — we just reset paging so the next pose-menu
                // re-render starts at page 0 (parity with [ADJUST]).
                menu_page = 0;
            }
            if (msg == "Harder >>")
            {
                ++speed_index;
                if (speed_index > 1)
                    speed_index = 1;
                send_anim_info(FALSE);
            }
            if (msg == "<< Softer")
            {
                --speed_index;
                if (speed_index < -1)
                    speed_index = -1;
                send_anim_info(FALSE);
            }
            return;
        }
        if (num == 90201)
        {
            // Plugin-discovery probe from sitA. Reset everything that's
            // set by the matching reply channels so a removed plugin
            // doesn't leave its capability flag latched TRUE forever.
            has_security = FALSE;
            has_texture = FALSE;
            return;
        }
        if (num == 90202)
        {
            // 90202 signals "[AV]root-security exists in this linkset" by
            // virtue of being sent; has_security is bound to that existence,
            // not the payload value (mirrors sitA's pre-0.910 handler). The
            // msg payload (stock RLV on/off) is no longer consumed: RLV-plugin
            // presence is read on demand from qs:alive:rlv (rlv_present()),
            // since a stock root-security probing the old "[AV]root-RLV" name
            // would broadcast 0 here and wrongly hide Control... on a QS rig.
            has_security = TRUE;
            return;
        }
        if (num == 90203)
        {
            // Stock-AVsitter: "[AV]texture exists in this linkset".
            // Unused upstream but reserved; we gate [TEXTURE] in the
            // ADJUST submenu on it for compatibility with any plugin
            // that ever does send it.
            has_texture = TRUE;
            return;
        }
        if (one == SCRIPT_CHANNEL)
        {
            data = llParseStringKeepNulls(id, ["|"], data);
            if (num == 90299)
            {
                page_map = [];
                nav_stack = [];
                FIRST_INDEX = ANIM_INDEX = -1;
                return;
            }
            if (num == 90070)
            {
                CONTROLLER = MY_SITTER = id;
                menu_page = 0;
                current_menu = -1;
                nav_stack = [];          // fresh occupant -> clean back-path (invariant: root => empty stack)
                menu_channel = ((integer)llFrand(0x7FFFFF80) + 1) * -1; // 7FFFFF80 = max float < 2^31
                llListenRemove(menu_handle);
                return;
            }
            if (num == 90065 && sender == llGetLinkNumber())
            {
                CONTROLLER = MY_SITTER = "";
                llListenRemove(menu_handle);
                return;
            }
            if (num == 90300)
            {
                // Adjuster inserted a new entry in LSD at idx X (payload:
                // name|anim|pos|rot|idx; anim empty = SUBMENU marker, populated
                // = POSE/SYNC). qs:p is already shifted by qs_insert_pose — one
                // shift per inserted entry, and a SUBMENU is TWO (TOMENU + MENU)
                // done before either 90300 arrives. So shift our RAM view +1 per
                // 90300 to match, then re-derive the whole sidecar from the
                // finished qs:p (a per-insert re-key can't track the double
                // shift; the rebuild also wires the new TOMENU->MENU link).
                integer insert_at = (integer)llList2String(data, 4);
                if (current_menu >= insert_at) ++current_menu;
                if (FIRST_INDEX >= insert_at) ++FIRST_INDEX;
                if (ANIM_INDEX >= insert_at) ++ANIM_INDEX;
                integer ns;
                for (ns = 0; ns < llGetListLength(nav_stack); ++ns)
                    if (llList2Integer(nav_stack, ns) >= insert_at)
                        nav_stack = llListReplaceList(nav_stack, [llList2Integer(nav_stack, ns) + 1], ns, ns);
                qs_rebuild_sidecar();   // also sets SLOTS + qs:cfg:slots
                // POSE/SYNC (anim populated) auto-becomes the active pose.
                if (llList2String(data, 1) != "")
                {
                    if (FIRST_INDEX == -1) FIRST_INDEX = insert_at;
                    ANIM_INDEX = insert_at;
                    send_anim_info(TRUE);
                    memory();
                }
                return;
            }
            if (num == 90301)
            {
                // Adjuster overwrote pos/rot in LSD via [HELPER] [SAVE].
                // Forward the new values straight from the 90301 payload to
                // sitA — re-reading LSD via send_anim_info() races with
                // adjuster's qs_save_pose_offset and (worse) uses ANIM_INDEX,
                // which can point to a stale slot or be -1 entirely, leading
                // to empty 90055s and avatar snap-back to the previous saved
                // position. Only fire when the saved pose is the one this
                // sitter is currently playing; otherwise nothing visible to
                // update right now (the new default takes effect on next sit).
                // Is the saved pose the one we're currently playing? Compare by
                // name (no MENU_LIST / index lookup) — data[0] is bare, the
                // stored name may carry a "P:" prefix.
                list pp = qs_pose_data(ANIM_INDEX);
                string curnm = llList2String(pp, 0);
                if ((curnm == llList2String(data, 0) || curnm == "P:" + llList2String(data, 0)) && llGetListLength(data) != 3)
                {
                    llMessageLinked(LINK_THIS, 90055, (string)SCRIPT_CHANNEL,
                        llDumpList2String([
                            curnm,
                            llList2String(pp, 2),    // anim sequence (unchanged)
                            llList2String(data, 1),  // NEW pos from 90301 payload
                            llList2String(data, 2),  // NEW rot from 90301 payload
                            FALSE,
                            speed_index
                        ], "|"));
                }
                return;
            }
            // 90302 handler removed — sitB reads settings from LSD directly
            // in state_entry. Boot no longer dispatches 90302.
            //
            // 90020 handler removed — adjuster's [DUMP] reads LSD directly
            // via qs_dump_channel and emits its own 90022 lines, so sitB
            // is no longer asked to dump.
        }
    }
}
