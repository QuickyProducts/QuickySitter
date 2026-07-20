/*
 * [QS]root-security - Specify who can sit and/or use the menu (QuickySitter fork of [AV]root-security)
 *
 * Minimally-invasive fork of avstock/[AV]root-security.lsl (2.2p04).
 * Diff against stock:
 *   1. Inter-plugin name couplings retargeted to the QS-renamed suite:
 *      menucontrol_script -> "[QS]root-control", RLV_script -> "[QS]root-RLV".
 *      The unused script_basename ("[AV]sitA") declaration was dropped — it
 *      hardcoded a sitter name and would have constrained QS's freedom to
 *      rename sitA; nothing reads it.
 *   2. The AVsitter `#version` preprocessor marker de-sugared to a plain
 *      `version` string — QS ships plain LSL; raw `#version` is not valid LSL.
 *   3. Product string rebranded to "QuickySitter(TM) Security".
 *   4. QS extension (1.05): third ACL category "Adjust" (OWNER/GROUP/ALL,
 *      default OWNER) controlling who may enter the adjust workflows
 *      ([HELPER]/[QUICKYHUD] and owner-gated registered [ADJUST] entries).
 *      This script only manages the setting and publishes it to LSD as
 *      qs:sec:adjust — enforcement lives in [QS]sitB / [QS]adjuster,
 *      which read the key synchronously in their gates. The qs:sec:
 *      prefix survives boot's re-seed wipe (^qs:(meta|cfg|...) pattern);
 *      after a full llLinksetDataReset the key is re-written on boot's
 *      QS_ALIVE_CENSUS broadcast and on our own state_entry. On
 *      CHANGED_OWNER the level resets to OWNER — a sold/transferred
 *      item must not carry the previous creator's widened ACL to the
 *      buyer (their group members could edit default poses).
 * Sit/menu access logic otherwise byte-identical to stock.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Original work: Copyright © the AVsitter Contributors (http://avsitter.github.io)
 * AVsitter™ is a trademark. For trademark use policy see:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string product = "QuickySitter™ Security";
string version = "1.0501";
string menucontrol_script = "[QS]root-control";
string RLV_script = "[QS]root-RLV";
key active_sitter;
integer active_prim;
integer active_script_channel;
integer menu_channel;
integer menu_handle;
list SIT_TYPES = ["ALL", "OWNER", "GROUP"];
integer SIT_INDEX;
integer MENU_INDEX;
string lastmenu;
list MENU_TYPES = [lastmenu]; //OSS::list MENU_TYPES; // Force error in LSO
// Adjust ACL (QS extension, see header diff #4). Order matters: index 0
// is the default, and OWNER preserves the pre-1.05 owner-only behavior.
list ADJUST_TYPES = ["OWNER", "GROUP", "ALL"];
integer ADJUST_INDEX;
// boot broadcasts QS_ALIVE_CENSUS after wiping/re-stamping LSD presence
// flags (plugin add/remove, re-seed, full reset) — our hook to re-write
// qs:sec:adjust after a full llLinksetDataReset.
integer QS_ALIVE_CENSUS = 90079;

// Publish the Adjust ACL level for the enforcing scripts ([QS]sitB
// render/dispatch gates, [QS]adjuster click handlers). LSD because those
// gates run synchronously inside dialog builders — no link-message
// round-trip is possible there.
write_adjust_access()
{
    llLinksetDataWrite("qs:sec:adjust", llList2String(ADJUST_TYPES, ADJUST_INDEX));
}

integer pass_security(key id, string context)
{
    integer ALLOWED = FALSE;
    string TYPE = llList2String(SIT_TYPES, SIT_INDEX);
    if (context == "MENU")
    {
        TYPE = llList2String(MENU_TYPES, MENU_INDEX);
    }
    if (TYPE == "GROUP")
    {
        if (llSameGroup(id) == TRUE)
        {
            ALLOWED = TRUE;
        }
    }
    else if (id == llGetOwner() || TYPE == "ALL")
    {
        ALLOWED = TRUE;
    }
    return ALLOWED;
}

check_sitters()
{
    integer i = llGetNumberOfPrims();
    while (llGetAgentSize(llGetLinkKey(i)) != ZERO_VECTOR)
    {
        key av = llGetLinkKey(i);
        if (pass_security(av, "SIT") == FALSE)
        {
            llUnSit(av);
            llDialog(av, product + " " + version + "\n\nSorry, Sit access is set to: " + llList2String(SIT_TYPES, SIT_INDEX), ["OK"], -164289491);
        }
        i--;
    }
}

back_to_adjust(integer SCRIPT_CHANNEL, key sitter)
{
    llMessageLinked(LINK_SET, 90101, (string)SCRIPT_CHANNEL + "|[ADJUST]|", sitter);
}

list order_buttons(list menu_items)
{
    return llList2List(menu_items, -3, -1) + llList2List(menu_items, -6, -4) + llList2List(menu_items, -9, -7) + llList2List(menu_items, -12, -10);
}

register_touch(key id, integer animation_menu_function, integer active_prim, integer giveFailedMessage)
{
    if (pass_security(id, "MENU"))
    {
        if (llGetInventoryType(menucontrol_script) == INVENTORY_SCRIPT)
        {
            if (check_for_RLV())
            {
                llMessageLinked(LINK_THIS, 90012, (string)active_prim, id);
            }
            else
            {
                llMessageLinked(LINK_THIS, 90007, "", id);
            }
        }
        else
        {
            llMessageLinked(LINK_SET, 90005, (string)animation_menu_function, id);
        }
    }
    else if (giveFailedMessage)
    {
        llDialog(id, product + " " + version + "\n\nSorry, Menu access is set to: " + llList2String(MENU_TYPES, MENU_INDEX), ["OK"], -164289491);
    }
}

main_menu()
{
    list buttons = (list)"Sit" + "Menu" + "Adjust";
    if (active_sitter) // OSS::if (osIsUUID(active_sitter) && active_sitter != NULL_KEY)
    {
        buttons = "[BACK]" + buttons;
    }
    dialog("Sit access: " + llList2String(SIT_TYPES, SIT_INDEX) + "\nMenu access: " + llList2String(MENU_TYPES, MENU_INDEX) + "\nAdjust access: " + llList2String(ADJUST_TYPES, ADJUST_INDEX) + "\n\nChange security settings:", buttons);
    lastmenu = "";
}

dialog(string text, list menu_items)
{
    llListenRemove(menu_handle);
    menu_handle = llListen((menu_channel = ((integer)llFrand(0x7FFFFF80) + 1) * -1), "", llGetOwner(), ""); // 7FFFFF80 = max float < 2^31
    llDialog(llGetOwner(), product + " " + version + "\n\n" + text, order_buttons(menu_items), menu_channel);
    llSetTimerEvent(600);
}

integer check_for_RLV()
{
    if (llGetInventoryType(RLV_script) == INVENTORY_SCRIPT)
    {
        return TRUE;
    }
    return FALSE;
}

default
{
    state_entry()
    {
        MENU_TYPES = SIT_TYPES;
        // Restore a persisted Adjust level before the first write — the
        // LSD key survives a script reset, unlike the RAM-only
        // SIT_INDEX/MENU_INDEX (which revert to stock defaults).
        integer idx = llListFindList(ADJUST_TYPES, [llLinksetDataRead("qs:sec:adjust")]);
        if (idx != -1) ADJUST_INDEX = idx;
        write_adjust_access();
        llMessageLinked(LINK_SET, 90202, (string)check_for_RLV(), "");
    }

    timer()
    {
        llSetTimerEvent(0);
        llListenRemove(menu_handle);
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == 90201)
        {
            llMessageLinked(LINK_SET, 90202, (string)check_for_RLV(), "");
        }
        else if (num == QS_ALIVE_CENSUS)
        {
            write_adjust_access();
        }
        else if (num == 90006)
        {
            if (llGetInventoryType(menucontrol_script) != INVENTORY_SCRIPT)
            {
                register_touch(id, (integer)msg, sender, FALSE);
            }
        }
        else if (num == 90100)
        {
            list data = llParseString2List(msg, ["|"], []);
            if (llList2String(data, 1) == "[SECURITY]")
            {
                if (id == llGetOwner())
                {
                    active_prim = sender;
                    active_script_channel = llList2Integer(data, 0);
                    active_sitter = llList2Key(data, 2);
                    main_menu();
                }
                else
                {
                    llRegionSayTo(id, 0, "Sorry, only the owner can change security settings.");
                    llMessageLinked(sender, 90101, llList2String(data, 0) + "|[ADJUST]|" + (string)id, llList2Key(data, 2));
                }
            }
        }
        else if (num == 90033)
        {
            llListenRemove(menu_handle);
        }
    }

    listen(integer listen_channel, string name, key id, string msg)
    {
        if (msg == "Sit")
        {
            dialog("Sit security:", SIT_TYPES);
            lastmenu = msg;
            return;
        }
        else if (msg == "Menu")
        {
            dialog("Menu security:", MENU_TYPES);
            lastmenu = msg;
            return;
        }
        else if (msg == "Adjust")
        {
            dialog("Adjust security — who may use the adjust tools\n([HELPER]/[QUICKYHUD] + owner-gated plugin entries):", ADJUST_TYPES);
            lastmenu = msg;
            return;
        }
        else
        {
            if (msg == "[BACK]")
            {
                llMessageLinked(LINK_SET, 90101, (string)active_script_channel + "|[ADJUST]|" + (string)id, active_sitter);
            }
            else if (lastmenu == "Sit")
            {
                SIT_INDEX = llListFindList(SIT_TYPES, [msg]);
                main_menu();
                check_sitters();
                return;
            }
            else if (lastmenu == "Menu")
            {
                MENU_INDEX = llListFindList(MENU_TYPES, [msg]);
                main_menu();
                return;
            }
            else if (lastmenu == "Adjust")
            {
                // Guarded (unlike the stock Sit/Menu branches): a -1 here
                // would persist a garbage level to LSD, not just to RAM.
                integer pick = llListFindList(ADJUST_TYPES, [msg]);
                if (pick != -1)
                {
                    ADJUST_INDEX = pick;
                    write_adjust_access();
                }
                main_menu();
                return;
            }
        }
        llListenRemove(menu_handle);
    }

    changed(integer change)
    {
        if (change & CHANGED_OWNER)
        {
            // Safety reset (see header diff #4): don't carry a widened
            // Adjust ACL across a sale/transfer if the creator forgot to
            // set it back — the new owner re-widens via [SECURITY] →
            // Adjust if wanted. Sit/Menu need no equivalent: their
            // indices are RAM-only and llGetOwner() re-resolves live.
            ADJUST_INDEX = 0; // OWNER
            write_adjust_access();
        }
        if (change & CHANGED_LINK)
        {
            check_sitters();
        }
    }

    touch_end(integer touched)
    {
        if (check_for_RLV() || llGetAgentSize(llGetLinkKey(llGetNumberOfPrims())) != ZERO_VECTOR)
        {
            register_touch(llDetectedKey(0), 0, llDetectedLinkNumber(0), TRUE);
        }
    }
}
