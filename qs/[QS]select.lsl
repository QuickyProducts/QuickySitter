/*
 * [QS]select - QuickySitter seat-select menu
 *
 * Fork of [AV]select from AVsitter2 (MPL 2.0). The only functional
 * change is replacing the hard-coded "[AV]sitA" reference used to
 * count sitter slots with "[QS]sitA"; everything else is verbatim.
 *
 * Why fork: stock [AV]select looks for "[AV]sitA 1", "[AV]sitA 2", ...
 * in the prim's inventory. QuickySitter renames the runtime scripts
 * to [QS]sitA so the count returns 1 even on multi-sitter setups,
 * which collapses the seat-select dialog to a single button.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Original work: Copyright © the AVsitter Contributors
 * AVsitter™ is a trademark. For trademark use policy see:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string product = "QuickySitter™ seat select";
string version = "0.901";
integer select_type;
list BUTTONS;
integer reading_notecard_section = -1;
key notecard_key;
key notecard_query;
string notecard_name = "AVpos";
string helper_object = "[AV]helper";

// QSALIVE — sitter-count cache (replaces the legacy
// llGetInventoryType("[QS]sitA " + i) loop). See qs/PROTOCOL.md § QSALIVE.
// Fallback default 7 is a sensible upper bound until slot-0 sitA replies.
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;
integer qs_alive = FALSE;
integer qs_sitter_count_cached = 1;

// QS_SELECT_HELLO — broadcast from this script on state_entry and
// in response to slot-0 sitA's QSALIVE-reply. sitB listens for it
// to gate select-driven menu logic without script-name inventory
// probes for [QS]select. (The legacy [AV]select probe in sitB
// stays as a stock-AVsitter backward-compat fallback.)
integer QS_SELECT_HELLO = 90092;
string CUSTOM_TEXT;
list SITTERS;
list SYNCS = [CUSTOM_TEXT]; //OSS::list SYNCS; // Force error in LSO
integer menu_channel;
integer menu_handle;
integer menu_type;
integer variable1;
integer verbose = 0;

Out(integer level, string out)
{
    if (verbose >= level)
    {
        llOwnerSay(llGetScriptName() + "[" + version + "] " + out);
    }
}

string strReplace(string str, string search, string replace)
{
    return llDumpList2String(llParseStringKeepNulls(str, [search], []), replace);
}

list order_buttons(list buttons)
{
    return llList2List(buttons, -3, -1) + llList2List(buttons, -6, -4) + llList2List(buttons, -9, -7) + llList2List(buttons, -12, -10);
}

menu(key av)
{
    integer sitter_index = llListFindList(SITTERS, [av]);
    if (sitter_index != -1)
    {
        list menu_buttons;
        integer i;
        for (i = 0; i < llGetListLength(BUTTONS); i++)
        {
            string avname = llKey2Name(llList2Key(SITTERS, i));
            if ((select_type == 0 && llList2Integer(SYNCS, i) == FALSE || select_type == 2) && avname != "" && av != llList2Key(SITTERS, i))
            {
                menu_buttons += "⊘" + llGetSubString(strReplace(avname, " Resident", " "), 0, 11);
            }
            else
            {
                menu_buttons += llList2String(BUTTONS, i);
            }
        }
        while ((llGetListLength(menu_buttons) + 1) % 3)
        {
            menu_buttons += " ";
        }
        menu_buttons += "[ADJUST]";
        llListenControl(menu_handle, TRUE);
        llDialog(av, product + " " + version + "\n\n" + CUSTOM_TEXT + "[" + llList2String(BUTTONS, sitter_index) + "]", order_buttons(menu_buttons), menu_channel);
    }
}
integer get_number_of_scripts()
{
    if (qs_alive) return qs_sitter_count_cached;
    return 7;  // pre-QSALIVE-reply fallback — sensible upper bound.
}

// Resize SITTERS / SYNCS / BUTTONS to the cached count. Preserves
// existing entries when growing (NULL_KEY / FALSE / "Sitter N" for
// new slots) and trims only the tail when shrinking — keeps the
// notecard-derived BUTTONS labels intact across QSALIVE-reply-driven
// resizes during boot.
init_lists()
{
    // Use get_number_of_scripts() so the 7-fallback applies before
    // the QSALIVE_REPLY arrives — otherwise state_entry pre-sizes
    // to qs_sitter_count_cached's default (1), the dataserver
    // handler's `section < llGetListLength(SITTERS)` guard drops
    // SITTER 1+ entries, and the late grow appends "Sitter N"
    // defaults instead of the notecard-supplied button labels.
    integer count = get_number_of_scripts();
    if (count < 1) count = 1;
    while (llGetListLength(SITTERS) > count)
    {
        SITTERS = llDeleteSubList(SITTERS, -1, -1);
        SYNCS   = llDeleteSubList(SYNCS,   -1, -1);
        BUTTONS = llDeleteSubList(BUTTONS, -1, -1);
    }
    integer i = llGetListLength(SITTERS);
    while (i < count)
    {
        SITTERS += NULL_KEY;
        SYNCS   += FALSE;
        BUTTONS += "Sitter " + (string)i;
        i++;
    }
}
default
{
    state_entry()
    {
        menu_channel = ((integer)llFrand(0x7FFFFF80) + 1) * -1; // 7FFFFF80 = max float < 2^31
        menu_handle = llListen(menu_channel, "", "", "");
        llListenControl(menu_handle, FALSE);
        // QSALIVE probe — slot-0 sitA replies with the real count.
        // init_lists pre-sizes via get_number_of_scripts() (returns
        // 7 until qs_alive flips); the reply handler re-runs it once
        // we know the actual count and shrinks the tail.
        qs_alive = FALSE;
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
        // Announce ourselves so sitB can gate select-driven menu logic
        // without script-name inventory probes. Re-broadcast on
        // QSALIVE_REPLY receipt below covers a late sitB boot.
        llMessageLinked(LINK_SET, QS_SELECT_HELLO, "", llGetScriptName());
        init_lists();
        notecard_key = llGetInventoryKey(notecard_name);
        Out(0, "Loading...");
        notecard_query = llGetNotecardLine(notecard_name, variable1);
    }
    listen(integer listen_channel, string name, key id, string message)
    {
        integer av_index = llListFindList(SITTERS, [id]);
        integer button_index = llListFindList(BUTTONS, [message]);
        if (av_index != -1)
        {
            if (message == "[ADJUST]" || message == "[HELPER]" || message == "[QUICKYHUD]")
            {
                // [QUICKYHUD] is sitA's hudproxy-gated entry into
                // ADJUSTMODE. Adjuster opens its own submenu with
                // [ADJUST OFF] / [BACK] from there.
                llMessageLinked(LINK_SET, 90101, llDumpList2String(["X", message, id], "|"), id);
            }
            else if (llGetSubString(message, 0, 0) == "⊘" || (select_type == 0 && llList2Integer(SYNCS, button_index) == FALSE && llList2Key(SITTERS, button_index) != NULL_KEY && llList2Key(SITTERS, button_index) != id))
            {
                menu(id);
            }
            else if (button_index != -1)
            {
                llMessageLinked(LINK_SET, 90030, (string)av_index, (string)button_index);
            }
        }
    }
    changed(integer change)
    {
        if (change & CHANGED_INVENTORY)
        {
            // Notecard-key change → full reset to re-read.
            // Sitter-count change is propagated by sitA-slot-0's
            // unsolicited QSALIVE-reply broadcast on its own reset, which
            // we handle via init_lists() in the link_message handler.
            if (llGetInventoryKey(notecard_name) != notecard_key)
            {
                llResetScript();
            }
        }
        if (change & CHANGED_LINK)
        {
            if (llGetAgentSize(llGetLinkKey(llGetNumberOfPrims())) == ZERO_VECTOR)
            {
                llListenControl(menu_handle, FALSE);
            }
        }
    }
    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QSALIVE_REPLY)
        {
            // Slot-0 sitA reports the real sitter count. Resize the
            // tracking lists if needed (preserves existing entries).
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
                // Re-announce so sitB-slot-0 (which just reset and
                // broadcast 90097) catches our presence flag.
                llMessageLinked(LINK_SET, QS_SELECT_HELLO, "", llGetScriptName());
            }
            return;
        }
        if (sender == llGetLinkNumber())
        {
            if (num == 90055)
            {
                list data = llParseStringKeepNulls(id, ["|"], []);
                if (llGetSubString(llList2String(data, 0), 0, 1) != "P:")
                {
                    SYNCS = llListReplaceList(SYNCS, [TRUE], (integer)msg, (integer)msg);
                }
                else
                {
                    SYNCS = llListReplaceList(SYNCS, [FALSE], (integer)msg, (integer)msg);
                }
            }
            else if (num == 90065)
            {
                integer index = llListFindList(SITTERS, [id]);
                if (index != -1)
                {
                    SITTERS = llListReplaceList(SITTERS, [NULL_KEY], index, index);
                }
            }
            else if (num == 90030)
            {
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)msg, (integer)msg);
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)((string)id), (integer)((string)id));
            }
            else if (num == 90070)
            {
                SITTERS = llListReplaceList(SITTERS, [id], (integer)msg, (integer)msg);
            }
            else if (num == 90009)
            {
                menu(id);
            }
        }
    }
    dataserver(key query_id, string data)
    {
        if (query_id == notecard_query)
        {
            if (data == EOF)
            {
                integer i;
                Out(0, "Ready");
            }
            else
            {
                data = llGetSubString(data, llSubStringIndex(data, "◆") + 1, 99999);
                data = llStringTrim(data, STRING_TRIM);
                string command = llGetSubString(data, 0, llSubStringIndex(data, " ") - 1);
                list parts = llParseString2List(llGetSubString(data, llSubStringIndex(data, " ") + 1, 99999), [" | ", " |", "| ", "|"], []);
                string part0 = llList2String(parts, 0);
                if (command == "TEXT")
                {
                    CUSTOM_TEXT = strReplace(part0, "\\n", "\n") + "\n";
                }
                else if (command == "SITTER")
                {
                    reading_notecard_section = (integer)part0;
                    string button_text = llList2String(parts, 1);
                    if (reading_notecard_section < llGetListLength(SITTERS))
                    {
                        if (button_text != "" && llListFindList(BUTTONS, [button_text]) == -1)
                        {
                            BUTTONS = llListReplaceList(BUTTONS, [button_text], reading_notecard_section, reading_notecard_section);
                            reading_notecard_section = -1;
                        }
                    }
                }
                else if (command == "MTYPE")
                {
                    menu_type = (integer)part0;
                }
                else if (command == "SELECT")
                {
                    select_type = (integer)part0;
                }
                else if (command == "POSE" || command == "SYNC")
                {
                    if (reading_notecard_section < llGetListLength(SITTERS) && reading_notecard_section != -1)
                    {
                        if (llList2String(BUTTONS, reading_notecard_section) == "Sitter " + (string)reading_notecard_section)
                        {
                            part0 = llGetSubString(part0, 0, 22);
                            if (llListFindList(BUTTONS, [part0]) == -1)
                            {
                                BUTTONS = llListReplaceList(BUTTONS, [part0], reading_notecard_section, reading_notecard_section);
                            }
                        }
                        else
                        {
                            BUTTONS = llListReplaceList(BUTTONS, ["Sitter " + (string)reading_notecard_section], reading_notecard_section, reading_notecard_section);
                            reading_notecard_section = -1;
                        }
                    }
                }
                notecard_query = llGetNotecardLine(notecard_name, ++variable1);
            }
        }
    }
}
