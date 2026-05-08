/*
 * [QS]sitA - QuickySitter main script - needs [QS]sitB to work
 *
 * Fork of [AV]sitA from AVsitter2 (MPL 2.0). Replaces the AVpos
 * notecard load with Linkset Data; on first boot per channel the
 * notecard is read once and seeded into LSD, then ignored.
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
string version = "0.11";
string main_script = "[QS]sitA";
string memoryscript = "[QS]sitB";
string expression_script = "[AV]faces";
string helper_object = "[AV]helper";
string adjust_script = "[QS]adjuster";
integer SCRIPT_CHANNEL;
list SITTERS;
integer SWAPPED;
key MY_SITTER;
key CONTROLLER;
string CUSTOM_TEXT;
list ADJUST_MENU;
integer SET = -1;
integer MTYPE = 0;
integer ETYPE = 1;
integer SELECT;
integer SWAP = 2;
integer AMENU = 2;
integer DFLT = 1;
list GENDERS;
integer OLD_HELPER_METHOD;
integer WARN = 1;
string FIRST_POSENAME;
string FIRST_ANIMATION_SEQUENCE;
string OLD_POSE_NAME;
string CURRENT_POSE_NAME;
string OLD_ANIMATION_FILENAME;
string CURRENT_ANIMATION_SEQUENCE;
string MALE_POSENAME;
string FIRST_MALE_ANIMATION_SEQUENCE;
string FEMALE_POSENAME;
string FIRST_FEMALE_ANIMATION_SEQUENCE;
string CURRENT_ANIMATION_FILENAME;
list SITTER_INFO = [FIRST_POSENAME]; //OSS::list SITTER_INFO; // Force error in LSO
integer SEQUENCE_POINTER;
vector FIRST_POSITION;
vector FIRST_ROTATION;
vector DEFAULT_POSITION;
vector DEFAULT_ROTATION;
vector CURRENT_POSITION;
vector CURRENT_ROTATION;
integer wrong_primcount;
integer prims;
// Per-sitter offset cache pushed by [QS]offset on sit. Layout:
// [pose_name, pos_diff, rot_diff, ...]. NOT persisted — volatile by design.
list MY_CUSTOMS;
integer HASKEYFRAME = FALSE;
integer REFERENCE;
key reused_key;
integer boot_done;
integer my_sittarget;
integer original_my_sittarget;
list SITTERS_SITTARGETS;
list ORIGINAL_SITTERS_SITTARGETS;
integer has_security;
integer has_texture;
string RLVDesignations;
integer increment_pointer;
integer pos_rot_adjust_toggle;
integer menu_channel;
integer menu_handle;
string BRAND;
string onSit;
integer speed_index;
integer verbose = 0;
// SEP = U+FFFD. Initialized at runtime via llUnescapeURL because the
// SL script editor mangles a literal U+FFFD to 0x20 (space) on upload,
// which silently splits anim names containing spaces.
string SEP;

// QuickySitter: notecard parsing + LSD writing moved to [QS]boot.lsl.
// sitA reads its channel's LSD directly in state_entry — no message
// round-trip during boot.

Out(integer level, string out)
{
    if (verbose >= level)
    {
        llOwnerSay(llGetScriptName() + "[" + version + "] " + out);
    }
}

list order_buttons(list buttons)
{
    return llList2List(buttons, -3, -1) + llList2List(buttons, -6, -4) + llList2List(buttons, -9, -7) + llList2List(buttons, -12, -10);
}

integer get_number_of_scripts()
{
    integer i;
    while (llGetInventoryType(main_script + " " + (string)(++i)) == INVENTORY_SCRIPT)
        ;
    return i;
}

dialog(string text, list menu_items)
{
    llListenRemove(menu_handle);
    menu_handle = llListen((menu_channel = ((integer)llFrand(0x7FFFFF80) + 1) * -1), "", CONTROLLER, ""); // 7FFFFF80 = max float < 2^31
    llDialog(CONTROLLER
             , product + " " + version + "\n\n" + text
             , llList2List(menu_items, -3, -1)
             + llList2List(menu_items, -6, -4)
             + llList2List(menu_items, -9, -7)
             + llList2List(menu_items, -12, -10)
             , menu_channel);
}

options_menu()
{
    list menu_items;
    if (has_texture)
    {
        menu_items += "[TEXTURE]";
    }
    if (llGetInventoryType(expression_script) == INVENTORY_SCRIPT)
    {
        menu_items += "[FACES]";
    }
    if (has_security)
    {
        menu_items += "[SECURITY]";
    }
    integer i;
    while (i < llGetListLength(ADJUST_MENU))
    {
        menu_items += llList2String(ADJUST_MENU, i);
        i = i + 2;
    }
    if (llGetInventoryType(helper_object) == INVENTORY_OBJECT && llGetInventoryType(adjust_script) == INVENTORY_SCRIPT)
    {
        menu_items += "[HELPER]";
    }
    if (!llGetListLength(menu_items))
    {
        adjust_pose_menu();
        return;
    }
    menu_items += "[POSE]";
    dialog("Adjust:", ["[BACK]"] + menu_items);
}

adjust_pose_menu()
{
    string posrot_button = "Position";
    string value_button = llList2String(["0.05m", "0.25m", "0.01m"], increment_pointer);
    if (pos_rot_adjust_toggle)
    {
        posrot_button = "Rotation";
        value_button = llList2String(["5°", "25°", "1°"], increment_pointer);
    }
    dialog("Personal adjustment:", ["[BACK]", posrot_button, value_button, "[DEFAULT]", "[SAVE]", "[SAVE ALL]", "X+", "Y+", "Z+", "X-", "Y-", "Z-"]);
}

integer IsInteger(string data)
{
    // This should allow for leading zeros, hence the "1"
    return data != "" && (string)((integer)("1" + data)) == "1" + data;
}

wipe_sit_targets()
{
    integer i;
    for (; i <= llGetNumberOfPrims(); i++)
    {
        string desc = (string)llGetLinkPrimitiveParams(i, [PRIM_DESC]);
        if (desc != "-1" && "#-1" != llGetSubString(desc, -3, -1))
        {
            llLinkSitTarget(i, ZERO_VECTOR, ZERO_ROTATION);
        }
    }
}

primcount_error()
{
    llDialog(llGetOwner(), "\nThere aren't enough prims for required SitTargets.\nYou must have one prim for each avatar to sit!", ["OK"], 23658);
}

sittargets()
{
    wrong_primcount = FALSE;
    prims = llGetObjectPrimCount(llGetKey());
    if (llGetListLength(SITTERS) > prims && WARN)
    {
        if (!SCRIPT_CHANNEL)
        {
            // primcount_error() inlined here:
            llDialog(llGetOwner(), "\nThere aren't enough prims for required SitTargets.\nYou must have one prim for each avatar to sit!", ["OK"], 23658);
        }
        wrong_primcount = TRUE;
    }
    integer i;
    SITTERS_SITTARGETS = [];
    list ASSIGNED_SITTARGETS = [];
    if (llGetListLength(SITTERS) == 1)
    {
        my_sittarget = llGetLinkNumber();
        SITTERS_SITTARGETS += my_sittarget;
    }
    else
    {
        for (i = 0; i < llGetListLength(SITTERS); i++)
        {
            SITTERS_SITTARGETS += 1000;
            ASSIGNED_SITTARGETS += FALSE;
        }
        for (i = 1; i <= prims; i++) // FIXME: will this work for single prim in OpenSim?
        {
            integer next = llListFindList(SITTERS_SITTARGETS, [1000]);
            string desc = (string)llGetLinkPrimitiveParams(i, [PRIM_DESC]);
            desc = llGetSubString(desc, llSubStringIndex(desc, "#") + 1, 99999);
            if (desc != "-1")
            {
                list data = llParseStringKeepNulls(desc, ["-"], []);
                if (llGetListLength(data) == 2 && IsInteger(llList2String(data, 0)) && IsInteger(llList2String(data, 1)))
                {
                    if (llList2Integer(data, 0) == SET)
                    {
                        SITTERS_SITTARGETS = llListReplaceList(SITTERS_SITTARGETS, [i], llList2Integer(data, 1), llList2Integer(data, 1));
                        ASSIGNED_SITTARGETS = llListReplaceList(ASSIGNED_SITTARGETS, [TRUE], llList2Integer(data, 1), llList2Integer(data, 1));
                        if (llListFindList(ASSIGNED_SITTARGETS, [FALSE]) == -1)
                        {
                            jump end;
                        }
                    }
                }
                else if (next != -1)
                {
                    SITTERS_SITTARGETS = llListReplaceList(SITTERS_SITTARGETS, [i], next, next);
                }
            }
        }
        @end;
        my_sittarget = llList2Integer(SITTERS_SITTARGETS, SCRIPT_CHANNEL);
    }
    original_my_sittarget = my_sittarget;
    ORIGINAL_SITTERS_SITTARGETS = SITTERS_SITTARGETS;
    // inline prep() here
    has_security = has_texture = FALSE;
    if (!SCRIPT_CHANNEL)
    {
        llMessageLinked(LINK_SET, 90201, "", ""); // 90201=Ask for info about plugins
    }

    set_sittarget();
}

prep()
{
    has_security = has_texture = FALSE;
    if (!SCRIPT_CHANNEL)
    {
        llMessageLinked(LINK_SET, 90201, "", ""); // 90201=Ask for info about plugins
    }
}

release_sitter(integer i)
{
    SITTERS = llListReplaceList(SITTERS, [""], i, i);
    if (i == SCRIPT_CHANNEL)
    {
        if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
        {
            if (MY_SITTER) // OSS::if (osIsUUID(MY_SITTER) && MY_SITTER != NULL_KEY)
            {
                llMessageLinked(LINK_SET, 90065, (string)SCRIPT_CHANNEL, MY_SITTER); // 90065=sitter gone
            }
            if (llGetAgentSize(MY_SITTER) != ZERO_VECTOR && CURRENT_ANIMATION_FILENAME != "")
            {
                llStopAnimation(CURRENT_ANIMATION_FILENAME);
            }
            MY_SITTER = "";
            MY_CUSTOMS = [];   // drop sitter-specific cache
            llListenRemove(menu_handle);
        }
    }
}

set_sittarget()
{
    vector target_pos = DEFAULT_POSITION;
    rotation target_rot = llEuler2Rot(DEFAULT_ROTATION * DEG_TO_RAD);
    if (my_sittarget != llGetLinkNumber())
    {
        vector local_avsit_prim_pos;
        rotation local_avsit_prim_rot;
        if (llGetLinkNumber() > 1)
        {
            local_avsit_prim_pos = llGetLocalPos();
            local_avsit_prim_rot = llGetLocalRot();
        }
        target_pos = local_avsit_prim_pos + DEFAULT_POSITION * local_avsit_prim_rot;
        target_rot = target_rot * local_avsit_prim_rot;
        if (my_sittarget > 1)
        {
            rotation local_target_prim_rot = llList2Rot(llGetLinkPrimitiveParams(my_sittarget, [PRIM_ROT_LOCAL]), 0);
            target_pos = (local_avsit_prim_pos + DEFAULT_POSITION * local_avsit_prim_rot - llList2Vector(llGetLinkPrimitiveParams(my_sittarget, [PRIM_POS_LOCAL]), 0)) / local_target_prim_rot;
            target_rot = target_rot / local_target_prim_rot;
        }
    }
    integer target = my_sittarget;
    if (llGetNumberOfPrims() == 1 && target == 1)
    {
        target = 0;
    }
    string desc = (string)llGetLinkPrimitiveParams(target, [PRIM_DESC]);
    if (desc != "-1" && "#-1" != llGetSubString(desc, -3, -1))
    {
        llLinkSitTarget(target, target_pos - <0.,0.,0.4> + llRot2Up(target_rot) * 0.05, target_rot);
    }
}

update_current_anim_name()
{
    list SEQUENCE = llParseStringKeepNulls(CURRENT_ANIMATION_SEQUENCE, [SEP], []);
    CURRENT_ANIMATION_FILENAME = llList2String(SEQUENCE, SEQUENCE_POINTER);
    string speed_text = llList2String(["", "+", "-"], speed_index);
    if (llGetInventoryType(CURRENT_ANIMATION_FILENAME + speed_text) == INVENTORY_ANIMATION)
    {
        CURRENT_ANIMATION_FILENAME += speed_text;
    }
    llSetTimerEvent((float)llList2String(SEQUENCE, SEQUENCE_POINTER + 1));
}

apply_current_anim(integer broadcast)
{
    SEQUENCE_POINTER = 0;
    update_current_anim_name();
    CURRENT_POSITION = DEFAULT_POSITION;
    CURRENT_ROTATION = DEFAULT_ROTATION;
    // Apply this sitter's personal offset (cache pushed by [QS]offset).
    // MY_CUSTOMS is per-sitter so no user_short lookup needed here.
    integer custom_index = llListFindList(MY_CUSTOMS, [CURRENT_POSE_NAME]);
    if (custom_index == -1)
        custom_index = llListFindList(MY_CUSTOMS, ["M#T!"]);
    llOwnerSay("[QS]sitA[" + version + "] apply_current_anim_in slot="
        + (string)SCRIPT_CHANNEL + " pose=" + CURRENT_POSE_NAME
        + " MY_CUSTOMS_len=" + (string)llGetListLength(MY_CUSTOMS)
        + " match_idx=" + (string)custom_index
        + " DEFAULT=" + (string)DEFAULT_POSITION);
    if (custom_index > -1)
    {
        CURRENT_POSITION += llList2Vector(MY_CUSTOMS, custom_index + 1);
        CURRENT_ROTATION += llList2Vector(MY_CUSTOMS, custom_index + 2);
    }
    llOwnerSay("[QS]sitA[" + version + "] apply_current_anim_out slot="
        + (string)SCRIPT_CHANNEL
        + " CURRENT_POSITION=" + (string)CURRENT_POSITION);
    if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
    {
        if (llGetAgentSize(MY_SITTER) != ZERO_VECTOR)
        {
            if (broadcast)
            {
                string POSENAME = CURRENT_POSE_NAME;
                integer IS_SYNC;
                if (llSubStringIndex(POSENAME, "P:"))
                {
                    IS_SYNC = TRUE;
                }
                else
                {
                    POSENAME = llGetSubString(POSENAME, 2, 99999);
                }
                string OLD_SYNC;
                if (OLD_POSE_NAME != CURRENT_POSE_NAME)
                {
                    if (llSubStringIndex(OLD_POSE_NAME, "P:"))
                    {
                        OLD_SYNC = OLD_POSE_NAME;
                    }
                }
                llMessageLinked(LINK_SET, 90045, llDumpList2String([SCRIPT_CHANNEL, POSENAME, CURRENT_ANIMATION_SEQUENCE, SET, llDumpList2String(SITTERS, "@"), OLD_SYNC, IS_SYNC], "|"), MY_SITTER); // 90045=Broadcast info about pose playing
            }
            if (HASKEYFRAME)
            {
                sit_using_prim_params();
            }
            if (CURRENT_ANIMATION_FILENAME != "")
            {
                llStartAnimation(CURRENT_ANIMATION_FILENAME);
            }
            if (OLD_ANIMATION_FILENAME != "" && OLD_ANIMATION_FILENAME != CURRENT_ANIMATION_FILENAME)
            {
                llSleep(0.2);
                llStopAnimation(OLD_ANIMATION_FILENAME);
            }
            if (!HASKEYFRAME)
            {
                sit_using_prim_params();
            }
        }
    }
}

sit_using_prim_params()
{
    integer sitter_prim = llGetNumberOfPrims();
    while (llGetAgentSize(llGetLinkKey(sitter_prim)) != ZERO_VECTOR)
    {
        if (llGetLinkKey(sitter_prim) == MY_SITTER)
        {
            jump ok;
        }
        sitter_prim--;
    }
    return;
    @ok;
    rotation localrot = ZERO_ROTATION;
    vector localpos = ZERO_VECTOR;
    if (llGetLinkNumber() > 1)
    {
        localrot = llGetLocalRot();
        localpos = llGetLocalPos();
    }
    if (HASKEYFRAME == 2 && !llGetStatus(STATUS_PHYSICS))
    {
        llSleep(0.4);
    }
    if (HASKEYFRAME && !llGetStatus(STATUS_PHYSICS))
    {
        llSetKeyframedMotion([], [KFM_COMMAND, KFM_CMD_PAUSE]);
    }
    vector finalLocalPos = CURRENT_POSITION * localrot + localpos;
    llSetLinkPrimitiveParamsFast(sitter_prim, [PRIM_ROT_LOCAL, llEuler2Rot((CURRENT_ROTATION + <0,0,0.002>) * DEG_TO_RAD) * localrot, PRIM_POS_LOCAL, finalLocalPos]);
    llOwnerSay("[QS]sitA[" + version + "] sit_using_prim_params slot="
        + (string)SCRIPT_CHANNEL
        + " CURRENT=" + (string)CURRENT_POSITION
        + " set PRIM_POS_LOCAL=" + (string)finalLocalPos);
    if (HASKEYFRAME && !llGetStatus(STATUS_PHYSICS))
    {
        llSleep(0.2);
        llSetKeyframedMotion([], [KFM_COMMAND, KFM_CMD_PLAY]);
    }
}

end_sitter()
{
    llSetTimerEvent(0);
    if (MY_SITTER) // OSS::if (osIsUUID(MY_SITTER) && MY_SITTER != NULL_KEY)
    {
        if (CURRENT_ANIMATION_FILENAME != "")
        {
            llStopAnimation(CURRENT_ANIMATION_FILENAME);
        }
        if (OLD_HELPER_METHOD)
        {
            llStartAnimation("sit");
        }
    }
}

// QSALIVE — presence reply for plugin discovery. See qs/PROTOCOL.md.
// Replaces the legacy llGetInventoryType("[AV]sitA N") slot-count loop
// for plugins that care to detect QuickySitter explicitly. Only the
// slot-0 sitA replies, so plugins receive exactly one 90097 per probe.
// Payload (pipe-delimited, parse with llParseString2List — KeepNulls
// would re-introduce the trailing-empty bug noted in MEMORY.md):
//   0: product token  (always "QuickySitter" for this fork)
//   1: version        (matches the global `version` string above)
//   2: sitter count   (same number get_number_of_scripts() returns)
//   3: capability CSV (feature flags; plugins can substring-match)
qs_alive_reply()
{
    llMessageLinked(LINK_SET, 90097,
        "QuickySitter|" + version + "|"
        + (string)get_number_of_scripts() + "|"
        + "customs90260,dump90098,offsetlsd_v1",
        "");
}

default
{
    state_entry()
    {
        SEP = llUnescapeURL("%EF%BF%BD");
        SCRIPT_CHANNEL = (integer)llGetSubString(llGetScriptName(), llSubStringIndex(llGetScriptName(), " "), 99999);
        while (llGetInventoryType(memoryscript) != INVENTORY_SCRIPT)
        {
            llSleep(0.1);
        }
        integer i;
        while (llGetInventoryType(main_script + " " + (string)(++i)) == INVENTORY_SCRIPT)
            ;
        while (i--)
            SITTERS += "";
        if (SCRIPT_CHANNEL)
            memoryscript += " " + (string)SCRIPT_CHANNEL;

        // Wait for [QS]boot to finish seeding this channel.
        while (llLinksetDataRead("qs:meta:" + (string)SCRIPT_CHANNEL) == "")
            llSleep(0.1);

        // Read settings + poses straight from LSD (no message round-trip).
        list p = llParseStringKeepNulls(llLinksetDataRead("qs:cfg:" + (string)SCRIPT_CHANNEL), ["\n"], []);
        MTYPE             = (integer)llList2String(p, 0);
        ETYPE             = (integer)llList2String(p, 1);
        SET               = (integer)llList2String(p, 2);
        SWAP              = (integer)llList2String(p, 3);
        SELECT            = (integer)llList2String(p, 4);
        AMENU             = (integer)llList2String(p, 5);
        OLD_HELPER_METHOD = (integer)llList2String(p, 6);
        WARN              = (integer)llList2String(p, 7);
        HASKEYFRAME       = (integer)llList2String(p, 8);
        REFERENCE         = (integer)llList2String(p, 9);
        DFLT              = (integer)llList2String(p, 10);
        BRAND             = llList2String(p, 11);
        onSit             = llList2String(p, 12);
        CUSTOM_TEXT       = llDumpList2String(llParseStringKeepNulls(llList2String(p, 13), ["\\n"], []), "\n");
        // Use llParseString2List (drops empties). When the AVpos has no
        // ADJUST line, boot writes "" for this field; KeepNulls would turn
        // that into [""] and the inlined options_menu below would emit an
        // empty button label, tripping llDialog with "all buttons must have
        // label strings".
        ADJUST_MENU       = llParseString2List(llList2String(p, 14), [SEP], []);
        RLVDesignations   = llList2String(p, 15);
        GENDERS = [];
        list gp = llCSV2List(llList2String(p, 16));
        integer gj;
        integer gn = llGetListLength(gp);
        for (gj = 0; gj < gn; ++gj)
            GENDERS += (integer)llList2String(gp, gj);

        string s = llLinksetDataRead("qs:sitter:" + (string)SCRIPT_CHANNEL);
        if (s != "")
            SITTER_INFO = llParseStringKeepNulls(s, [SEP], []);

        // Iterate poses; derive FIRST_POSENAME / MALE / FEMALE / FIRST_POSITION etc.
        FIRST_POSENAME = "";
        FIRST_ANIMATION_SEQUENCE = "";
        MALE_POSENAME = "";
        FIRST_MALE_ANIMATION_SEQUENCE = "";
        FEMALE_POSENAME = "";
        FIRST_FEMALE_ANIMATION_SEQUENCE = "";
        FIRST_POSITION = ZERO_VECTOR;
        FIRST_ROTATION = ZERO_VECTOR;
        i = 0;
        string val;
        while ((val = llLinksetDataRead("qs:p:" + (string)SCRIPT_CHANNEL + ":" + (string)i)) != "")
        {
            list pp = llParseStringKeepNulls(val, ["|"], []);
            string name = llList2String(pp, 0);
            string type = llList2String(pp, 1);
            string anim = llList2String(pp, 2);
            string pos  = llList2String(pp, 3);
            string rot  = llList2String(pp, 4);
            if (FIRST_POSENAME == "" && (type == "P" || type == "S"))
            {
                FIRST_POSENAME = name;
                CURRENT_POSE_NAME = name;
                FIRST_ANIMATION_SEQUENCE = anim;
                CURRENT_ANIMATION_SEQUENCE = anim;
            }
            if (type == "P" || type == "S")
            {
                string tail = llList2String(llParseStringKeepNulls(anim, [SEP], []), -1);
                if (tail == "M")
                {
                    MALE_POSENAME = name;
                    FIRST_MALE_ANIMATION_SEQUENCE = anim;
                }
                else if (tail == "F")
                {
                    FEMALE_POSENAME = name;
                    FIRST_FEMALE_ANIMATION_SEQUENCE = anim;
                }
            }
            if (name == FIRST_POSENAME && pos != "")
            {
                FIRST_POSITION = (vector)pos;
                FIRST_ROTATION = (vector)rot;
            }
            ++i;
        }
        DEFAULT_POSITION = CURRENT_POSITION = FIRST_POSITION;
        DEFAULT_ROTATION = CURRENT_ROTATION = FIRST_ROTATION;

        llPassTouches(MTYPE > 2);
        // Wipe sit targets (channel 0) then place them.
        if (!SCRIPT_CHANNEL)
        {
            integer k;
            for (k = 0; k <= llGetNumberOfPrims(); k++)
            {
                string desc = (string)llGetLinkPrimitiveParams(k, [PRIM_DESC]);
                if (desc != "-1" && "#-1" != llGetSubString(desc, -3, -1))
                    llLinkSitTarget(k, ZERO_VECTOR, ZERO_ROTATION);
            }
        }
        sittargets();
        boot_done = TRUE;
        // QSALIVE boot-announce: plugins that came up before us missed any
        // earlier replies, so emit one unsolicited 90097 once we're done
        // booting. Plugins that came up after us still get an answer via
        // the 90096 probe path. Only slot 0 emits — see qs_alive_reply().
        if (!SCRIPT_CHANNEL) qs_alive_reply();
        llOwnerSay(llGetScriptName() + "[" + version + "] state_entry done slot="
            + (string)SCRIPT_CHANNEL);
    }

    timer()
    {
        SEQUENCE_POINTER += 2;
        list SEQUENCE = llParseStringKeepNulls(CURRENT_ANIMATION_SEQUENCE, [SEP], []);
        if (SEQUENCE_POINTER >= llGetListLength(SEQUENCE) || llListFindList(["M", "F"], llList2List(SEQUENCE, SEQUENCE_POINTER, SEQUENCE_POINTER)) != -1)
        {
            SEQUENCE_POINTER = 0;
        }
        OLD_ANIMATION_FILENAME = CURRENT_ANIMATION_FILENAME;
        update_current_anim_name();
        if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
        {
            if (llGetAgentSize(MY_SITTER) != ZERO_VECTOR)
            {
                if (CURRENT_ANIMATION_FILENAME != "")
                {
                    llStartAnimation(CURRENT_ANIMATION_FILENAME);
                }
                if (OLD_ANIMATION_FILENAME != "" && OLD_ANIMATION_FILENAME != CURRENT_ANIMATION_FILENAME)
                {
                    llSleep(1.);
                    llStopAnimation(OLD_ANIMATION_FILENAME);
                }
            }
        }
    }

    touch_end(integer touched)
    {
        if (SCRIPT_CHANNEL == 0 && (!has_security) && MTYPE < 3)
        {
            llMessageLinked(LINK_SET, 90005, "", llDetectedKey(0)); // 90005=send menu to user
        }
    }

    listen(integer listen_channel, string name, key id, string msg)
    {
        integer index = llListFindList(ADJUST_MENU, [msg]);
        if (index != -1)
        {
            if (id != MY_SITTER && !(AMENU & 4))
            {
                id = (string)id + "|" + (string)MY_SITTER;
            }
            llMessageLinked(LINK_SET, llList2Integer(ADJUST_MENU, index + 1), msg, id);
        }
        else
        {
            index = llListFindList(["Position", "Rotation", "X+", "Y+", "Z+", "X-", "Y-", "Z-", "0.05m", "0.25m", "0.01m", "5°", "25°", "1°"], [msg]);
            if (msg == "[BACK]")
            {
                llMessageLinked(LINK_SET, 90005, "", (string)CONTROLLER + "|" + (string)MY_SITTER); // 90005=send menu to user
            }
            else if (msg == "[POSE]")
            {
                adjust_pose_menu();
            }
            else if (msg == "[DEFAULT]")
            {
                CURRENT_POSITION = DEFAULT_POSITION;
                CURRENT_ROTATION = DEFAULT_ROTATION;
                sit_using_prim_params();
                adjust_pose_menu();
            }
            else if (msg == "[SAVE ALL]")
            {
                dialog("Save personal position offset for all poses?", ["[BACK]", "[ALL POSES]"]);
            }
            else if (msg == "[ALL POSES]")
            {
                vector pd = CURRENT_POSITION - DEFAULT_POSITION;
                vector rd = CURRENT_ROTATION - DEFAULT_ROTATION;
                // Wipe pose-specific entries from MY_CUSTOMS, keep only M#T!.
                integer i = llGetListLength(MY_CUSTOMS) - 3;
                while (i >= 0)
                {
                    if (llList2String(MY_CUSTOMS, i) != "M#T!")
                        MY_CUSTOMS = llDeleteSubList(MY_CUSTOMS, i, i + 2);
                    i -= 3;
                }
                // Replace any existing M#T!.
                integer mi = llListFindList(MY_CUSTOMS, ["M#T!"]);
                if (mi >= 0) MY_CUSTOMS = llDeleteSubList(MY_CUSTOMS, mi, mi + 2);
                MY_CUSTOMS += ["M#T!", pd, rd];
                // Persist to [QS]offset.
                llMessageLinked(LINK_THIS, 90262, "M#T!|" + (string)pd + "|" + (string)rd, MY_SITTER);
                adjust_pose_menu();
                llRegionSayTo(id, 0, "Personal position saved for all poses.");
            }
            else if (msg == "[SAVE]")
            {
                vector pd = CURRENT_POSITION - DEFAULT_POSITION;
                vector rd = CURRENT_ROTATION - DEFAULT_ROTATION;
                integer custom_index = llListFindList(MY_CUSTOMS, [CURRENT_POSE_NAME]);
                if (custom_index >= 0)
                    MY_CUSTOMS = llDeleteSubList(MY_CUSTOMS, custom_index, custom_index + 2);
                MY_CUSTOMS += [CURRENT_POSE_NAME, pd, rd];
                // Persist to [QS]offset.
                llMessageLinked(LINK_THIS, 90262, CURRENT_POSE_NAME + "|" + (string)pd + "|" + (string)rd, MY_SITTER);
                adjust_pose_menu();
                llRegionSayTo(id, 0, "Personal position saved for this pose.");
            }
            else if (index != -1)
            {
                if (index < 2)
                {
                    pos_rot_adjust_toggle = !pos_rot_adjust_toggle;
                }
                else if (index < 8)
                {
                    float change = llList2Float([0.05, 0.25, 0.01], increment_pointer);
                    if (llGetSubString(msg, 1, 1) == "-")
                    {
                        change = -1 * change;
                    }
                    vector direction = <1,0,0>;
                    if (llGetSubString(msg, 0, 0) == "Y")
                    {
                        direction = <0,1,0>;
                    }
                    else if (llGetSubString(msg, 0, 0) == "Z")
                    {
                        direction = <0,0,1>;
                    }
                    if (pos_rot_adjust_toggle)
                    {
                        CURRENT_ROTATION += direction * change * 100;
                    }
                    else
                    {
                        vector c = direction * change;
                        if (REFERENCE)
                        {
                            if (llGetLinkNumber() > 1)
                            {
                                c /= llGetLocalRot();
                            }
                        }
                        else
                        {
                            c /= llGetRot();
                        }
                        CURRENT_POSITION += c;
                    }
                    sit_using_prim_params();
                }
                else
                {
                    increment_pointer = (increment_pointer + 1) % 3;
                }
                adjust_pose_menu();
            }
            else if (msg == "[HELPER]" && id != llGetOwner() && llSubStringIndex(llGetLinkName(!!llGetLinkNumber()), "HELPER") == -1)
            {
                dialog("Only the owner can rez the helpers. If the owner is nearby they can type '/5 helper' in chat.", ["[BACK]"]);
            }
            else
            {
                llMessageLinked(LINK_SET, 90100, (string)SCRIPT_CHANNEL + "|" + msg + "|" + (string)MY_SITTER + "|" + (string)OLD_HELPER_METHOD, id); // 90100=Menu choice
            }
        }
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        integer one = (integer)msg;
        integer two = (integer)((string)id);
        integer target;
        list data;
        // 90303 handler removed — sitA reads settings from LSD directly in
        // state_entry now. [QS]boot resets sitA after seeding so this runs
        // with populated LSD.
        if (num == 90260)
        {
            llOwnerSay("[QS]sitA[" + version + "] 90260 in slot="
                + (string)SCRIPT_CHANNEL
                + " id=" + (string)id
                + " MY_SITTER=" + (string)MY_SITTER
                + " match=" + (string)(id == MY_SITTER)
                + " msg=" + msg);
            if (id != MY_SITTER) return;
            list mp = llParseStringKeepNulls(msg, ["|"], []);
            string pname = llList2String(mp, 0);
            integer mi = llListFindList(MY_CUSTOMS, [pname]);
            if (mi >= 0) MY_CUSTOMS = llDeleteSubList(MY_CUSTOMS, mi, mi + 2);
            MY_CUSTOMS += [pname,
                (vector)llList2String(mp, 1),
                (vector)llList2String(mp, 2)];

            llOwnerSay("[QS]sitA[" + version + "] 90260 cached pname="
                + pname + " CURRENT_POSE_NAME=" + CURRENT_POSE_NAME
                + " CURRENT=" + (string)CURRENT_POSITION
                + " DEFAULT=" + (string)DEFAULT_POSITION);

            if (CURRENT_POSITION == DEFAULT_POSITION
                && CURRENT_ROTATION == DEFAULT_ROTATION)
            {
                integer ci = llListFindList(MY_CUSTOMS, [CURRENT_POSE_NAME]);
                if (ci == -1) ci = llListFindList(MY_CUSTOMS, ["M#T!"]);
                if (ci > -1)
                {
                    CURRENT_POSITION = DEFAULT_POSITION
                        + llList2Vector(MY_CUSTOMS, ci + 1);
                    CURRENT_ROTATION = DEFAULT_ROTATION
                        + llList2Vector(MY_CUSTOMS, ci + 2);
                    sit_using_prim_params();
                    llOwnerSay("[QS]sitA[" + version
                        + "] 90260 re-applied offset; new CURRENT="
                        + (string)CURRENT_POSITION);
                }
                else
                {
                    llOwnerSay("[QS]sitA[" + version
                        + "] 90260 no MY_CUSTOMS match for pose="
                        + CURRENT_POSE_NAME);
                }
            }
            else
            {
                llOwnerSay("[QS]sitA[" + version
                    + "] 90260 CURRENT != DEFAULT — no re-apply");
            }
            return;
        }
        if (num == 90263) // 90263=adjuster overwrote pose default; drop stale personal offset
        {
            // [HELPER] [SAVE] in adjuster sends this right before 90301 so
            // apply_current_anim (triggered via the 90055 chain) doesn't add
            // a now-stale pose-specific offset on top of the freshly saved
            // default. M#T! survives — that's the user's all-poses offset.
            if (one == SCRIPT_CHANNEL)
            {
                string pname = (string)id;
                integer mi = llListFindList(MY_CUSTOMS, [pname]);
                if (mi >= 0) MY_CUSTOMS = llDeleteSubList(MY_CUSTOMS, mi, mi + 2);
            }
            return;
        }
        if (num == 90096) // 90096=QSALIVE probe; only slot-0 sitA replies (90097)
        {
            if (SCRIPT_CHANNEL == 0) qs_alive_reply();
            return;
        }
        if (num == 90075) // 90075=old-style helper ask to animate
        {
            if (one == SCRIPT_CHANNEL)
            {
                llRequestPermissions(id, PERMISSION_TRIGGER_ANIMATION);
            }
            return;
        }
        if (num == 90076) // 90076=old-style helper stop animating
        {
            release_sitter(one);
            return;
        }
        if (num == 90030) // 90030=swap sitters
        {
            if (one == SCRIPT_CHANNEL || two == SCRIPT_CHANNEL)
            {
                end_sitter();
                reused_key = llList2Key(SITTERS, one);
                if (one == SCRIPT_CHANNEL)
                {
                    reused_key = llList2Key(SITTERS, two);
                }
                if (reused_key) // OSS::if (osIsUUID(reused_key) && reused_key != NULL_KEY)
                {
                    SWAPPED = TRUE;
                    llRequestPermissions(reused_key, PERMISSION_TRIGGER_ANIMATION);
                }
            }
            SITTERS_SITTARGETS = llListReplaceList(llListReplaceList(SITTERS_SITTARGETS, [llList2Integer(SITTERS_SITTARGETS, two)], one, one), [llList2Integer(SITTERS_SITTARGETS, one)], two, two);
            my_sittarget = llList2Integer(SITTERS_SITTARGETS, SCRIPT_CHANNEL);
            set_sittarget();
            SITTERS = llListReplaceList(llListReplaceList(SITTERS, [""], one, one), [""], two, two);
            MY_SITTER = llList2Key(SITTERS, SCRIPT_CHANNEL);
            return;
        }
        if (num == 90070) // 90070=update SITTERS after permission granted
        {
            if (one != SCRIPT_CHANNEL)
            {
                SITTERS = llListReplaceList(SITTERS, [id], one, one);
            }
            return;
        }
        if (num == 90150) // 90150=ask other AVsitA scripts to place their sittargets again
        {
            sittargets();
            return;
        }
        if (num == 90202) // 90202=security script present in root
        {
            has_security = TRUE;
            llPassTouches(has_security);
            return;
        }
        if (num == 90203) // 90203=texture script present in root (unused)
        {
            has_texture = TRUE;
            return;
        }
        if (num == 90298) // 90298=show SitTargets (/5 targets)
        {
            target = my_sittarget;
            if (llGetNumberOfPrims() == 1 && target == 1)
            {
                target = 0;
            }
            llSetLinkPrimitiveParams(target, [PRIM_TEXT, (string)SET + "-" + (string)SCRIPT_CHANNEL, <1,1,0>, 1]);
            llSleep(5);
            llSetLinkPrimitiveParams(target, [PRIM_TEXT, "", <1,1,1>, 1]);
            return;
        }
        if (num == 90011) // 90011=set link camera
        {
            llSetLinkCamera(LINK_THIS, (vector)msg, (vector)((string)id));
            return;
        }
        if (num == 90033) // 90033=clear menu listener
        {
            llListenRemove(menu_handle);
            return;
        }
        if (id == MY_SITTER)
        {
            if ((num == 90001 || num == 90002) // 90001=start an overlay animation
                                               // 90002=stop an overlay animation
                && (PERMISSION_TRIGGER_ANIMATION & llGetPermissions()) != 0)
            {
                if (num == 90001)
                    llStartAnimation(msg);
                else
                    llStopAnimation(msg);
            }
            data = llParseStringKeepNulls(msg, ["|"], data);
            if (num == 90101) // 90101=menu option chosen
            {
                CONTROLLER = llList2Key(data, 2);
                if ((msg = llList2String(data, 1)) == "[ADJUST]") // WARNING: reusing msg
                {
                    // options_menu() inlined here:
                    data = [];
                    if (has_texture)
                    {
                        data += "[TEXTURE]";
                    }
                    if (llGetInventoryType(expression_script) == INVENTORY_SCRIPT)
                    {
                        data += "[FACES]";
                    }
                    if (has_security)
                    {
                        data += "[SECURITY]";
                    }
                    integer i;
                    while (i < llGetListLength(ADJUST_MENU))
                    {
                        data += llList2String(ADJUST_MENU, i);
                        i = i + 2;
                    }
                    if (llGetInventoryType(helper_object) == INVENTORY_OBJECT && llGetInventoryType(adjust_script) == INVENTORY_SCRIPT)
                    {
                        data += "[HELPER]";
                    }
                    if (!llGetListLength(data))
                    {
                        adjust_pose_menu();
                        return;
                    }
                    data += "[POSE]";
                    dialog("Adjust:", ["[BACK]"] + data);
                    return;
                }
                if (msg == "Harder >>" || msg == "<< Softer")
                {
                    llMessageLinked(LINK_SET, 90005, "", llDumpList2String([CONTROLLER, MY_SITTER], "|"));
                    return;
                }
                if (msg == "[SWAP]")
                {
                    // target here means target script
                    target = SCRIPT_CHANNEL + 1;
                    list X = SITTERS + SITTERS;
                    if (llSubStringIndex(CURRENT_POSE_NAME, "P:"))
                    {
                        while (llList2Key(X, target) == "" && target + 1 < llGetListLength(X))
                        {
                            target++;
                        }
                        if (llList2Key(X, target) == MY_SITTER)
                        {
                            target++;
                        }
                    }
                    else
                    {
                        while (llList2String(X, target) != "" && target < llGetListLength(SITTERS) + SCRIPT_CHANNEL + 1)
                        {
                            target++;
                        }
                    }
                    target %= llGetListLength(SITTERS);
                    llMessageLinked(LINK_THIS, 90030, (string)SCRIPT_CHANNEL, (string)target);
                }
                return;
            }
        }
        if (one == SCRIPT_CHANNEL)
        {
            if (num == 90055) // 90055=anim info from AVsitB
            {
                data = llParseStringKeepNulls(id, ["|"], data);
                OLD_POSE_NAME = CURRENT_POSE_NAME;
                CURRENT_POSE_NAME = llList2String(data, 0);
                OLD_ANIMATION_FILENAME = CURRENT_ANIMATION_FILENAME;
                CURRENT_ANIMATION_SEQUENCE = llList2String(data, 1);
                DEFAULT_POSITION = CURRENT_POSITION = (vector)llList2String(data, 2);
                DEFAULT_ROTATION = CURRENT_ROTATION = (vector)llList2String(data, 3);
                if (FIRST_POSENAME == "" || CURRENT_POSE_NAME == FIRST_POSENAME)
                {
                    FIRST_POSENAME = CURRENT_POSE_NAME;
                    FIRST_POSITION = DEFAULT_POSITION;
                    FIRST_ROTATION = DEFAULT_ROTATION;
                    FIRST_ANIMATION_SEQUENCE = CURRENT_ANIMATION_SEQUENCE;
                }
                speed_index = llList2Integer(data, 5);
                apply_current_anim(llList2Integer(data, 4));
                set_sittarget();
                return;
            }
            if (num == 90057) // 90057=helper moved, update position
            {
                data = llParseStringKeepNulls(id, ["|"], data);
                llOwnerSay("[QS]sitA[" + version + "] 90057 in slot="
                    + (string)SCRIPT_CHANNEL
                    + " sender=" + (string)sender
                    + " new_pos=" + llList2String(data, 0)
                    + " new_rot=" + llList2String(data, 1));
                CURRENT_POSITION = (vector)llList2String(data, 0);
                CURRENT_ROTATION = (vector)llList2String(data, 1);
                sit_using_prim_params();
                return;
            }
        }
    }

    changed(integer change)
    {
        integer i;
        if (change & CHANGED_LINK)
        {
            SWAPPED = FALSE;
            integer stood;
            if (SET == -1 && llGetListLength(SITTERS) > 1)
            {
                list AVPRIMS;
                i = llGetNumberOfPrims();
                while (llGetAgentSize(llGetLinkKey(i)) != ZERO_VECTOR)
                {
                    if (llListFindList(SITTERS, [llGetLinkKey(i)]) == -1)
                    {
                        integer sitterGender = llList2Integer(llGetObjectDetails(llGetLinkKey(i), [OBJECT_BODY_SHAPE_TYPE]), 0);
                        integer first_available = llListFindList(SITTERS, [""]);
                        integer first_unassigned = -1;
                        integer j;
                        while (j < llGetListLength(SITTERS))
                        {
                            if (llList2String(SITTERS, j) == "")
                            {
                                if (llList2Integer(GENDERS, j) == sitterGender)
                                {
                                    first_available = j;
                                    jump foundavailable;
                                }
                                if (llList2Integer(GENDERS, j) == -1 && first_unassigned == -1)
                                {
                                    first_unassigned = j;
                                }
                            }
                            j++;
                        }
                        if (first_unassigned > first_available)
                        {
                            first_available = first_unassigned;
                        }
                        @foundavailable;
                        if (first_available == SCRIPT_CHANNEL)
                        {
                            if (sitterGender)
                            {
                                if (MALE_POSENAME != "")
                                {
                                    if (CURRENT_POSE_NAME == FIRST_POSENAME)
                                    {
                                        CURRENT_POSE_NAME = MALE_POSENAME;
                                        CURRENT_ANIMATION_SEQUENCE = FIRST_MALE_ANIMATION_SEQUENCE;
                                    }
                                }
                            }
                            else
                            {
                                if (FEMALE_POSENAME != "")
                                {
                                    if (CURRENT_POSE_NAME == FIRST_POSENAME)
                                    {
                                        CURRENT_POSE_NAME = FEMALE_POSENAME;
                                        CURRENT_ANIMATION_SEQUENCE = FIRST_FEMALE_ANIMATION_SEQUENCE;
                                    }
                                }
                            }
                            llRequestPermissions(llGetLinkKey(i), PERMISSION_TRIGGER_ANIMATION);
                            llMessageLinked(LINK_SET, 90060, (string)SCRIPT_CHANNEL, llGetLinkKey(i)); // 90060=new sitter
                        }
                        else
                        {
                            llMessageLinked(LINK_THIS, 90056, (string)SCRIPT_CHANNEL, llDumpList2String([CURRENT_POSE_NAME, CURRENT_ANIMATION_SEQUENCE, CURRENT_POSITION, CURRENT_ROTATION], "|")); // 90056=send anim info
                        }
                    }
                    AVPRIMS += llGetLinkKey(i);
                    i--;
                }
                for (i = 0; i < llGetListLength(SITTERS); i++)
                {
                    if (llList2String(SITTERS, i) != "" && llListFindList(AVPRIMS, [llList2Key(SITTERS, i)]) == -1)
                    {
                        llSetTimerEvent(0);
                        stood = TRUE;
                        SITTERS = llListReplaceList(SITTERS, [""], i, i);
                        if (i == SCRIPT_CHANNEL)
                        {
                            if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
                            {
                                if (MY_SITTER) // OSS::if (osIsUUID(MY_SITTER) && MY_SITTER != NULL_KEY)
                                {
                                    llMessageLinked(LINK_SET, 90065, (string)SCRIPT_CHANNEL, MY_SITTER); // 90065=sitter gone
                                }
                                if (llGetAgentSize(MY_SITTER) != ZERO_VECTOR && (integer)CURRENT_ANIMATION_FILENAME)
                                {
                                    llStopAnimation(CURRENT_ANIMATION_FILENAME);
                                }
                                MY_SITTER = "";
                                llListenRemove(menu_handle);
                            }
                        }
                    }
                }
            }
            else
            {
                for (i = 0; i < llGetListLength(SITTERS); i++)
                {
                    string existing_sitter = llList2String(SITTERS, i);
                    key actual_sitter = llAvatarOnLinkSitTarget(llList2Integer(SITTERS_SITTARGETS, i));
                    if (llGetListLength(SITTERS) == 1)
                    {
                        actual_sitter = llAvatarOnSitTarget();
                    }
                    if (existing_sitter != "")
                    {
                        if (actual_sitter == NULL_KEY)
                        {
                            llSetTimerEvent(0);
                            stood = TRUE;
                            release_sitter(i);
                        }
                    }
                    else if (actual_sitter) // OSS::else if (osIsUUID(actual_sitter) && actual_sitter != NULL_KEY)
                    {
                        if (i == SCRIPT_CHANNEL)
                        {
                            if (llList2Integer(llGetObjectDetails(actual_sitter, [OBJECT_BODY_SHAPE_TYPE]), 0))
                            {
                                if (MALE_POSENAME != "")
                                {
                                    if (CURRENT_POSE_NAME == FIRST_POSENAME)
                                    {
                                        CURRENT_POSE_NAME = MALE_POSENAME;
                                        CURRENT_ANIMATION_SEQUENCE = FIRST_MALE_ANIMATION_SEQUENCE;
                                    }
                                }
                            }
                            else
                            {
                                if (FEMALE_POSENAME != "")
                                {
                                    if (CURRENT_POSE_NAME == FIRST_POSENAME)
                                    {
                                        CURRENT_POSE_NAME = FEMALE_POSENAME;
                                        CURRENT_ANIMATION_SEQUENCE = FIRST_FEMALE_ANIMATION_SEQUENCE;
                                    }
                                }
                            }
                            llRequestPermissions(actual_sitter, PERMISSION_TRIGGER_ANIMATION);
                            llMessageLinked(LINK_SET, 90060, (string)SCRIPT_CHANNEL, actual_sitter); // 90060=new sitter
                        }
                        else
                        {
                            llMessageLinked(LINK_THIS, 90056, (string)SCRIPT_CHANNEL, llDumpList2String([CURRENT_POSE_NAME, CURRENT_ANIMATION_SEQUENCE, CURRENT_POSITION, CURRENT_ROTATION], "|")); // 90056=send anim info
                        }
                    }
                }
            }
            if (stood && (string)SITTERS == "")
            {
                if (DFLT || llSubStringIndex(CURRENT_POSE_NAME, "P:") == -1)
                {
                    DEFAULT_POSITION = FIRST_POSITION;
                    DEFAULT_ROTATION = FIRST_ROTATION;
                    CURRENT_POSE_NAME = FIRST_POSENAME;
                    CURRENT_ANIMATION_SEQUENCE = FIRST_ANIMATION_SEQUENCE;
                    my_sittarget = original_my_sittarget;
                    SITTERS_SITTARGETS = ORIGINAL_SITTERS_SITTARGETS;
                    set_sittarget();
                }
                // inline prep() here
                has_security = has_texture = FALSE;
                if (!SCRIPT_CHANNEL)
                {
                    llMessageLinked(LINK_SET, 90201, "", ""); // 90201=Ask for info about plugins
                }
            }
            if (prims != llGetObjectPrimCount(llGetKey()))
            {
                if (!SCRIPT_CHANNEL)
                {
                    // wipe_sit_targets() inlined here:
                    for (i = 0; i <= llGetNumberOfPrims(); i++)
                    {
                        string desc = (string)llGetLinkPrimitiveParams(i, [PRIM_DESC]);
                        if (desc != "-1" && "#-1" != llGetSubString(desc, -3, -1))
                        {
                            llLinkSitTarget(i, ZERO_VECTOR, ZERO_ROTATION);
                        }
                    }

                    llMessageLinked(LINK_SET, 90150, "", ""); // 90150=ask other AVsitA scripts to place their sittargets again
                }
                // inline prep() here
                has_security = has_texture = FALSE;
                if (!SCRIPT_CHANNEL)
                {
                    llMessageLinked(LINK_SET, 90201, "", ""); // 90201=Ask for info about plugins
                }
            }
        }
        if (change & CHANGED_INVENTORY)
        {
            // get_number_of_scripts() inlined here:
            while (llGetInventoryType(main_script + " " + (string)(++i)) == INVENTORY_SCRIPT)
                ;
            // [QS]boot owns the notecard now and resets if the notecard
            // changes. sitA only resets on sitter-count or sitB changes.
            if (i != llGetListLength(SITTERS) || llGetInventoryType(memoryscript) != INVENTORY_SCRIPT)
            {
                end_sitter();
                llResetScript();
            }
        }
    }

    run_time_permissions(integer perm)
    {
        if (perm & PERMISSION_TRIGGER_ANIMATION)
        {
            llStopAnimation("sit");
            if (llGetInventoryType("AVhipfix") == INVENTORY_ANIMATION)
            {
                llStartAnimation("AVhipfix");
            }
            integer animation_menu_function;
            if (llGetPermissionsKey() != reused_key)
            {
                animation_menu_function = -1;
            }
            reused_key = "";
            SITTERS = llListReplaceList(SITTERS, [(CONTROLLER = MY_SITTER = llGetPermissionsKey())], SCRIPT_CHANNEL, SCRIPT_CHANNEL);
            // Reset cache and ask [QS]offset to push this sitter's customs.
            MY_CUSTOMS = [];
            llMessageLinked(LINK_THIS, 90261, "", MY_SITTER);
            string channel_or_swap = (string)SCRIPT_CHANNEL;
            integer lnk = 90000; // 90000=play pose
            if (SWAPPED)
            {
                lnk = 90010; // 90010=play pose, ignoring ETYPE
                SWAPPED = FALSE;
            }
            else if (llGetSubString(CURRENT_POSE_NAME, 0, 1) != "P:")
            {
                channel_or_swap = "";
            }
            string posename = CURRENT_POSE_NAME;
            if (llGetSubString(CURRENT_POSE_NAME, 0, 1) == "P:")
            {
                posename = llGetSubString(CURRENT_POSE_NAME, 2, 99999);
            }
            llMessageLinked(LINK_THIS, 90070, (string)SCRIPT_CHANNEL, MY_SITTER); // 90070=update SITTERS after permissions granted
            llMessageLinked(LINK_THIS, lnk, posename, channel_or_swap);
            if (wrong_primcount && WARN)
            {
                // primcount_error() inlined here:
                llDialog(llGetOwner(), "\nThere aren't enough prims for required SitTargets.\nYou must have one prim for each avatar to sit!", ["OK"], 23658);
            }
            else if (!MTYPE)
            {
                if (has_security)
                {
                    llMessageLinked(LINK_SET, 90006, (string)animation_menu_function, MY_SITTER);
                    // Docs say 90006 is:
                    // "Register touch or sit to [AV]root-security script from [AV]sitA after permissions granted."
                }
                else
                {
                    llMessageLinked(LINK_SET, 90005, (string)animation_menu_function, llDumpList2String([CONTROLLER, MY_SITTER], "|")); // 90005=send menu to user
                }
            }
        }
    }

    // dataserver event removed — [QS]boot.lsl owns notecard parsing now.
}
