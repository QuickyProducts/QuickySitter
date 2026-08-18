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
 *   - QSFACE_PICK (90214, since 1.251): the facial-anim picker dialog
 *     moved here from [QS]adjuster (this plugin owns list, dialog and
 *     storage; the adjuster no longer pays bytecode for an optional
 *     feature). The stock 90172 wire stays as the store contract.
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

string version = "1.28";
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

// QSFACE_PICK: [QS]adjuster hands the facial-anim picker over to us
// (1.251; the dialog used to live adjuster-side). msg =
// "<slot>|<controller>|<sitterAv>", id = "". We render the paginated
// picker to <controller>, store the pick via store_face() and reopen
// the pose menu via 90005 with "<controller>|<sitterAv>". Stock
// [AV]faces authoring is deliberately unsupported (that compat was
// dropped with the qs:alive migration). See qs/PROTOCOL.md.
//
// Prim-local wire, like the 90172 store it replaced: the adjuster sends
// LINK_THIS from our own prim (>= 1.2558) and the handler refuses any
// other sender (1.2511). Both halves matter, because <slot> indexes OUR
// SITTERS list: a linkset-wide broadcast would have every faces instance
// open a picker and store against a different seat.
integer QSFACE_PICK = 90214;
integer face_chan;
integer face_page;
integer face_sitter;
key     face_controller;
key     face_return;      // seated avatar, tail of the 90005 reopen route
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
// 2=runtime status, 3=debug. Set globally via AVpos `VERBOSE n` →
// qs:cfg:verbose LSD key (read in state_entry below). No OutForce
// here: faces has no never-suppress messages (dropped as dead code in
// 1.251, same rationale as adjuster 1.2551 / sitB).
integer verbose = 0;

Out(integer level, string out)
{
    if (verbose >= level)
    {
        llOwnerSay(llGetScriptName() + "[" + version + "] " + out);
    }
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

// Store (or clear, anim == "none") a facial anim for <sitter>'s current
// pose. Extracted from the 90172 handler (1.251) so the QSFACE_PICK
// picker below can share it: LSL never delivers a script's own
// llMessageLinked back to itself, so the picker must call this directly
// instead of sending 90172. The 90172 wire itself stays untouched as
// the stock store contract.
store_face(integer sitter, string anim)
{
    is_running = TRUE;
    remove_sequences(llList2Key(SITTERS, sitter));
    string trigger = (string)sitter + "|" + llList2String(SITTER_POSES, sitter);
    integer i = llGetListLength(anim_triggers);
    while (i > 0)
    {
        i--;
        if (llList2String(anim_triggers, i) == trigger)
        {
            anim_triggers = llDeleteSubList(anim_triggers, i, i);
            anim_animsequences = llDeleteSubList(anim_animsequences, i, i);
        }
    }
    if (anim != "none")
    {
        anim_triggers += [trigger];
        string seq = anim + "|1";
        // Reuse existing entries to save data memory when possible
        i = llListFindList(anim_animsequences, [seq]);
        if (~i)
            seq = llList2String(anim_animsequences, i);
        anim_animsequences += seq;
        start_sequence(llGetListLength(anim_animsequences) - 1, llList2Key(SITTERS, sitter));
        llSay(0, "FACE added: '" + anim + "' to '" + llList2String(SITTER_POSES, sitter) + "' for SITTER " + (string)sitter + ".");
    }
}

// QSFACE_PICK picker (1.251, moved here from [QS]adjuster's choice_menu).
// "none" + the 19 stock expressions, 9 per page with numeric buttons,
// mirroring the adjuster's old pagination UX. One picker at a time: a
// new 90214 re-arms the single listener, an abandoned dialog window
// stays on screen but its listen is dead (LSL cannot close dialogs).
open_face_picker()
{
    list opts = ["none"] + facial_anim_list;
    integer total = llGetListLength(opts);
    integer pages = (total + 8) / 9;
    if (face_page < 0) face_page = pages - 1;
    if (face_page >= pages) face_page = 0;
    integer start = face_page * 9;
    string text = "\nChoose your facial anim (" + (string)(face_page + 1)
        + "/" + (string)pages + "):\n";
    list buttons;
    integer i = start;
    while (i < start + 9 && i < total)
    {
        text += "\n" + (string)(i - start + 1) + ". " + llList2String(opts, i);
        buttons += (string)(i - start + 1);
        ++i;
    }
    buttons += ["[<<]", "[>>]", "[CANCEL]"];
    llListenRemove(listen_handle);
    face_chan = ((integer)llFrand(0x7FFFFF80) + 1) * -1;
    listen_handle = llListen(face_chan, "", face_controller, "");
    llDialog(face_controller, text, buttons, face_chan);
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

    listen(integer chan, string name, key id, string msg)
    {
        // QSFACE_PICK picker responses only (the sole listener in this
        // script). Paging re-renders; a numeric pick stores and returns
        // to the pose menu; [CANCEL] just returns.
        if (chan != face_chan) return;
        if (msg == "[<<]") { --face_page; open_face_picker(); return; }
        if (msg == "[>>]") { ++face_page; open_face_picker(); return; }
        llListenRemove(listen_handle);
        integer pick = (integer)msg;
        if ((string)pick == msg && pick >= 1 && pick <= 9)
        {
            list opts = ["none"] + facial_anim_list;
            integer idx = face_page * 9 + pick - 1;
            if (idx < llGetListLength(opts))
                store_face(face_sitter, llList2String(opts, idx));
        }
        // Reopen the pose menu either way, mirroring the adjuster's old
        // post-pick behavior ([CANCEL] included: the user came from a
        // menu and should land back in one).
        llMessageLinked(LINK_THIS, 90005, "",
            llDumpList2String([face_controller, face_return], "|"));
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
        if (num == QSFACE_PICK)
        {
            // [QS]adjuster hands over the [FACE] picker. See the
            // QSFACE_PICK declaration for the payload contract and for why
            // this wire is prim-local. Our own prim only: the slot in the
            // payload indexes OUR SITTERS list, so a sender from another
            // prim would have us pick and store for the wrong seat. Sits
            // here rather than under the shared sender guard below because
            // this handler returns early like the other typed wires above.
            if (sender != llGetLinkNumber()) return;
            data = llParseString2List(msg, ["|"], []);
            face_sitter     = (integer)llList2String(data, 0);
            face_controller = (key)llList2String(data, 1);
            face_return     = (key)llList2String(data, 2);
            face_page       = 0;
            open_face_picker();
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
                // Body extracted to store_face() in 1.251 (shared with
                // the QSFACE_PICK picker); wire semantics unchanged.
                store_face((integer)msg, (string)id);
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
