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
string version = "0.911";
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

// QS_SELECT_HELLO — [QS]select broadcasts this on its own state_entry
// and in response to slot-0 sitA's QSALIVE-reply. We cache the flag
// and use it in select_present(), with the legacy [AV]select probe
// kept as a stock-AVsitter backward-compat fallback.
integer QS_SELECT_HELLO   = 90092;
integer qs_select_present = FALSE;

// QS_BOOT_RELOAD — broadcast by [QS]boot at the end of its seed cascade.
// Triggers a fresh qs_load_from_lsd() so a notecard re-save doesn't
// require a manual reset to pick up the new MENU_LIST. Resets menu
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
// 90101[ADJUST] back-route. Capability flags below are LINK_SET-fed
// (90090/90091/90202/90203) — sitA still keeps its own has_security
// for non-menu purposes (llPassTouches + L1454 dispatch), so both
// scripts maintain parallel copies. ADJUST_MENU comes from qs:cfg
// slot 14 (notecard ADJUST line, label|chan pairs).
list    ADJUST_MENU;
integer has_texture;
integer has_security;
integer adjuster_present;
integer faces_present;
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
list MENU_LIST;
// DATA_LIST and POS_ROT_LIST removed — read on demand from qs:p:<ch>:<i>
// to keep sitB under the 64 KB Mono cap at scale (1000+ poses).
integer helper_mode;
integer has_RLV;
integer ANIM_INDEX;
integer FIRST_INDEX = -1;
integer menu_handle;
integer menu_channel;
integer current_menu = -1;
integer last_menu;
string submenu_info;
integer menu_page;
key MY_SITTER;
key CONTROLLER;
string RLVDesignations;
string onSit;
integer speed_index;
integer verbose = 0;
// SEP = U+FFFD. Initialized at runtime via llUnescapeURL because the
// SL script editor mangles a literal U+FFFD to 0x20 (space) on upload,
// which silently splits anim names containing spaces.
string SEP;

Out(integer level, string out)
{
    if (verbose >= level)
    {
        llOwnerSay(llGetScriptName() + "[" + version + "]:" + out);
    }
}

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
            llList2String(MENU_LIST, ANIM_INDEX),
            anim,
            pos,
            rot,
            broadcast,
            speed_index
        ], "|"));
}

memory()
{
    llOwnerSay(llGetScriptName() + "[" + version + "] " + (string)llGetListLength(MENU_LIST) + " Items Ready, Mem=" + (string)(65536 - llGetUsedMemory()));
}

// QS-side presence is QS_SELECT_HELLO-cached (90092); falls back to
// the [AV]select inventory probe so a stock-AVsitter furniture (no
// QS broadcaster) still gets detected. select_script declaration is
// no longer needed for the [QS] path — the cache flag carries it.
integer select_present()
{
    return qs_select_present
        || llGetInventoryType("[AV]select") == INVENTORY_SCRIPT;
}

integer animation_menu(integer animation_menu_function)
{
    if ((animation_menu_function == -1 || llGetListLength(MENU_LIST) < 2) && (!helper_mode) && select_present())
    {
        llMessageLinked(LINK_SET, 90009, CONTROLLER, MY_SITTER);
    }
    else
    {
        string menu = product + version;
        if (BRAND != "")
            menu = BRAND;
        if (CONTROLLER != MY_SITTER || has_RLV)
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
        string animation_file = llList2String(llParseStringKeepNulls(llList2String(qs_pose_data(ANIM_INDEX), 2), [SEP], []), 0);
        string CURRENT_POSE_NAME;
        if (FIRST_INDEX != -1)
        {
            CURRENT_POSE_NAME = llList2String(MENU_LIST, ANIM_INDEX);
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
        integer total_items;
        integer i = current_menu + 1;
        while (i < llGetListLength(MENU_LIST) && llSubStringIndex(llList2String(MENU_LIST, i), "M:"))
        {
            ++total_items;
            ++i;
        }
        list menu_items0;
        list menu_items2;
        if (current_menu != -1 || select_present())
        {
            menu_items0 += "[BACK]";
        }
        string submenu_info;
        if (current_menu != -1)
        {
            submenu_info = llList2String(qs_pose_data(current_menu), 2);
        }
        // QuickyHUD ADJUSTMODE mirrors helper_mode's main-menu
        // enrichment: while the HUD is in adjust state, the user gets
        // [NEW]/[DUMP]/[SAVE] in the pose menu and [ADJUST] becomes
        // [ADJUST OFF] as the toggle-off button. LSD key is the single
        // source of truth — sitA gates its [QUICKYHUD] entry button
        // off the same probe.
        // [SAVE] is needed in both modes despite ADJUSTMODE auto-saving
        // sitter pose offsets via the 90055 → qs_save_pose_offset path:
        // [PROP] in-world drag has no HUD-driven auto-save and the
        // 90101[SAVE] → PROPSEARCH broadcast in [QS]prop is the only
        // way prop positions get persisted ([QS]prop.lsl:736 explicitly
        // tells the user "Position your prop and click [SAVE]."). The
        // pose-offset re-write under qh_on is idempotent — same value.
        integer qh_on = (llLinksetDataRead("QPP_CFG:ADJUSTMODE") == "On");
        if (helper_mode || qh_on)
        {
            menu_items2 += "[NEW]";
            if (CURRENT_POSE_NAME != "")
            {
                menu_items2 = menu_items2 + "[DUMP]" + "[SAVE]";
            }
        }
        else if (llSubStringIndex(submenu_info, "V") != -1)
        {
            menu_items0 = menu_items0 + "<< Softer" + "Harder >>";
        }
        if (AMENU == 2 || (AMENU == 1 && current_menu == -1) || llSubStringIndex(submenu_info, "A") != -1)
        {
            if (!(OLD_HELPER_METHOD && helper_mode))
            {
                if (qh_on)
                    menu_items2 += "[ADJUST OFF]";
                else
                    menu_items2 += "[ADJUST]";
            }
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
            if (has_RLV && (llGetSubString(RLVDesignations, SCRIPT_CHANNEL, SCRIPT_CHANNEL) == "D" || CONTROLLER != MY_SITTER))
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
        list menu_items1;
        integer page_start = (i = current_menu + 1 + menu_page * items_per_page);
        do
        {
            if (i < llGetListLength(MENU_LIST))
            {
                string m = llList2String(MENU_LIST, i);
                if (!llSubStringIndex(m, "M:"))
                {
                    jump end;
                }
                if (llListFindList(["T:", "P:", "B:"], [llGetSubString(m, 0, 1)]) == -1)
                {
                    menu_items1 += m;
                }
                else
                {
                    menu_items1 += llGetSubString(m, 2, 99999);
                }
            }
        }
        while (++i < page_start + items_per_page);
        @end;
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
        menu_items1 = llList2List(menu_items0, -3, -1);
        menu_items1 += llList2List(menu_items0, -6 ,-4);
        menu_items1 += llList2List(menu_items0, -9 ,-7);
        menu_items1 += llList2List(menu_items0, -12 ,-10);
        llDialog(CONTROLLER, menu, menu_items1, menu_channel);
    }
    return 0;
}

// QuickySitter: read this channel's data straight from Linkset Data instead
// of waiting for [QS]boot to dispatch 90300/90301/90302 messages. Boot is
// the only script that writes LSD during seed; it resets sitB after the
// seed finishes so this state_entry runs with populated LSD. The runtime
// 90300/90301 handlers stay for adjuster live-edits.
qs_load_from_lsd()
{
    MENU_LIST = [];
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

    // Cache only the names + types we need for menu rendering and lookup.
    // anim/pos/rot live in LSD; qs_pose_data(idx) reads them on demand.
    integer i = 0;
    string val;
    while ((val = llLinksetDataRead("qs:p:" + (string)SCRIPT_CHANNEL + ":" + (string)i)) != "")
    {
        list pp = llParseStringKeepNulls(val, ["|"], []);
        MENU_LIST += [llList2String(pp, 0)];
        if (FIRST_INDEX == -1)
        {
            string type = llList2String(pp, 1);
            if (type == "P" || type == "S")
                FIRST_INDEX = ANIM_INDEX = i;
        }
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
    // Bottom-up reorder — same trick as animation_menu (LSL renders
    // dialog buttons bottom-row first, left-to-right within each row).
    list reordered = llList2List(buttons, -3, -1);
    reordered += llList2List(buttons, -6, -4);
    reordered += llList2List(buttons, -9, -7);
    reordered += llList2List(buttons, -12, -10);
    llListenRemove(menu_handle);
    menu_channel = ((integer)llFrand(0x7FFFFF80) + 1) * -1;
    menu_handle = llListen(menu_channel, "", CONTROLLER, "");
    string text = product + " " + version + "\n\nOptions:";
    if (pages > 1) text += " (" + (string)(plugin_page + 1) + "/" + (string)pages + ")";
    llDialog(CONTROLLER, text, reordered, menu_channel);
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
    if (faces_present) builtins += "[FACES]";
    if (has_security)  builtins += "[SECURITY]";

    list dyn;
    integer i;
    integer n = llGetListLength(ADJUST_MENU);
    while (i < n) { dyn += llList2String(ADJUST_MENU, i); i += 2; }

    list tail;
    if (llGetInventoryType(helper_object) == INVENTORY_OBJECT && adjuster_present)
        tail += "[HELPER]";
    // [QUICKYHUD] — owner-only entry, gated on the unprotected
    // QPP_CFG:ADJUSTMODE LSD key (same probe sitA used pre-0.910).
    // HUDPROXY presence cleanup (90093) keeps the key from going stale
    // after the HUD is removed.
    if (CONTROLLER == llGetOwner() && adjuster_present
        && llGetListLength(llLinksetDataFindKeys("^QPP_CFG:ADJUSTMODE$", 0, 1)))
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

    list reordered = llList2List(buttons, -3, -1);
    reordered += llList2List(buttons, -6, -4);
    reordered += llList2List(buttons, -9, -7);
    reordered += llList2List(buttons, -12, -10);

    llListenRemove(menu_handle);
    menu_channel = ((integer)llFrand(0x7FFFFF80) + 1) * -1;
    menu_handle = llListen(menu_channel, "", CONTROLLER, "");
    string text = product + " " + version + "\n\nAdjust:";
    if (pages > 1) text += " (" + (string)(adjust_page + 1) + "/" + (string)pages + ")";
    llDialog(CONTROLLER, text, reordered, menu_channel);
}

default
{
    state_entry()
    {
        SEP = llUnescapeURL("%EF%BF%BD");
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
        // registry. Checked first so a MENU_LIST collision (e.g. a pose
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
        integer index = llListFindList(MENU_LIST, [msg]);
        if (index == -1)
        {
            channel = (string)SCRIPT_CHANNEL;
            index = llListFindList(MENU_LIST, ["P:" + msg]);
        }
        if (index != -1)
        {
            llMessageLinked(LINK_THIS, 90050, (string)channel + "|" + msg + "|" + (string)SET, MY_SITTER);
            llMessageLinked(LINK_THIS, 90000, msg, channel);
            if (MTYPE != 2 && MTYPE != 4)
            {
                llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([id, MY_SITTER], "|"));
            }
            return;
        }
        index = llListFindList(MENU_LIST, ["M:" + msg]);
        if (index != -1)
        {
            if (llListFindList(MENU_LIST, ["T:" + msg]) != -1) // security check - TOMENU must exist
            {
                llMessageLinked(LINK_SET, 90051, (string)channel + "|" + llGetSubString(msg, 0, -2) + "|" + (string)SET, MY_SITTER);
                menu_page = 0;
                last_menu = current_menu;
                current_menu = index;
                animation_menu(0);
            }
            return;
        }
        index = llListFindList(llList2List(MENU_LIST, current_menu + 1, 99999), ["B:" + msg]);
        if (index != -1)
        {
            index += current_menu + 1;
            list button_data = llParseStringKeepNulls(llList2String(qs_pose_data(index), 2), [SEP], []);
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
            else
            {
                if (last_menu != -1)
                {
                    current_menu = last_menu;
                    last_menu = -1;
                }
                else
                {
                    current_menu = llListFindList(MENU_LIST, ["T:" + llGetSubString(llList2String(MENU_LIST, current_menu), 2, 99999)]);
                    if (current_menu != -1)
                    {
                        current_menu -= 1;
                        while (current_menu != -1 && llSubStringIndex(llList2String(MENU_LIST, current_menu), "M:") != 0)
                        {
                            current_menu--;
                        }
                    }
                }
            }
            animation_menu(0);
        }
        else if (msg == "Control..." || msg == "[STOP]")
        {
            llMessageLinked(LINK_SET, 90100, llDumpList2String([SCRIPT_CHANNEL, msg, MY_SITTER], "|"), id);
        }
        else if (index == -1)
        {
            // current_menu (field 3) lets adjuster's [NEW] handler insert new
            // entries at the end of the user's current submenu instead of at
            // the LSD tail. Older adjusters (< 0.904) ignore the extra field.
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
        if (num == QS_SELECT_HELLO)
        {
            // [QS]select announces presence (covers both initial state_entry
            // broadcast and the re-announce triggered by our QSALIVE-reply).
            qs_select_present = TRUE;
            return;
        }
        // Capability flags for the ADJUST submenu (migrated from sitA in
        // 0.909). All three are HELLO-broadcast announce-only — see
        // PROTOCOL.md § 90089/90090/90091. faces_present and
        // adjuster_present gate the [FACES] and [HELPER]/[QUICKYHUD]
        // submenu entries; sitA still keeps its own faces_present /
        // adjuster_present is gone in 0.910 (only has_security stays
        // because L1454 + llPassTouches need it).
        if (num == 90090) { faces_present    = TRUE; return; }
        if (num == 90091) { adjuster_present = TRUE; return; }
        if (num == QS_SITB_PROBE)
        {
            // Boot self-check probe — reply once. One HELLO per probe is
            // enough; boot's handler only sets a flag.
            llMessageLinked(LINK_SET, QS_SITB_HELLO, "", "");
            return;
        }
        if (num == QS_BOOT_RELOAD)
        {
            // Boot finished re-seeding LSD. Re-read MENU_LIST and reset
            // menu navigation — old indices point into the stale list.
            // Also marks iBooted TRUE so the slot-0 pre-boot eject guard
            // disengages (covers both initial wake-up and re-seeds).
            qs_load_from_lsd();
            current_menu = -1;
            last_menu = 0;
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
            index = llListFindList(MENU_LIST, [msg]);
            if (index == -1)
            {
                index = llListFindList(MENU_LIST, ["P:" + msg]);
                // If it's a POSE entry, don't treat it specially
                if (~index && num == 90008)
                    num = 90000;
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
                if (num != 90010 && llGetSubString(llList2String(MENU_LIST, ANIM_INDEX), 0, 1) != "P:")
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
            if (OLD_SYNC != "" && llList2String(MENU_LIST, ANIM_INDEX) == OLD_SYNC)
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
                index = llListFindList(MENU_LIST, ["M:" + msg + "*"]);
                if (num == 90004)
                {
                    current_menu = -1;
                    menu_page = 0;
                }
                else if (index != -1)
                {
                    last_menu = -1;
                    menu_page = 0;
                    current_menu = index;
                    msg = "";
                }
                animation_menu((integer)msg);
            }
            return;
        }
        if (num == 90030 && (one == SCRIPT_CHANNEL || two == SCRIPT_CHANNEL))
        {
            CONTROLLER = MY_SITTER = "";
            return;
        }
        if (num == 90100 || num == 90101)
        {
            // reuse msg to save a local
            msg = llList2String((data = llParseStringKeepNulls(msg, ["|"], data)), 1);
            if (msg == "[HELPER]")
            {
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
            has_RLV = FALSE;
            has_security = FALSE;
            has_texture = FALSE;
            return;
        }
        if (num == 90202)
        {
            // 90202 carries the RLV state in msg (legacy stock-AVsitter
            // convention) AND signals "[AV]root-security exists in this
            // linkset" by virtue of being sent. Both interpretations
            // stack — has_security is bound to the channel's existence,
            // not the payload value (mirrors sitA's pre-0.910 handler).
            has_RLV = (integer)msg;
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
            index = llListFindList(MENU_LIST, [llList2String(data, 0)]);
            if (index == -1)
            {
                index = llListFindList(MENU_LIST, ["P:" + llList2String(data, 0)]);
            }
            if (num == 90299)
            {
                MENU_LIST = [];
                FIRST_INDEX = ANIM_INDEX = -1;
                return;
            }
            if (num == 90070)
            {
                CONTROLLER = MY_SITTER = id;
                menu_page = 0;
                current_menu = -1;
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
                // Adjuster signals "new entry inserted in LSD at idx X".
                // Payload: name | anim | pos | rot | idx — anim is empty
                // for SUBMENU (T:/M: markers), populated for POSE/SYNC.
                // anim/pos/rot are already in LSD via qs_insert_pose; we
                // just mirror the insertion into MENU_LIST and shift any
                // stored indices that pointed past the insertion point.
                integer insert_at = (integer)llList2String(data, 4);
                MENU_LIST = llListInsertList(MENU_LIST, [llList2String(data, 0)], insert_at);
                if (current_menu >= insert_at) ++current_menu;
                if (last_menu >= insert_at) ++last_menu;
                if (FIRST_INDEX >= insert_at) ++FIRST_INDEX;
                if (ANIM_INDEX >= insert_at) ++ANIM_INDEX;
                // POSE/SYNC (anim field populated) auto-becomes the active
                // pose so the avatar animates to it and helper-bar moves
                // adjust the new pose's defaults.
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
                if (index == ANIM_INDEX && llGetListLength(data) != 3)
                {
                    list pp = qs_pose_data(index);
                    llMessageLinked(LINK_THIS, 90055, (string)SCRIPT_CHANNEL,
                        llDumpList2String([
                            llList2String(MENU_LIST, index),
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
