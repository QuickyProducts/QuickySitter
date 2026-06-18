/*
 * [QS]faces - Use facial expressions in poses (QuickySitter fork of [AV]faces)
 *
 * Minimally-invasive fork of avstock/Plugins/AVfaces/[AV]faces.lsl (2.2p04).
 * Diff against stock:
 *   - Sitter count via QSALIVE (90096/90097) instead of inventory-walk on
 *     "[AV]sitA " + i. Stock fails to detect multi-sitter QS furniture
 *     because the script asset is named "[QS]sitA", not "[AV]sitA", so
 *     facial expressions only ever fire for slot 0.
 *   - get_number_of_scripts() now returns qs_sitter_count_cached
 *     (default 7 until first QSALIVE reply lands, then the real count).
 *
 * Everything else is byte-identical to upstream. Stock hasn't shipped a
 * change since 2016, so the rebase risk is negligible.
 *
 * Original [AV]faces license preserved below — fork inherits MPL 2.0.
 *
 * [AV]faces - Use facial expressions in poses
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Copyright © the AVsitter Contributors (http://avsitter.github.io)
 * AVsitter™ is a trademark. For trademark use policy see:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

integer is_running = TRUE;
list facial_anim_list =
    [ "express_afraid_emote"
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

integer IsInteger(string data)
{
    // This should allow for leading zeros, hence the "1"
    return data != "" && (string)((integer)("1" + data)) == "1" + data;
}

string version = "1.02";
string notecard_name = "AVpos";
// [QS] fork: QSALIVE handshake replaces the stock `string main_script = "[AV]sitA"`
// + inventory-walk. See qs/PROTOCOL.md § QSALIVE.
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;
integer qs_alive = FALSE;
integer qs_sitter_count_cached = 1;

// Presence is published to the qs:alive:faces LSD flag (written early in
// state_entry, re-written on QS_ALIVE_CENSUS). sitB's [FACES] gate and
// adjuster's [FACE] picker read it on-demand when building menus — no
// HELLO broadcast, no cached flag. See qs/PROTOCOL.md § qs:alive.
integer QS_ALIVE_CENSUS = 90079;

// QSDUMP — announce DUMP capability so [QS]boot's plugin-cascade
// (cmd_dump in adjuster → 90020/90021 round-trips via boot) doesn't
// need to hardcode "[AV]faces" in dump_plugins. Mirrors [QS]prop's
// pattern. See qs/PROTOCOL.md § QSDUMP.
integer QSDUMP_PROBE = 90094;
integer QSDUMP_HELLO = 90095;
key key_request;
key notecard_key;
key notecard_query;
integer notecard_line;
integer notecard_section;
integer listen_handle;
list anim_triggers;
list anim_animsequences;
list running_uuid;
list running_sequence_indexes;
list running_pointers;
list SITTERS = [key_request]; //OSS::list SITTERS; // Force error in LSO
list SITTER_POSES;

// [QS] fork: was a stock inventory-walk on `main_script + " " + i`.
// Default 7 (Quicky's per-furniture hard cap) so SITTERS is sized for
// every possible slot during the brief boot window before the first
// 90097 reply lands. The reply re-runs init_sitters() if the cached
// count disagrees.
integer get_number_of_scripts()
{
    if (qs_alive) return qs_sitter_count_cached;
    return 7;
}

// Verbose convention: 0=error/warn floor (default), 1=boot banner,
// 2=runtime status, 3=debug. OutForce() bypasses for critical messages.
// Set globally via AVpos `VERBOSE n` → qs:cfg:verbose LSD key (read in
// state_entry below).
integer verbose = 0;

Out(integer level, string out)
{
    if (verbose >= level)
    {
        llOwnerSay(llGetScriptName() + "[" + version + "] " + out);
    }
}
OutForce(string out)
{
    llOwnerSay(llGetScriptName() + "[" + version + "] " + out);
}

Readout_Say(string say, string SCRIPT_CHANNEL)
{
    llSleep(0.2);
    llMessageLinked(LINK_THIS, 90022, say, SCRIPT_CHANNEL);
}

string Key2Number(key objKey)
{
    return llGetSubString((string)llAbs((integer)("0x" + llGetSubString((string)objKey, -8, -1)) & 0x3FFFFFFF ^ 0xBFFFFFFF), 6, 99999);
}

init_sitters()
{
    SITTERS = [];
    SITTER_POSES = [];
    integer i;
    for (i = 0; i < get_number_of_scripts(); i++)
    {
        SITTERS += NULL_KEY;
        SITTER_POSES += "";
    }
}

string element(string text, integer x)
{
    return llList2String(llParseStringKeepNulls(text, ["|"], []), x);
}

start_sequence(integer sequence_index, key av)
{
    integer wasRunning = llListFindList(running_sequence_indexes, [sequence_index]);
    if (~wasRunning)
    {
        if (llList2Key(running_uuid, wasRunning) == av)
        {
            running_uuid = llDeleteSubList(running_uuid, wasRunning, wasRunning);
            running_sequence_indexes = llDeleteSubList(running_sequence_indexes, wasRunning, wasRunning);
            running_pointers = llDeleteSubList(running_pointers, wasRunning, wasRunning);
        }
    }
    running_uuid += av;
    running_sequence_indexes += sequence_index;
    running_pointers += 0;
    llSetTimerEvent(0.01);
}

sequence()
{
    list anims;
    list uuids;
    integer i;
    while (i < llGetListLength(running_pointers))
    {
        integer sequence_pointer = llList2Integer(running_pointers, i);
        integer sequence_index = llList2Integer(running_sequence_indexes, i);
        list sequence = llParseStringKeepNulls(llList2String(anim_animsequences, sequence_index), ["|"], []);
        list sequence_anims = llList2ListStrided(sequence, 0, -1, 2);
        list sequence_durations = llList2ListStrided(llDeleteSubList(sequence, 0, 0), 0, -1, 2);
        integer sequence_length;
        integer j;
        while (j <= llGetListLength(sequence_durations))
        {
            integer lastDuration = (integer)llList2String(sequence_durations, j - 1);
            integer repeats = FALSE;
            if (lastDuration < 0)
            {
                repeats = TRUE;
                lastDuration = llAbs(lastDuration);
            }
            string anim;
            if (sequence_pointer == sequence_length)
            {
                anim = llStringTrim(llList2String(sequence_anims, j), STRING_TRIM);
            }
            else if (repeats && sequence_pointer > sequence_length - lastDuration && sequence_pointer < sequence_length - 1)
            {
                anim = llStringTrim(llList2String(sequence_anims, j - 1), STRING_TRIM);
            }
            if (anim != "")
            {
                if (IsInteger(anim))
                {
                    anim = llList2String(facial_anim_list, (integer)anim);
                }
                anims += anim;
                uuids += llList2Key(running_uuid, i);
            }
            if (llList2String(sequence_durations, j) == "-")
            {
                sequence_pointer++;
                jump go;
            }
            integer duration = llAbs((integer)llList2String(sequence_durations, j));
            sequence_length += duration;
            j++;
        }
        sequence_pointer++;
        if (sequence_pointer == sequence_length)
        {
            sequence_pointer = 0;
        }
        @go;
        running_pointers = llListReplaceList(running_pointers, [sequence_pointer], i, i);
        i++;
    }
    for (i = 0; i < llGetListLength(anims); i++)
    {
        if (llList2String(anims, i) != "none")
        {
            if (is_running)
            {
                llMessageLinked(LINK_THIS, 90001, llList2String(anims, i), llList2Key(uuids, i));
            }
        }
    }
}

remove_sequences(key id)
{
    integer index;
    while (~(index = llListFindList(running_uuid, [id])))
    {
        running_uuid = llDeleteSubList(running_uuid, index, index);
        list sequence = llParseStringKeepNulls(llList2String(anim_animsequences, llList2Integer(running_sequence_indexes, index)), ["|"], []);
        running_sequence_indexes = llDeleteSubList(running_sequence_indexes, index, index);
        running_pointers = llDeleteSubList(running_pointers, index, index);
        while (sequence != [])
        {
            if ((!IsInteger(llList2String(sequence, 0))) && llList2String(sequence, 0) != "none")
            {
                llMessageLinked(LINK_THIS, 90002, llList2String(sequence, 0), id);
            }
            sequence = llDeleteSubList(sequence, 0, 1);
        }
    }
    if (llGetListLength(running_uuid) == 0)
    {
        llSetTimerEvent(0);
    }
}

default
{
    state_entry()
    {
        // [QS] fork: probe QSALIVE first so the reply can re-init SITTERS
        // with the actual sitter count asynchronously. init_sitters() runs
        // against the default (7) immediately so the script is usable
        // before the reply lands.
        qs_alive = FALSE;
        // Pick up the boot-written verbose level before any Out() call.
        string v = llLinksetDataRead("qs:cfg:verbose");
        if (v != "") verbose = (integer)v;
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
        // Publish presence to LSD, read on-demand by sitB's [FACES] gate
        // and adjuster's [FACE] picker. Written here before the notecard
        // load so the flag is up long before any menu read; boot's CENSUS
        // re-triggers it on a plugin add/remove.
        llLinksetDataWrite("qs:alive:faces", "1");
        // Announce DUMP capability so boot's cascade doesn't need to
        // hardcode "[AV]faces" — see qs/PROTOCOL.md § QSDUMP.
        llMessageLinked(LINK_SET, QSDUMP_HELLO, "", llGetScriptName());
        init_sitters();
        notecard_key = llGetInventoryKey(notecard_name);
        if (llGetInventoryType(notecard_name) == INVENTORY_NOTECARD)
        {
            Out(2, "Loading...");
            notecard_query = llGetNotecardLine(notecard_name, 0);
        }
    }

    timer()
    {
        sequence();
        llSetTimerEvent(1);
    }

    on_rez(integer start)
    {
        is_running = TRUE;
        // cancel all sequences as there can't be anyone sitting
        while (running_uuid != [])
            remove_sequences(llList2Key(running_uuid, 0));
        // Re-announce DUMP capability — boot may have reset on rez too
        // and lost its dump_plugins cache.
        llMessageLinked(LINK_SET, QSDUMP_HELLO, "", llGetScriptName());
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        list data;
        integer i;
        integer sitter;
        integer x;
        if (num == QSDUMP_PROBE)
        {
            // Boot is asking who's DUMP-capable. Re-announce.
            llMessageLinked(LINK_SET, QSDUMP_HELLO, "", llGetScriptName());
            return;
        }
        if (num == QS_ALIVE_CENSUS)
        {
            // boot wiped presence on a plugin add/remove — re-publish ours.
            llLinksetDataWrite("qs:alive:faces", "1");
            return;
        }
        // [QS] fork: QSALIVE reply from [QS]sitA slot 0. Cache the sitter
        // count and mark sitA present; re-init SITTERS if the count differs
        // from the boot default. See qs/PROTOCOL.md § QSALIVE.
        if (num == QSALIVE_REPLY)
        {
            list d = llParseString2List(msg, ["|"], []);
            if (llList2String(d, 0) == "QuickySitter")
            {
                qs_alive = TRUE;
                qs_sitter_count_cached = (integer)llList2String(d, 2);
                if (qs_sitter_count_cached != llGetListLength(SITTERS))
                {
                    init_sitters();
                }
            }
            return;
        }
        if (num == 90100)
        {
            data = llParseString2List(msg, ["|"], []);
            if (llList2String(data, 1) == "[FACES]")
            {
                llMessageLinked(sender, 90101, llDumpList2String([llList2String(data, 0), "[ADJUST]", id], "|"), llList2String(data, 2));
                if (id == llGetOwner())
                {
                    is_running = !is_running;
                    if (sender == llGetLinkNumber())
                    {
                        llRegionSayTo(id, 0, "Facial Expressions " + llList2String(["OFF", "ON"], is_running));
                    }
                }
                else
                {
                    llRegionSayTo(id, 0, "Sorry, only the owner can change this.");
                }
            }
            return;
        }
        if (sender == llGetLinkNumber())
        {
            if (num == 90045)
            {
                data = llParseStringKeepNulls(msg, ["|"], []);
                sitter = (integer)llList2String(data, 0);
                if (id == llList2Key(SITTERS, sitter))
                {
                    string given_posename = llList2String(data, 1);
                    SITTER_POSES = llListReplaceList(SITTER_POSES, [given_posename], sitter, sitter);
                    given_posename = (string)sitter + "|" + given_posename;
                    remove_sequences(id);
                    while (i < llGetListLength(anim_triggers))
                    {
                        if (llList2String(anim_triggers, i) == given_posename)
                        {
                            x = llListFindList(anim_triggers, [(string)sitter + "|" + llList2String(anim_animsequences, i)]);
                            if (x == -1)
                            {
                                x = i;
                            }
                            start_sequence(x, id);
                        }
                        i++;
                    }
                }
                return;
            }
            if (num == 90065)
            {
                remove_sequences(id);
                i = llListFindList(SITTERS, [id]);
                if (i != -1)
                {
                    SITTERS = llListReplaceList(SITTERS, [NULL_KEY], i, i);
                }
                return;
            }
            if (num == 90030)
            {
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)msg, (integer)msg);
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)((string)id), (integer)((string)id));
                return;
            }
            if (num == 90070)
            {
                SITTERS = llListReplaceList(SITTERS, [id], (integer)msg, (integer)msg);
                return;
            }
            if (num == 90172)
            {
                is_running = TRUE;
                sitter = (integer)msg;
                remove_sequences(llList2Key(SITTERS, sitter));
                i = llGetListLength(anim_triggers);
                while (i > 0)
                {
                    i--;
                    if (llList2String(anim_triggers, i) == msg + "|" + llList2String(SITTER_POSES, sitter))
                    {
                        anim_triggers = llDeleteSubList(anim_triggers, i, i);
                        anim_animsequences = llDeleteSubList(anim_animsequences, i, i);
                    }
                }
                if (id != "none")
                {
                    anim_triggers += [msg + "|" + llList2String(SITTER_POSES, sitter)];

                    msg = (string)id + "|1";
                    // Reuse existing entries to save data memory when possible
                    i = llListFindList(anim_animsequences, [msg]);
                    if (~i)
                        msg = llList2String(anim_animsequences, i);
                    anim_animsequences += msg;

                    start_sequence(llGetListLength(anim_animsequences) - 1, llList2Key(SITTERS, sitter));
                    llSay(0, "FACE added: '" + (string)id + "' to '" + llList2String(SITTER_POSES, sitter) + "' for SITTER " + (string)sitter + ".");
                }
                return;
            }
            if (num == 90020 && (string)id == llGetScriptName())
            {
                for (i = 0; i < llGetListLength(anim_triggers); i++)
                {
                    if (llSubStringIndex(llList2String(anim_triggers, i), msg + "|") == 0)
                    {
                        data = llParseString2List(llList2String(anim_triggers, i), ["|"], []);
                        list sequence = llParseString2List(llList2String(anim_animsequences, i), ["|"], []);
                        for (x = 0; x < llGetListLength(sequence); x += 2)
                        {
                            if (IsInteger(llList2String(sequence, x)))
                            {
                                sequence = llListReplaceList(sequence, [llList2String(facial_anim_list, llList2Integer(sequence, x))], x, x);
                            }
                        }
                        Readout_Say("ANIM " + llList2String(data, 1) + "|" + llDumpList2String(sequence, "|"), msg);
                    }
                }
                llMessageLinked(LINK_THIS, 90021, msg, llGetScriptName());
                return;
            }
        }
    }

    changed(integer change)
    {
        if (change & CHANGED_INVENTORY)
        {
            if (llGetInventoryKey(notecard_name) != notecard_key)
            {
                llResetScript(); // llResetScript() never returns
            }
            // [QS] fork: re-probe QSALIVE — sitA may have been added /
            // removed / its slot count changed. Reply re-inits SITTERS
            // if the cached count disagrees.
            qs_alive = FALSE;
            llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
            if (get_number_of_scripts() != llGetListLength(SITTERS))
            {
                init_sitters();
            }
        }
        /*
        // If you uncomment this, don't make this an 'else if', as
        // changed events may come several at a time.
        if (change & CHANGED_LINK)
        {
            if (llGetAgentSize(llGetLinkKey(llGetNumberOfPrims())) == ZERO_VECTOR)
            {
            }
        }
        */
    }

    dataserver(key query_id, string data)
    {
        if (query_id == notecard_query)
        {
            if (data == EOF)
            {
                Out(1, (string)llGetListLength(anim_triggers) + " Expressions Ready, Mem=" + (string)llGetFreeMemory());
            }
            else
            {
                data = llGetSubString(data, llSubStringIndex(data, "◆") + 1, 99999);
                data = llStringTrim(data, STRING_TRIM);
                string command = llGetSubString(data, 0, llSubStringIndex(data, " ") - 1);
                list parts = llParseStringKeepNulls(llGetSubString(data, llSubStringIndex(data, " ") + 1, 99999), [" | ", " |", "| ", "|"], []);
                if (command == "SITTER")
                {
                    notecard_section = llList2Integer(parts, 0);
                }
                if (command == "ANIM")
                {
                    string part1 = llStringTrim(llDumpList2String(llDeleteSubList(parts, 0, 0), "|"), STRING_TRIM);
                    list sequence = llParseString2List(part1, ["|"], []);
                    integer x;
                    for (; x < llGetListLength(sequence); x += 2)
                    {
                        integer index = llListFindList(facial_anim_list, [llList2String(sequence, x)]);
                        if (~index)
                        {
                            // Reuse the string in facial_anim_list to save memory
                            sequence = llListReplaceList(sequence,
                                llList2List(facial_anim_list, index, index), // OSS::[index],
                                x, x);
                        }
                    }
                    anim_triggers += [(string)notecard_section + "|" + llStringTrim(llList2String(parts, 0), STRING_TRIM)];
                    part1 = llDumpList2String(sequence, "|");
                    // Reuse existing entries to save data memory when possible
                    x = llListFindList(anim_animsequences, [part1]);
                    if (~x)
                        part1 = llList2String(anim_animsequences, x);
                    anim_animsequences += part1;
                }
                notecard_query = llGetNotecardLine(notecard_name, ++notecard_line);
            }
        }
    }
}
