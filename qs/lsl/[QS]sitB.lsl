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
string #version = "0.01";
string BRAND;
integer OLD_HELPER_METHOD;
string main_script = "[QS]sitA";
string select_script = "[QS]select";
integer SET;
integer ETYPE;
integer MTYPE;
integer SWAP;
integer AMENU;
integer SELECT;
integer SCRIPT_CHANNEL;
integer number_of_sitters;
string CUSTOM_TEXT;
string ADJUST_MENU;
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

integer animation_menu(integer animation_menu_function)
{
    if ((animation_menu_function == -1 || llGetListLength(MENU_LIST) < 2) && (!helper_mode) && llGetInventoryType(select_script) == INVENTORY_SCRIPT)
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
        if (current_menu != -1 || llGetInventoryType(select_script) == INVENTORY_SCRIPT)
        {
            menu_items0 += "[BACK]";
        }
        string submenu_info;
        if (current_menu != -1)
        {
            submenu_info = llList2String(qs_pose_data(current_menu), 2);
        }
        if (helper_mode)
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
                menu_items2 += "[ADJUST]";
            }
        }
        if (llSubStringIndex(onSit, "ASK") && ((current_menu == -1 && SWAP == 1) || SWAP == 2 || llSubStringIndex(submenu_info, "S") != -1) && (number_of_sitters > 1 && llGetInventoryType(select_script) != INVENTORY_SCRIPT))
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
    SELECT            = (integer)llList2String(p, 4);
    AMENU             = (integer)llList2String(p, 5);
    OLD_HELPER_METHOD = (integer)llList2String(p, 6);
    BRAND             = llList2String(p, 11);
    onSit             = llList2String(p, 12);
    CUSTOM_TEXT       = llDumpList2String(llParseStringKeepNulls(llList2String(p, 13), ["\\n"], []), "\n");
    ADJUST_MENU       = llList2String(p, 14);   // SEP-joined string, kept as-is
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

    // number_of_sitters = total [QS]sitA scripts in the prim.
    i = 1;
    while (llGetInventoryType("[QS]sitA " + (string)i) == INVENTORY_SCRIPT)
        ++i;
    number_of_sitters = i;
}

default
{
    state_entry()
    {
        SEP = llUnescapeURL("%EF%BF%BD");
        SCRIPT_CHANNEL = (integer)llGetSubString(llGetScriptName(), llSubStringIndex(llGetScriptName(), " "), 99999);
        if (SCRIPT_CHANNEL)
            main_script += " " + (string)SCRIPT_CHANNEL;
        // Wait for [QS]boot to finish seeding this channel.
        while (llLinksetDataRead("qs:meta:" + (string)SCRIPT_CHANNEL) == "")
            llSleep(0.1);
        qs_load_from_lsd();
        memory();
    }

    listen(integer listen_channel, string name, key id, string msg)
    {
        string channel;
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
                if (llGetInventoryType(select_script) == INVENTORY_SCRIPT)
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
            llMessageLinked(LINK_SET, 90101, llDumpList2String([SCRIPT_CHANNEL, msg, CONTROLLER], "|"), MY_SITTER);
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_LINK)
        {
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
            has_RLV = FALSE;
            return;
        }
        if (num == 90202)
        {
            has_RLV = (integer)msg;
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
                // Adjuster signals "new pose added at LSD end". sitB just
                // appends its name to MENU_LIST so menu rendering sees it;
                // anim/pos/rot are already in LSD via adjuster's qs_add_pose.
                MENU_LIST += [llList2String(data, 0)];
                if (llGetListLength(data) == 4)
                {
                    integer new_idx = llGetListLength(MENU_LIST) - 1;
                    if (FIRST_INDEX == -1) FIRST_INDEX = new_idx;
                    ANIM_INDEX = new_idx;
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
