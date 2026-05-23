/*
 * [QS]adjuster - QuickySitter creator tool
 *
 * Fork of [AV]adjuster from AVsitter2 (MPL 2.0). Live-saves pose
 * adjustments to Linkset Data; the [DUMP] button still produces a
 * paste-able AVpos backup, sourced from LSD instead of [QS]sitB.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Original work: Copyright © the AVsitter Contributors (http://avsitter.github.io)
 * AVsitter™ is a trademark. For trademark use policy see:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

integer OLD_HELPER_METHOD;
key key_request;
// Swap-grace: timestamp until which CHANGED_LINK is suppressed (set on
// 90030 receive). See changed-event in default state for rationale.
float swap_grace_until = 0.0;
string version = "0.991";
string helper_name = "[AV]helper";
string camera_script = "[AV]camera";
string notecard_name = "AVpos";

// QSALIVE — sitter-count cache (replaces the legacy
// llGetInventoryType("[QS]sitA " + i) loop). See qs/PROTOCOL.md § QSALIVE.
// Fallback default 7 is a sensible upper bound until slot-0 sitA replies.
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;
integer qs_alive = FALSE;
integer qs_sitter_count_cached = 1;

// QS_ADJUSTER_HELLO — broadcast from this script on state_entry and
// in response to slot-0 sitA's QSALIVE-reply. sitA listens for it to
// gate the [HELPER] menu item (replaces the legacy
// llGetInventoryType("[QS]adjuster") inventory probe).
integer QS_ADJUSTER_HELLO = 90091;

// QS_FACES_HELLO — [QS]faces broadcasts this on its state_entry and
// in response to a QSALIVE-reply. We cache the flag and gate the
// [FACE] menu item below on it (replaces the legacy
// llGetInventoryType("[AV]faces") inventory probe). 90090 lives in
// the 9007x-9009x fork range; see PROTOCOL.md.
integer QS_FACES_HELLO = 90090;
integer faces_present  = FALSE;

// QS_PROP_HELLO — [QS]prop broadcasts this on state_entry / on_rez
// and in response to QSALIVE-reply (mirrors QS_FACES_HELLO). We cache
// the flag and gate the [PROP] menu item below on it (replaces the
// legacy llGetInventoryType("[QS]prop") inventory probe). 90089 sits
// in the 9007x-9008x fork-hello band just below QS_FACES_HELLO.
// Together with the L898 generic diagnostic, adjuster is fully
// name-agnostic for prop (no "[QS]prop" literal left in this file).
integer QS_PROP_HELLO = 90089;
integer prop_present  = FALSE;

// QS_HUDPROXY_HELLO — bidirectional hudproxy presence check (see
// PROTOCOL.md § HUDPROXY presence). Single number, msg-discriminated:
// adjuster sends "PROBE", hudproxy answers "HELLO" (also broadcasts
// "HELLO" unsolicited on its state_entry). If no reply within 1 s
// after state_entry's probe, hudproxy is gone and adjuster cleans up
// the stale QPP_CFG:ADJUSTMODE LSD key — otherwise sitA would keep
// showing the [QUICKYHUD] button after HUD removal, and sitB would
// keep showing the ADJUSTMODE-enriched pose menu indefinitely.
// CHANGED_INVENTORY does llResetScript() so removal automatically
// triggers a fresh probe via state_entry — no separate probe path.
integer QS_HUDPROXY_HELLO = 90093;
integer hudproxy_present;
// Tracks the one-time solo-channel offset applied when we first learn
// count == 1 (legacy state_entry behavior, deferred to QSALIVE-reply
// time because the count isn't known synchronously anymore).
integer solo_offset_applied;
list POS_LIST;
list ROT_LIST;
list HELPER_KEY_LIST;
list SITTER_POSES;
list SITTERS;
integer sitter_count;
integer end_count;
integer verbose = 0;
integer chat_channel = 5;
integer helper_mode;
// 0 = old [AV]helper bars, 1 = QuickyHUD ADJUSTMODE handoff. Tracks
// whether end_helper_mode should also flip QuickyHUD off (auto-Off on
// stand-up / [ADJUST] toggle / inventory change), so we never overwrite
// a state the user enabled themselves via the HUD's own settings dialog.
integer helper_method;
integer comm_channel;
integer listen_handle;
integer active_sitter;
key controller;
integer menu_page;
string adding;
integer adding_item_type;
// current_menu reported by sitB in the [NEW] click — tells qs_insert_idx
// which submenu the user has open so new POSE/SYNC/SUBMENU entries land
// there instead of getting appended to the LSD tail (where they'd hide
// inside whatever submenu happened to be last in the notecard).
integer active_current_menu;
string last_text;
integer menu_pages;
integer number_per_page = 9;
list chosen_animations = [last_text]; //OSS::list chosen_animations; // Force error in LSO

// ========================================================================
// QuickySitter LSD persistence layer (adjuster side)
// ------------------------------------------------------------------------
// Live-save writes to qs:p:<ch>:<i> when the creator [SAVE]s a pose or
// adds a new POSE/SYNC/MENU/TOMENU/BUTTON. [DUMP] itself lives in
// [QS]boot now; this script just kicks it via 90098 (see PROTOCOL.md).
// ========================================================================
string qs_p_key(integer ch, integer i)
{
    return "qs:p:" + (string)ch + ":" + (string)i;
}

integer qs_p_count(integer ch)
{
    integer i = 0;
    while (llLinksetDataRead(qs_p_key(ch, i)) != "")
        ++i;
    return i;
}

integer qs_find_index(integer ch, string name)
{
    integer i = 0;
    string val;
    while ((val = llLinksetDataRead(qs_p_key(ch, i))) != "")
    {
        if (llList2String(llParseStringKeepNulls(val, ["|"], []), 0) == name)
            return i;
        ++i;
    }
    return -1;
}

// Update pos/rot on an existing pose, leaving name/type/anim alone.
qs_save_pose_offset(integer ch, string name, string pos, string rot)
{
    integer idx = qs_find_index(ch, name);
    if (idx == -1) return;
    list cur = llParseStringKeepNulls(llLinksetDataRead(qs_p_key(ch, idx)), ["|"], []);
    llLinksetDataWrite(qs_p_key(ch, idx),
          llList2String(cur, 0) + "|"
        + llList2String(cur, 1) + "|"
        + llList2String(cur, 2) + "|"
        + pos + "|" + rot);
}

// Insert pose entry at `pos`, shifting all keys >= pos up by 1.
// `type` is the single-char form: P/S/M/T/B.
qs_insert_pose(integer ch, integer pos, string name, string type, string anim, string p, string r)
{
    integer total = qs_p_count(ch);
    integer i;
    for (i = total; i > pos; --i)
        llLinksetDataWrite(qs_p_key(ch, i), llLinksetDataRead(qs_p_key(ch, i - 1)));
    llLinksetDataWrite(qs_p_key(ch, pos), name + "|" + type + "|" + anim + "|" + p + "|" + r);
}

// [DUMP] (producer + receiver, including plugin cascade and HTTP upload)
// lives entirely in [QS]boot now. Adjuster's involvement is: the [DUMP]
// dialog handler sends 90098 to start, and that's it.

stop_all_anims(key id)
{
    list animations = llGetAnimationList(id);
    integer i;
    for (i = 0; i < llGetListLength(animations); i++)
    {
        llMessageLinked(LINK_THIS, 90002, llList2String(animations, i), id);
    }
}

list order_buttons(list buttons)
{
    return llList2List(buttons, -3, -1) + llList2List(buttons, -6, -4) + llList2List(buttons, -9, -7) + llList2List(buttons, -12, -10);
}

string strReplace(string str, string search, string replace)
{
    return llDumpList2String(llParseStringKeepNulls(str, [search], []), replace);
}

preview_anim(string anim, key id)
{
    if (id) // OSS::if (osIsUUID(id) && id != NULL_KEY)
    {
        stop_all_anims(id);
        llMessageLinked(LINK_THIS, 90001, anim, id);
    }
}

list get_choices()
{
    integer my_number_per_page = number_per_page;
    if (adding == "[SYNC]" && sitter_count > 1)
    {
        my_number_per_page--;
    }
    list options;
    integer i;
    integer start = my_number_per_page * menu_page;
    integer end = start + my_number_per_page;
    if (adding == "[FACE]")
    {
        list facial_anim_list =
            [ "none"
            , "express_afraid_emote"
            , "express_anger_emote"
            , "express_laugh_emote"
            , "express_bored_emote"
            , "express_cry_emote"
            , "express_embarrassed_emote"
            , "express_sad_emote"
            , "express_toothsmile"
            , "express_smile"
            , "express_surprise_emote"
            , "express_worry_emote"
            , "express_repulsed_emote"
            , "express_shrug_emote"
            , "express_wink_emote"
            , "express_disdain"
            , "express_frown"
            , "express_kiss"
            , "express_open_mouth"
            , "express_tongue_out"
            ];
        i = llGetListLength(facial_anim_list);
        options = llList2List(facial_anim_list, start, end - 1);
    }
    else
    {
        integer type = INVENTORY_ANIMATION;
        if (adding == "[PROP]")
        {
            type = INVENTORY_OBJECT;
        }
        i = start;
        while (i < end && i < llGetInventoryNumber(type))
        {
            if (llGetInventoryName(type, i) != helper_name)
            {
                options += llGetInventoryName(type, i);
            }
            i++;
        }
        i = llGetInventoryNumber(type);
    }
    menu_pages = llCeil((float)i / my_number_per_page);
    return options;
}

ask_anim()
{
    choice_menu(get_choices(), "Choose anim" + sitter_text(sitter_count) + ":");
}

choice_menu(list options, string menu_text)
{
    last_text = menu_text;
    menu_text = "\n(Page " + (string)(menu_page + 1) + "/" + (string)menu_pages + ")\n" + menu_text + "\n\n";
    list menu_items;
    integer i;
    if (llGetListLength(options) == 0)
    {
        menu_text = "\nNo items of required type in prim inventory.";
        menu_items = ["[BACK]"];
    }
    else
    {
        integer cutoff = 65;
        integer all_options_length = llStringLength(llDumpList2String(options, ""));
        integer total_need_to_cut = 412 - all_options_length;
        if (total_need_to_cut < 0)
        {
            cutoff = 43;
        }
        for (i = 0; i < llGetListLength(options); i++)
        {
            menu_items += (string)(i + 1);
            string item = llList2String(options, i);
            if (llStringLength(item) > cutoff)
            {
                item = llGetSubString(item, 0, cutoff) + "..";
            }
            menu_text += (string)(i + 1) + "." + item + "\n";
        }
        if (adding == "[SYNC]" && sitter_count > 1)
        {
            menu_items += "[DONE]";
        }
        menu_items += ["[BACK]", "[<<]", "[>>]"];
    }
    llDialog(controller
            , menu_text
            , llList2List(menu_items, -3, -1)
            + llList2List(menu_items, -6, -4)
            + llList2List(menu_items, -9, -7)
            + llList2List(menu_items, -12, -10)
            , comm_channel
            );
}

new_menu()
{
    menu_page = 0;
    list menu_items = ["[BACK]", "[POSE]", "[SYNC]", "[SUBMENU]"];
    if (llList2String(SITTER_POSES, active_sitter) != "")
    {
        menu_items += ["[PROP]", "[FACE]"];
    }
    menu_items += "[CAMERA]";
    string menu_text = "\nWhat would you like to create?\n";
    llDialog(controller
            , menu_text
            , llList2List(menu_items, -3, -1)
            + llList2List(menu_items, -6, -4)
            + llList2List(menu_items, -9, -7)
            + llList2List(menu_items, -12, -10)
            , comm_channel
            );
}

// Helper-mode cleanup without flipping ADJUSTMODE. Used by the explicit
// [ADJUST] toggle in the main menu: the user wants to drop out of the
// AVsitter helper overlay but keep QuickyHUD's ADJUSTMODE in whatever
// state it's currently in — that's controlled separately via
// [QUICKYHUD] → [ADJUST OFF] (or the HUD settings dialog). The
// stand-up paths still go through end_helper_mode() so the
// helper_method == 1 auto-Off safety net stays intact when the user
// forgets to disable ADJUSTMODE before standing up.
cleanup_helper_mode()
{
    llRegionSay(comm_channel, "DONEA");
    helper_mode = FALSE;
}

end_helper_mode()
{
    if (helper_method == 1)
    {
        llMessageLinked(LINK_SET, 90266, "Off", llGetOwner());
        helper_method = 0;
    }
    cleanup_helper_mode();
}

// QuickyHUD's hudproxy (when present in the linkset) writes
// QPP_CFG:ADJUSTMODE unprotected. The key's existence is the capability
// signal — sitA gates the [QUICKYHUD] button on the same probe. We don't
// rely on script-name matches because stock AVsitter painted itself into
// a corner with that pattern. Stale-key cleanup uses QS_HUDPROXY_HELLO
// probe/reply (see state_entry + timer) so a removed hudproxy doesn't
// leave a phantom [QUICKYHUD] button.

// QuickyHUD ADJUSTMODE has no dedicated submenu — clicking [QUICKYHUD]
// in the Adjust dialog flips QPP_CFG:ADJUSTMODE to "On" and re-shows
// the main pose menu, which sitB then enriches with [NEW]/[DUMP]/
// [SAVE] and swaps [ADJUST] for [ADJUST OFF] (same enrichment pattern
// as helper_mode). [ADJUST OFF] in the pose menu round-trips back
// through 90100 to flip ADJUSTMODE off and re-show the pose menu.

Out(string out)
{
    llOwnerSay(llGetScriptName() + "[" + version + "] " + out);
}

integer get_number_of_scripts()
{
    if (qs_alive) return qs_sitter_count_cached;
    return 7;  // pre-QSALIVE-reply fallback — sensible upper bound.
}

// Reset all sitter-tracking lists to the current count. Called from
// state_entry (with fallback count) and again from the QSALIVE_REPLY
// handler when the real count differs.
init_lists()
{
    SITTERS = [];
    POS_LIST = [];
    ROT_LIST = [];
    HELPER_KEY_LIST = [];
    SITTER_POSES = [];
    integer count = get_number_of_scripts();
    integer i;
    for (i = 0; i < count; ++i)
    {
        SITTERS += 0;
        POS_LIST += 0;
        ROT_LIST += 0;
        HELPER_KEY_LIST += 0;
        SITTER_POSES += "";
    }
}

string convert_to_world_positions(integer num)
{
    rotation target_rot = llEuler2Rot(llList2Vector(ROT_LIST, num) * DEG_TO_RAD) * llGetRot();
    vector target_pos = llList2Vector(POS_LIST, num) * llGetRot() + llGetPos();
    return (string)target_pos + "|" + (string)target_rot;
}

string sitter_text(integer sitter)
{
    return " for SITTER " + (string)sitter;
}

remove_script(string reason)
{
    string message = "\n" + llGetScriptName() + " ==Script Removed==\n\n" + reason;
    llDialog(llGetOwner(), message, ["OK"], -3675);
    llInstantMessage(llGetOwner(), message);
    llRemoveInventory(llGetScriptName());
}

done_choosing_anims()
{
    string adding_text = llList2String(llParseString2List(adding, ["[", "]"], []), 0);
    adding += "2";
    integer i;
    string text;
    for (i = 0; i < llGetListLength(chosen_animations); i++)
    {
        text += "\nSITTER " + (string)i + ": " + llList2String(chosen_animations, i);
    }
    llTextBox(controller, "\nType a menu name for " + adding_text + text, comm_channel);
}

camera_menu()
{
    string text = "\nCamera:\n\n";
    if (llGetInventoryType(camera_script) == INVENTORY_SCRIPT)
    {
        text += "(using [AV]camera scripts)";
    }
    else
    {
        text += "(prim property)";
    }
    llDialog(controller, text, ["[BACK]", "[SAVE]", "[CLEAR]"], comm_channel);
}

unsit_all()
{
    integer i = llGetNumberOfPrims();
    while (llGetAgentSize(llGetLinkKey(i)) != ZERO_VECTOR)
    {
        stop_all_anims(llGetLinkKey(i));
        llUnSit(llGetLinkKey(i));
        i--;
    }
}

toggle_helper_mode()
{
    helper_mode = !helper_mode;
    if (helper_mode)
    {
        if (OLD_HELPER_METHOD)
        {
            unsit_all();
        }
        // Idempotent: helper_choice_menu() may have already armed the
        // listen for the choice dialog. Stacking llListen calls would
        // leak handles otherwise.
        llListenRemove(listen_handle);
        listen_handle = llListen(comm_channel, "", "", "");
        integer i;
        for (i = 0; i < llGetListLength(SITTERS); i++)
        {
            integer param = comm_channel + i * -1;
            if (llGetListLength(SITTERS) == 1)
            {
                param = comm_channel + llGetLinkNumber() * -1;
            }
            vector offset = llList2Vector(POS_LIST, i);
            if (llVecMag(offset) > 10)
            {
                offset = ZERO_VECTOR;
            }
            llRezAtRoot(helper_name, llGetPos() + offset * llGetRot(), ZERO_VECTOR, llEuler2Rot(llList2Vector(ROT_LIST, i) * DEG_TO_RAD) * llGetRot(), param);
        }
    }
    else
    {
        end_helper_mode();
    }
}

default
{
    state_entry()
    {
        if (llSubStringIndex(llGetScriptName(), " ") != -1)
        {
            remove_script("Use only one of this script!");
        }
        llListen(chat_channel, "", llGetOwner(), "");
        comm_channel = ((integer)llFrand(99999) + 1) * 1000 * -1;
        // QSALIVE probe — slot-0 sitA replies with the real sitter count.
        // Until then, init_lists pre-sizes to the fallback (7). The solo
        // -1e9 offset on comm_channel is applied later, from the QSALIVE
        // handler, once we actually know count == 1.
        qs_alive = FALSE;
        solo_offset_applied = FALSE;
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
        // Announce ourselves so sitA can gate the [HELPER] menu item
        // without script-name inventory probes. sitA caches the flag;
        // we re-announce in the QSALIVE_REPLY handler so a late sitA
        // boot also catches us.
        llMessageLinked(LINK_SET, QS_ADJUSTER_HELLO, "", llGetScriptName());
        // Probe hudproxy. HELLO-reply handler in link_message sets the
        // flag + cancels the timer; if 1 s passes silent, timer()
        // deletes the stale QPP_CFG:ADJUSTMODE key. See header comment
        // at QS_HUDPROXY_HELLO.
        hudproxy_present = FALSE;
        llMessageLinked(LINK_SET, QS_HUDPROXY_HELLO, "PROBE", "");
        llSetTimerEvent(1.0);
        init_lists();
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        integer one = (integer)msg;
        integer two = (integer)((string)id);
        integer i;
        if (num == QS_HUDPROXY_HELLO && msg == "HELLO")
        {
            // hudproxy is alive — cache + kill the timeout. (Our own
            // "PROBE" comes back through the same number; ignore it
            // via the msg check.)
            hudproxy_present = TRUE;
            llSetTimerEvent(0.0);
            return;
        }
        if (num == QS_FACES_HELLO) // 90090=faces announces presence
        {
            faces_present = TRUE;
            return;
        }
        if (num == QS_PROP_HELLO) // 90089=prop announces presence
        {
            prop_present = TRUE;
            return;
        }
        if (num == QSALIVE_REPLY)
        {
            // Slot-0 sitA reports the real sitter count. Resize the
            // tracking lists if needed and apply the solo-channel offset
            // once on first reply with count == 1.
            list d = llParseString2List(msg, ["|"], []);
            if (llList2String(d, 0) == "QuickySitter")
            {
                integer new_count = (integer)llList2String(d, 2);
                qs_alive = TRUE;
                if (new_count != qs_sitter_count_cached)
                {
                    qs_sitter_count_cached = new_count;
                    init_lists();
                }
                if (!solo_offset_applied && new_count == 1)
                {
                    comm_channel -= 1000000000;
                    solo_offset_applied = TRUE;
                }
                // Re-announce so sitA-slot-0 (which just reset and
                // broadcast 90097) catches our presence flag.
                llMessageLinked(LINK_SET, QS_ADJUSTER_HELLO, "", llGetScriptName());
            }
            return;
        }
        if (sender == llGetLinkNumber())
        {
            list data = llParseStringKeepNulls(msg, ["|"], []);
            if (num == 90065)
            {
                i = llListFindList(SITTERS, [id]);
                if (i != -1)
                {
                    SITTERS = llListReplaceList(SITTERS, [NULL_KEY], i, i);
                }
                return;
            }
            if (num == 90030)
            {
                // Arm the CHANGED_LINK swap-grace window — transient link
                // changes during the sittarget swap must not be treated as
                // "last sitter left" (which would auto-end ADJUSTMODE).
                swap_grace_until = llGetTime() + 2.0;
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)msg, (integer)msg);
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)((string)id), (integer)((string)id));
                if (OLD_HELPER_METHOD && helper_mode)
                {
                    i = llList2Integer(HELPER_KEY_LIST, (integer)msg);
                    HELPER_KEY_LIST = llListReplaceList(HELPER_KEY_LIST, [llList2Integer(HELPER_KEY_LIST, (integer)((string)id))], (integer)msg, (integer)msg);
                    HELPER_KEY_LIST = llListReplaceList(HELPER_KEY_LIST, [i], (integer)((string)id), (integer)((string)id));
                    llRegionSay(comm_channel, "SWAP|" + (string)msg + "|" + (string)id);
                }
                return;
            }
            if (num == 90070)
            {
                SITTERS = llListReplaceList(SITTERS, [id], (integer)msg, (integer)msg);
                return;
            }
            // 90021 / 90022 handlers moved to [QS]boot along with the
            // dump output pipeline (Readout_Say + web upload). Boot owns
            // both producer (qs_dump_start/qs_dump_tick) and receiver
            // (90022 formatter, 90021 plugin cascade) now. See PROTOCOL.md.
            if (num == 90100 || num == 90101)
            {
                if ((msg = llList2String(data, 1)) == "[DUMP]")
                {
                    if (id != llGetOwner())
                    {
                        llRegionSayTo(id, 0, "Dumping settings to Owner");
                    }
                    // Hand off to [QS]boot. Boot streams V: + per-pose
                    // 90022s, formats and Readout_Says them itself, then
                    // runs the plugin/next-channel cascade and finalizes
                    // the upload.
                    //
                    // Mode marker in the id field: "quiet" → boot's
                    // Readout_Say suppresses the per-line chat output,
                    // emitting only the COPY ABOVE/BELOW banners and the
                    // final URL shout to the owner. Anything else (""
                    // here) keeps stock-style loud chat output.
                    //
                    // Routing rule: [DUMP] reached us via the same pose
                    // menu, but the user entered that menu either via
                    // [HELPER] (helper_mode=TRUE) or via [QUICKYHUD]
                    // (helper_mode=FALSE, ADJUSTMODE flipped to "On").
                    // Helper path keeps stock behavior; QUICKYHUD path
                    // goes quiet because the HUD user already has a
                    // chat-free workflow and the URL is the deliverable.
                    string dump_mode = "";
                    if (!helper_mode
                        && llLinksetDataRead("QPP_CFG:ADJUSTMODE") == "On")
                    {
                        dump_mode = "quiet";
                    }
                    llMessageLinked(LINK_THIS, 90098, "0", dump_mode);
                }
                if (msg == "[NEW]")
                {
                    controller = llList2Key(data, 2);
                    active_sitter = llList2Integer(data, 0);
                    // sitB ≥ 0.902 includes current_menu as field 3. Older
                    // sitBs omit it → fall back to -1 (top-level append).
                    if (llGetListLength(data) >= 4)
                        active_current_menu = (integer)llList2String(data, 3);
                    else
                        active_current_menu = -1;
                    adding = "";
                    new_menu();
                }
                if (msg == "[SAVE]")
                {
                    for (i = 0; i < llGetListLength(SITTERS); i++)
                    {
                        if (llList2String(SITTER_POSES, i) != "")
                        {
                            string type = "SYNC";
                            string temp_pose_name = llList2String(SITTER_POSES, i);
                            if (llSubStringIndex(llList2String(SITTER_POSES, i), "P:") == 0)
                            {
                                type = "POSE";
                                temp_pose_name = llGetSubString(temp_pose_name, 2, 99999);
                            }
                            // Saving a new default invalidates any pose-specific
                            // personal offset that was relative to the OLD default.
                            // Drop those entries before sitB re-applies via 90055,
                            // so the avatar lands at the helper-bar position rather
                            // than (new_default + stale_offset). Send 90263 first
                            // so sitA processes it ahead of the 90055 chain.
                            // M#T! (all-poses offset) is intentionally kept.
                            llMessageLinked(LINK_THIS, 90263, (string)i, (key)llList2String(SITTER_POSES, i));
                            llMessageLinked(LINK_THIS, 90301, (string)i, llList2String(SITTER_POSES, i) + "|" + llList2String(POS_LIST, i) + "|" + llList2String(ROT_LIST, i) + "|");
                            // Persist the new offset to LSD immediately — no
                            // [DUMP] required. SITTER_POSES holds names with
                            // sitB's prefix already attached, matching the
                            // `name` field stored in qs:p:<ch>:<i>.
                            qs_save_pose_offset(i,
                                llList2String(SITTER_POSES, i),
                                llList2String(POS_LIST, i),
                                llList2String(ROT_LIST, i));
                            vector pos = llList2Vector(POS_LIST, i);
                            vector rot = llList2Vector(ROT_LIST, i);
                            llSay(0, type + " Saved " + sitter_text(i) + ": {" + temp_pose_name + "}" + llList2String(POS_LIST, i) + llList2String(ROT_LIST, i));
                        }
                    }
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([llList2String(data, 2), id], "|"));
                }
                if (msg == "[BACK]")
                {
                    // sitB asked us to tear down the active mode
                    // (helper_mode or ADJUSTMODE) — it's already
                    // opening its adjust submenu, we only do the
                    // cleanup here. Both modes can theoretically be
                    // independently active; handle whichever is on.
                    // Silent (no menu re-render from here; sitB owns
                    // the navigation).
                    controller = id;
                    if (helper_mode)
                    {
                        helper_mode = FALSE;
                        end_helper_mode();
                    }
                    if (llLinksetDataRead("QPP_CFG:ADJUSTMODE") == "On")
                    {
                        llMessageLinked(LINK_SET, 90266, "Off", llGetOwner());
                        helper_method = 0;
                    }
                }
                if (msg == "[HELPER]")
                {
                    controller = id;
                    OLD_HELPER_METHOD = (integer)llList2String(data, 3);
                    toggle_helper_mode();
                }
                if (msg == "[QUICKYHUD]")
                {
                    controller = id;
                    // Arm the comm_channel listen so the [NEW] sub-flow's
                    // sub-dialogs (new_menu → [POSE]/[SYNC]/[PROP]/[FACE]/
                    // [CAMERA]/[SUBMENU], plus the prop/face choice_menu
                    // and TextBox naming) land back in our listen handler.
                    // toggle_helper_mode() does this for the [HELPER] flow;
                    // [QUICKYHUD] needs the same arming since both paths
                    // share the new_menu() sub-dialogs (sitB renders [NEW]
                    // in the qh_on-enriched pose menu, identical to the
                    // helper_mode branch).
                    llListenRemove(listen_handle);
                    listen_handle = llListen(comm_channel, "", "", "");
                    llMessageLinked(LINK_SET, 90266, "On", llGetOwner());
                    helper_method = 1;
                    // Re-show the main pose menu so sitB's qh_on branch
                    // emits the ADJUSTMODE-enriched buttons ([NEW]/
                    // [DUMP]/[SAVE]/[ADJUST OFF]) — same UX as [HELPER].
                    // [SAVE] is needed for [PROP] in-world position
                    // persistence (90101[SAVE] → PROPSEARCH); pose
                    // offsets re-write idempotently under ADJUSTMODE.
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([llList2String(data, 2), id], "|"));
                }
                if (msg == "[ADJUST OFF]")
                {
                    // sitB's pose-menu [ADJUST OFF] (qh_on branch). Flip
                    // ADJUSTMODE off, clear helper_method so end_helper_mode
                    // doesn't double-fire 90266, re-show pose menu.
                    llMessageLinked(LINK_SET, 90266, "Off", llGetOwner());
                    helper_method = 0;
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([llList2String(data, 2), id], "|"));
                }
                if (msg == "[ADJUST]")
                {
                    // Explicit main-menu toggle: drop helper overlay but
                    // leave ADJUSTMODE alone. Use the pose menu's
                    // [ADJUST OFF] to flip ADJUSTMODE off.
                    cleanup_helper_mode();
                }
                return;
            }
            if (num == 90055 || num == 90056)
            {
                data = llParseStringKeepNulls(id, ["|"], []);
                SITTER_POSES = llListReplaceList(SITTER_POSES, [llList2String(data, 0)], one, one);
                POS_LIST = llListReplaceList(POS_LIST, [(vector)llList2String(data, 2)], one, one);
                ROT_LIST = llListReplaceList(ROT_LIST, [(vector)llList2String(data, 3)], one, one);
                // Stock-equivalent ADJUSTMODE persistence: while QuickyHUD's
                // ADJUSTMODE is On, every X+/Y+/Z+ click round-trips through
                // hudproxy → 90301 → sitB → here as 90055, and we write the
                // new pos/rot straight into qs:p:<ch>:<i> as the new pose
                // default — no separate [SAVE] step. Idempotent on regular
                // pose changes / sit (same value rewritten). Gated on the
                // unprotected LSD key (single source of truth) rather than
                // helper_method, so a HUD-side toggle of ADJUSTMODE via the
                // settings dialog stays consistent with the persistence
                // behavior; helper_method is only the auto-Off-on-stand-up
                // gate in end_helper_mode.
                if (llLinksetDataRead("QPP_CFG:ADJUSTMODE") == "On")
                {
                    qs_save_pose_offset(one,
                        llList2String(data, 0),
                        llList2String(data, 2),
                        llList2String(data, 3));
                }
                if (helper_mode)
                {
                    llRegionSay(comm_channel, "POS|" + (string)one + "|" + convert_to_world_positions(one) + "|" + (string)OLD_HELPER_METHOD + "|" + llList2String(SITTERS, one));
                }
            }
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_LINK)
        {
            // Swap-grace: during a 90030 swap, the avatar can briefly
            // appear to leave the linkset (transient unsit between
            // sittarget updates on some furnitures). Without this guard,
            // adjuster's "last sitter left" heuristic (last-link agent
            // size == ZERO_VECTOR) fires end_helper_mode → 90266 Off →
            // hudproxy.setAdjustmode("Off") → 953-broadcast flips both
            // HUDs out of ADJUSTMODE mid-swap. Skip CHANGED_LINK in the
            // grace window — a real stand-up still fires CHANGED_LINK
            // after the grace expires.
            if (llGetTime() < swap_grace_until) return;
            if (OLD_HELPER_METHOD)
            {
                if (llGetAgentSize(llGetLinkKey(llGetNumberOfPrims())) != ZERO_VECTOR)
                {
                    end_helper_mode();
                }
            }
            else if (llGetListLength(SITTERS) == 1 && llAvatarOnSitTarget() == NULL_KEY || llGetAgentSize(llGetLinkKey(llGetNumberOfPrims())) == ZERO_VECTOR)
            {
                end_helper_mode();
            }
        }
        if (change & CHANGED_INVENTORY)
        {
            unsit_all();
            end_helper_mode();
            llResetScript();
        }
    }

    timer()
    {
        // QS_HUDPROXY_HELLO probe timed out — hudproxy isn't in the
        // linkset anymore. Wipe the stale QPP_CFG:ADJUSTMODE key so
        // sitA stops showing the [QUICKYHUD] button and sitB's qh_on
        // gate stops thinking ADJUSTMODE is on. Sole purpose of this
        // handler — no other timer state lives in adjuster.
        llSetTimerEvent(0.0);
        if (!hudproxy_present)
        {
            llLinksetDataDelete("QPP_CFG:ADJUSTMODE");
        }
    }

    run_time_permissions(integer perm)
    {
        if (llGetPermissions() & PERMISSION_TRACK_CAMERA)
        {
            llPlaySound("3d09f582-3851-c0e0-f5ba-277ac5c73fb4", 1.);
            vector eye = (llGetCameraPos() - llGetPos()) / llGetRot();
            vector at = eye + llRot2Fwd(llGetCameraRot() / llGetRot());
            if (llGetInventoryType(camera_script) == INVENTORY_SCRIPT)
            {
                llMessageLinked(LINK_THIS, 90174, (string)active_sitter, (string)eye + "|" + (string)at);
            }
            else
            {
                llMessageLinked(LINK_THIS, 90011, (string)eye, (string)at);
                llSay(0, "Camera property saved for all sitters in prim (takes effect next sit).");
            }
            camera_menu();
        }
    }

    listen(integer chan, string name, key id, string msg)
    {
        if (chan == chat_channel)
        {
            if (msg == "cleanup")
            {
                llRegionSay(comm_channel, "DONEA");
                Out("Cleaning \"" + llGetScriptName() + "\" and \"" + helper_name + "\" from prim " + (string)llGetLinkNumber());
                if (llGetInventoryType(helper_name) == INVENTORY_OBJECT)
                {
                    llRemoveInventory(helper_name);
                }
                llRemoveInventory(llGetScriptName());
            }
            else if (msg == "targets")
            {
                llMessageLinked(LINK_THIS, 90298, "", "");
            }
            else if (msg == "helper")
            {
                if (llGetAgentSize(llGetLinkKey(llGetNumberOfPrims())) != ZERO_VECTOR)
                {
                    llMessageLinked(LINK_SET, 90100, "0|[HELPER]||" + (string)OLD_HELPER_METHOD, llList2Key(SITTERS, 0));
                }
            }
        }
        else if (id == controller)
        {
            if (msg == "[>>]")
            {
                menu_page++;
                if (menu_page >= menu_pages)
                {
                    menu_page = 0;
                }
                choice_menu(get_choices(), last_text);
            }
            else if (msg == "[<<]")
            {
                menu_page--;
                if (menu_page < 0)
                {
                    menu_page = menu_pages - 1;
                }
                choice_menu(get_choices(), last_text);
            }
            else if (msg == "[BACK]")
            {
                llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([controller, llList2String(SITTERS, active_sitter)], "|"));
            }
            else if (msg == "[POSE]" || msg == "[SYNC]")
            {
                adding = msg;
                chosen_animations = [];
                sitter_count = active_sitter;
                end_count = sitter_count;
                if (msg == "[SYNC]")
                {
                    sitter_count = 0;
                    end_count = llGetListLength(SITTERS) - 1;
                }
                ask_anim();
            }
            else if (msg == "[SUBMENU]")
            {
                adding = msg;
                llTextBox(controller, "\n\nName your submenu:", comm_channel);
            }
            else if (msg == "[PROP]")
            {
                if (prop_present)
                {
                    adding = msg;
                    choice_menu(get_choices(), "Choose your prop:");
                }
                else
                {
                    llSay(0, "For this you need the prop plugin script.");
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([controller, llList2String(SITTERS, active_sitter)], "|"));
                }
            }
            else if (msg == "[FACE]")
            {
                if (faces_present)
                {
                    adding = msg;
                    choice_menu(get_choices(), "Choose your facial anim:");
                }
                else
                {
                    llSay(0, "For this you need the faces plugin script.");
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([controller, llList2String(SITTERS, active_sitter)], "|"));
                }
            }
            else if (msg == "[CAMERA]")
            {
                camera_menu();
            }
            else if (msg == "[CLEAR]")
            {
                integer i;
                for (i = 0; i < llGetNumberOfPrims(); i++)
                {
                    llSetLinkCamera(i, ZERO_VECTOR, ZERO_VECTOR);
                }
                if (llGetInventoryType(camera_script) == INVENTORY_SCRIPT)
                {
                    llMessageLinked(LINK_THIS, 90174, (string)active_sitter, "none");
                }
                else
                {
                    llSay(0, "Camera property cleared from all prims (takes effect next sit).");
                }
                camera_menu();
            }
            else if (msg == "[SAVE]")
            {
                llRequestPermissions(id, PERMISSION_TRACK_CAMERA);
            }
            else if (llListFindList(["[DONE]", "1", "2", "3", "4", "5", "6", "7", "8", "9"], [msg]) != -1 && llListFindList(["[POSE]", "[SYNC]", "[SYNC]2", "[PROP]", "[FACE]"], [adding]) != -1)
            {
                string choice = llList2String(get_choices(), (integer)msg - 1);
                if (adding == "[PROP]")
                {
                    integer perms = llGetInventoryPermMask(choice, MASK_NEXT);
                    if ((perms & PERM_COPY) == 0)
                    {
                        llSay(0, "Could not add prop '" + choice + "'. Props and their content must be COPY-OK for NEXT owner.");
                    }
                    else
                    {
                        llMessageLinked(LINK_THIS, 90171, (string)active_sitter, choice);
                    }
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([controller, llList2String(SITTERS, active_sitter)], "|"));
                }
                else if (adding == "[FACE]")
                {
                    llMessageLinked(LINK_THIS, 90172, (string)active_sitter, choice);
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([controller, llList2String(SITTERS, active_sitter)], "|"));
                }
                else if (msg == "[DONE]")
                {
                    done_choosing_anims();
                }
                else if (adding == "[SYNC]" || adding == "[POSE]")
                {
                    chosen_animations += choice;
                    preview_anim(choice, llList2Key(SITTERS, sitter_count));
                    sitter_count++;
                    if (sitter_count > end_count)
                    {
                        done_choosing_anims();
                    }
                    else
                    {
                        ask_anim();
                    }
                }
            }
            else
            {
                msg = strReplace(msg, "\n", "");
                msg = strReplace(msg, "|", "");
                msg = llGetSubString(msg, 0, 22);
                if (msg == "")
                {
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([controller, llList2String(SITTERS, active_sitter)], "|"));
                }
                else if (adding == "[SUBMENU]")
                {
                    // Insertion idx = end of user's current submenu (next M:*
                    // marker or end of list). T:* button + adjacent M:* group.
                    // Read-before-check: LSL has no sequence point inside an
                    // expression, so `(ival = read()) != "" && first2(ival) ...`
                    // uses ival's PREVIOUS value in the second operand → loop
                    // overshoots M:* by 1.
                    integer ins = active_current_menu + 1;
                    string ival = llLinksetDataRead(qs_p_key(active_sitter, ins));
                    while (ival != "" && llGetSubString(ival, 0, 1) != "M:")
                    {
                        ++ins;
                        ival = llLinksetDataRead(qs_p_key(active_sitter, ins));
                    }
                    qs_insert_pose(active_sitter, ins, "T:" + msg + "*", "T", "", "", "");
                    qs_insert_pose(active_sitter, ins + 1, "M:" + msg + "*", "M", "", "", "");
                    // Payload format: name|anim|pos|rot|idx — 4 pipes
                    // (5 fields). SUBMENU has empty anim/pos/rot; a stray
                    // 3-pipe `"|||"` shipped in 0.907 left idx at field 3
                    // (rot) and sitB's data[4] read returned "" → 0, so
                    // every SUBMENU insert mirrored into MENU_LIST[0] and
                    // desynced from LSD. Fixed in 0.909.
                    llMessageLinked(LINK_THIS, 90300, (string)active_sitter, "T:" + msg + "*" + "||||" + (string)ins);
                    llMessageLinked(LINK_THIS, 90300, (string)active_sitter, "M:" + msg + "*" + "||||" + (string)(ins + 1));
                    llSay(0, "MENU Added: '" + msg + "'" + sitter_text(active_sitter));
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([controller, llList2String(SITTERS, active_sitter)], "|"));
                }
                else if (adding == "[POSE]2" || adding == "[SYNC]2")
                {
                    integer start = 0;
                    integer end = llGetListLength(chosen_animations);
                    string type = "SYNC";
                    string prefix;
                    if (adding == "[POSE]2")
                    {
                        prefix = "P:";
                        type = "POSE";
                        start = active_sitter;
                        end = active_sitter + 1;
                    }
                    integer x;
                    integer i;
                    for (i = start; i < end; i++)
                    {
                        // Insertion idx per slot. For SYNC, active_current_menu
                        // is the clicker's submenu; other slots assumed symmetric.
                        // Read-before-check: see SUBMENU branch comment for the
                        // LSL sequence-point gotcha.
                        integer ins = active_current_menu + 1;
                        string ival = llLinksetDataRead(qs_p_key(i, ins));
                        while (ival != "" && llGetSubString(ival, 0, 1) != "M:")
                        {
                            ++ins;
                            ival = llLinksetDataRead(qs_p_key(i, ins));
                        }
                        llSay(0, type + " Added: '" + msg + "' using anim '" + llList2String(chosen_animations, x) + "' to SITTER " + (string)i);
                        // Persist new pose entry. Type maps:
                        //   [POSE]2  → P    [SYNC]2 → S
                        qs_insert_pose(i, ins,
                            prefix + msg,
                            llGetSubString(type, 0, 0),
                            llList2String(chosen_animations, x),
                            llList2String(POS_LIST, i),
                            llList2String(ROT_LIST, i));
                        llMessageLinked(LINK_THIS, 90300, (string)i, prefix + msg + "|" + llList2String(chosen_animations, x) + "|" + llList2String(POS_LIST, i) + "|" + llList2String(ROT_LIST, i) + "|" + (string)ins);
                        x++;
                    }
                }
                if (msg != "" && (adding == "[POSE]2" || adding == "[SYNC]2"))
                {
                    llMessageLinked(LINK_THIS, 90005, "", llDumpList2String([controller, llList2String(SITTERS, active_sitter)], "|"));
                }
            }
        }
        else if (llGetOwnerKey(id) == llGetOwner())
        {
            list data = llParseString2List(msg, ["|"], []);
            integer num = llList2Integer(data, 1);
            if (llList2String(data, 0) == "REG")
            {
                HELPER_KEY_LIST = llListReplaceList(HELPER_KEY_LIST, [id], num, num);
                llRegionSay(comm_channel, "POS|" + (string)num + "|" + convert_to_world_positions(num) + "|" + (string)OLD_HELPER_METHOD + "|" + llList2String(SITTERS, num));
            }
            else if (llList2String(data, 0) == "MENU")
            {
                if (llList2Key(data, 2) == controller)
                {
                    llMessageLinked(LINK_SET, 90005, "", llDumpList2String([controller, llList2String(SITTERS, num)], "|"));
                }
            }
            else if (llList2String(data, 0) == "MOVED")
            {
                rotation f = llGetRot();
                vector target_rot = llRot2Euler((rotation)llList2String(data, 3) / f) * RAD_TO_DEG;
                vector target_pos = ((vector)llList2String(data, 2) - llGetPos()) / f;
                if ((string)target_pos != (string)llList2Vector(POS_LIST, num) || (string)target_rot != (string)llList2Vector(ROT_LIST, num))
                {
                    POS_LIST = llListReplaceList(POS_LIST, [target_pos], num, num);
                    ROT_LIST = llListReplaceList(ROT_LIST, [target_rot], num, num);
                    llMessageLinked(LINK_THIS, 90057, (string)num, (string)target_pos + "|" + (string)target_rot);
                }
            }
            else if (OLD_HELPER_METHOD)
            {
                integer sitter = (integer)llGetSubString(name, llSubStringIndex(name, " ") + 1, 99999);
                if (llList2String(data, 0) == "ANIMA")
                {
                    llMessageLinked(LINK_THIS, 90075, (string)sitter, llList2Key(data, 1));
                }
                else if (llList2String(data, 0) == "GETUP")
                {
                    llMessageLinked(LINK_THIS, 90076, (string)sitter, llList2Key(data, 1));
                }
            }
        }
    }

    on_rez(integer x)
    {
        llResetScript();
    }
}
