/*
 * [QS]prop - Rez props when playing poses (QuickySitter fork of [AV]prop)
 *
 * Minimally-invasive fork of avstock/Plugins/AVprop/[AV]prop.lsl (2.2p04).
 * Diff against stock:
 *   1. Sitter presence via QSALIVE (90096/90097), NOT script-name probes.
 *   2. Parallel list prop_post_rez_say for QSPROP_ATTACH post-rez forwarding.
 *   3. comm_channel REZ branch emits prop_post_rez_say after ATTACHTO.
 *   4. New link_message 90280 (QSPROP_ATTACH) for dynamic prop registration.
 *   5. LAZY-LOAD STORAGE (0.018+): the parsed prop database lives entirely
 *      in linkset_data, not in script-globals. All prop_*[i] list accesses
 *      become qs:prop:<i> LSD reads, all llListFindList searches become
 *      qs:prop:trig:<trigger> index reads. Saves ~5–6 KB persistent heap
 *      and turns subsequent restarts into sub-second boots (the LSD record
 *      survives state_entry; we only re-parse the notecard when its inv key
 *      changes). External interface (link-messages, region-says, llRezAtRoot
 *      payload format) is byte-identical to stock + items 1–4 above.
 *   6. PROP SCALE + WORN FIT (1.25+): optional AVpos fields 7-9
 *      `PROP …|<point>|<scale>|<wornpos>|<wornrot>` + comm-channel commands
 *      QSSCALE/QSWORN (apply on rez) / QSSAVESCALE/QSSAVEWORN (persist on
 *      [SAVE]), handled by the [QS]propadjust companion script inside the
 *      prop. The companion is NOT part of this repo — it ships with the
 *      commercial QuickyHUD bundle. Props without the companion, and stock
 *      [AV]prop receiving the QSSAVE* replies, ignore the extension
 *      entirely. See qs/PROTOCOL.md § Prop scale for the open wire spec.
 *
 * LSD layout under "qs:prop:*":
 *   qs:prop:meta        = "<notecard_key>\t<count>\t<warn>\t<groups_nl>"
 *                         (groups_nl is "\n"-joined sequential_prop_groups)
 *   qs:prop:<i>         = "<trig>\t<type>\t<obj>\t<grp>\t<pos>\t<rot>\t<pt>\t<prs>\t<scl>\t<wpos>\t<wrot>"
 *                         (11 fields; prs = post_rez_say payload, scl =
 *                         uniform scale factor vs inventory size ("" ≡ "1"),
 *                         wpos/wrot = worn fit: local pos + Euler-deg rot
 *                         vs attach point, "" = unset. Rows written by
 *                         older versions have 8/9 fields and stay
 *                         readable — missing trailing fields read "".)
 *   qs:prop:trig:<trig> = "i0,i1,…"  (indices matching this trigger)
 *   qs:prop:sit:<sit>   = "i0,i1,…"  (indices belonging to this sitter)
 *   qs:prop:grp:<grp>   = "i0,i1,…"  (indices belonging to this group)
 *
 * Cleanup: changed(CHANGED_INVENTORY) on AVpos key mismatch triggers
 * llLinksetDataDeleteFound("^qs:prop:.*", "") which wipes the entire
 * namespace in one call, then llResetScript repopulates from notecard.
 *
 * Original [AV]prop license preserved below — fork inherits MPL 2.0.
 *
 * [AV]prop - Rez props when playing poses
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Copyright © the AVsitter Contributors (http://avsitter.github.io)
 * AVsitter™ is a trademark. For trademark use policy see:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "1.25";
string notecard_name = "AVpos";
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;
// QSDUMP — announce DUMP capability to [QS]boot. See qs/PROTOCOL.md.
integer QSDUMP_PROBE = 90094;
integer QSDUMP_HELLO = 90095;
// Presence is published to the qs:alive:prop LSD flag (written in
// state_entry / on_rez, re-written on QS_ALIVE_CENSUS). adjuster's [PROP]
// gate and boot's self-check read it on-demand — no HELLO broadcast.
// See qs/PROTOCOL.md § qs:alive.
integer QS_ALIVE_CENSUS = 90079;
integer qs_alive = FALSE;
integer qs_sitter_count_cached = 1;
key key_request;
integer comm_channel;
integer WARN = 1;
key notecard_key;
key notecard_query;
integer notecard_line;
integer notecard_section;
integer listen_handle;

// [QS] 0.018: prop database lives in LSD now. prop_count_cached mirrors
// the count for fast index-bound checks without an extra meta read.
// sequential_prop_groups is kept in memory because it's small (~150 B
// for typical notecards) and remove_props_by_group(integer gp) takes
// the gp as a list index — LSD-resident here would force a parse per
// call.
integer prop_count_cached;
list sequential_prop_groups;

integer HAVENTNAGGED = TRUE;
list SITTERS = [key_request]; //OSS::list SITTERS;
list SITTER_POSES;
list ATTACH_POINTS =
    [ ATTACH_CHEST,             "chest"
    , ATTACH_HEAD,              "head"
    , ATTACH_LSHOULDER,         "left shoulder"
    , ATTACH_RSHOULDER,         "right shoulder"
    , ATTACH_LHAND,             "left hand"
    , ATTACH_RHAND,             "right hand"
    , ATTACH_LFOOT,             "left foot"
    , ATTACH_RFOOT,             "right foot"
    , ATTACH_BACK,              "back"
    , ATTACH_PELVIS,            "pelvis"
    , ATTACH_MOUTH,             "mouth"
    , ATTACH_CHIN,              "chin"
    , ATTACH_LEAR,              "left ear"
    , ATTACH_REAR,              "right ear"
    , ATTACH_LEYE,              "left eye"
    , ATTACH_REYE,              "right eye"
    , ATTACH_NOSE,              "nose"
    , ATTACH_RUARM,             "right upper arm"
    , ATTACH_RLARM,             "right lower arm"
    , ATTACH_LUARM,             "left upper arm"
    , ATTACH_LLARM,             "left lower arm"
    , ATTACH_RHIP,              "right hip"
    , ATTACH_RULEG,             "right upper leg"
    , ATTACH_RLLEG,             "right lower leg"
    , ATTACH_LHIP,              "left hip"
    , ATTACH_LULEG,             "left upper leg"
    , ATTACH_LLLEG,             "left lower leg"
    , ATTACH_BELLY,             "stomach"
    , ATTACH_LEFT_PEC,          "left pectoral"
    , ATTACH_RIGHT_PEC,         "right pectoral"
    , ATTACH_HUD_CENTER_2,      "HUD center 2"
    , ATTACH_HUD_TOP_RIGHT,     "HUD top right"
    , ATTACH_HUD_TOP_CENTER,    "HUD top"
    , ATTACH_HUD_TOP_LEFT,      "HUD top left"
    , ATTACH_HUD_CENTER_1,      "HUD center"
    , ATTACH_HUD_BOTTOM_LEFT,   "HUD bottom left"
    , ATTACH_HUD_BOTTOM,        "HUD bottom"
    , ATTACH_HUD_BOTTOM_RIGHT,  "HUD bottom right"
    , ATTACH_NECK,              "neck"
    , ATTACH_AVATAR_CENTER,     "avatar center"
    ];

// Verbose convention: 0=error/warn floor (default), 1=boot banner,
// 2=runtime status, 3=debug. OutForce() bypasses for critical messages.
// Set globally via AVpos `VERBOSE n` → qs:cfg:verbose LSD key (read in
// state_entry below). Default lowered from stock's 5 to 0 — see
// [[feedback_ownersay_region_spam]]: prop instances on furniture-heavy
// regions multiply every Out() by N.
integer verbose = 0;

// LSD key prefixes — all under "qs:prop:" so prop_clear_all() can wipe
// the whole namespace with a single llLinksetDataDeleteFound.
string LSD_META     = "qs:prop:meta";
string LSD_PROP_PFX = "qs:prop:";
string LSD_TRIG_PFX = "qs:prop:trig:";
string LSD_SIT_PFX  = "qs:prop:sit:";
string LSD_GRP_PFX  = "qs:prop:grp:";

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

integer get_number_of_scripts()
{
    if (qs_alive) return qs_sitter_count_cached;
    return 7;
}

integer get_point(string text)
{
    integer i;
    for (i = 1; i < llGetListLength(ATTACH_POINTS); i = i + 2)
    {
        if (llSubStringIndex(llToUpper(text), llToUpper(llList2String(ATTACH_POINTS, i))) != -1)
        {
            return llList2Integer(ATTACH_POINTS, i - 1);
        }
    }
    return 0;
}

// ───────────────────────────────────────────────────────────────────
// LSD storage layer
// ───────────────────────────────────────────────────────────────────

integer prop_count()
{
    return prop_count_cached;
}

// Append idx to a comma-separated index list under `lsd_key`. Creates the
// entry if missing. (Param is `lsd_key`, not `key` — `key` is an LSL
// type keyword and cannot be used as an identifier.)
prop_index_append(string lsd_key, integer idx)
{
    string existing = llLinksetDataRead(lsd_key);
    if (existing == "")
        llLinksetDataWrite(lsd_key, (string)idx);
    else
        llLinksetDataWrite(lsd_key, existing + "," + (string)idx);
}

// Read an index-list LSD entry and return a list of string indices.
// Returns [] if entry missing. Caller casts to int as needed.
list prop_index_list(string lsd_key)
{
    string val = llLinksetDataRead(lsd_key);
    if (val == "") return [];
    return llParseStringKeepNulls(val, [","], []);
}

// Load a full prop entry by index. Returns 8-element list:
//   [0]=trig, [1]=type, [2]=obj, [3]=grp, [4]=pos, [5]=rot, [6]=pt, [7]=prs
// All fields are strings; cast at use-site.
list prop_load(integer idx)
{
    return llParseStringKeepNulls(
        llLinksetDataRead(LSD_PROP_PFX + (string)idx),
        ["\t"], []);
}

// Return the first index matching `trig`, or -1 if no entry.
// (90280 dynamic-attach uses this for idempotent re-attach.)
integer prop_find_trigger(string trig)
{
    list idx = prop_index_list(LSD_TRIG_PFX + trig);
    if (llGetListLength(idx) == 0) return -1;
    return (integer)llList2String(idx, 0);
}

// Extract the sitter prefix from a trigger string ("<sit>|<pose>").
string prop_trig_sit(string trig)
{
    integer p = llSubStringIndex(trig, "|");
    if (p == -1) return trig;
    return llGetSubString(trig, 0, p - 1);
}

// Append a new prop to the LSD store. Writes the entry + the three
// indices (trig, sit, grp). Returns the assigned index. scl is the
// uniform scale factor as string ("1" = unscaled); wpos/wrot the worn
// fit vectors as strings ("" = unset).
integer prop_add(string trig, integer type, string obj, string grp,
                 vector pos, vector rot, string pt, string prs, string scl,
                 string wpos, string wrot)
{
    integer idx = prop_count_cached;
    llLinksetDataWrite(LSD_PROP_PFX + (string)idx,
        trig + "\t" + (string)type + "\t" + obj + "\t" + grp
        + "\t" + (string)pos + "\t" + (string)rot + "\t" + pt + "\t" + prs
        + "\t" + scl + "\t" + wpos + "\t" + wrot);
    prop_index_append(LSD_TRIG_PFX + trig, idx);
    prop_index_append(LSD_SIT_PFX  + prop_trig_sit(trig), idx);
    prop_index_append(LSD_GRP_PFX  + grp, idx);
    prop_count_cached++;
    return idx;
}

// Update pos and rot of an existing prop (used by SAVEPROP listen).
prop_update_pos_rot(integer idx, vector pos, vector rot)
{
    list entry = prop_load(idx);
    entry = llListReplaceList(entry, [(string)pos], 4, 4);
    entry = llListReplaceList(entry, [(string)rot], 5, 5);
    llLinksetDataWrite(LSD_PROP_PFX + (string)idx, llDumpList2String(entry, "\t"));
}

// Pad a loaded entry to 11 fields so index-writes land correctly on
// rows written by older versions (8 or 9 fields).
list prop_pad(list entry)
{
    while (llGetListLength(entry) < 11)
    {
        entry += "";
    }
    return entry;
}

// Update the scale factor of an existing prop (used by QSSAVESCALE
// listen).
prop_update_scale(integer idx, string scl)
{
    list entry = prop_pad(prop_load(idx));
    entry = llListReplaceList(entry, [scl], 8, 8);
    llLinksetDataWrite(LSD_PROP_PFX + (string)idx, llDumpList2String(entry, "\t"));
}

// Update the worn fit of an existing prop (used by QSSAVEWORN listen).
prop_update_worn(integer idx, string wpos, string wrot)
{
    list entry = prop_pad(prop_load(idx));
    entry = llListReplaceList(entry, [wpos, wrot], 9, 10);
    llLinksetDataWrite(LSD_PROP_PFX + (string)idx, llDumpList2String(entry, "\t"));
}

// Build the optional "|<scale>[|<wpos>|<wrot>]" AVpos-line suffix for a
// loaded entry (SAVEPROP chat line + [DUMP] output). Scale is forced in
// whenever worn fields follow, so the notecard parser's field positions
// (6=scale, 7=wpos, 8=wrot) stay aligned; a bare non-1 scale comes out
// alone; fully unset props return "" (stock line format).
string prop_line_suffix(list entry)
{
    string scl  = llList2String(entry, 8);
    string wpos = llList2String(entry, 9);
    if (wpos != "")
    {
        if (scl == "") scl = "1";
        return "|" + scl + "|" + wpos + "|" + llList2String(entry, 10);
    }
    if (scl != "" && (float)scl != 1.0)
    {
        return "|" + scl;
    }
    return "";
}

// Update point and prs of an existing prop (used by 90280 re-attach).
prop_update_pt_prs(integer idx, string pt, string prs)
{
    list entry = prop_load(idx);
    entry = llListReplaceList(entry, [pt],  6, 6);
    entry = llListReplaceList(entry, [prs], 7, 7);
    llLinksetDataWrite(LSD_PROP_PFX + (string)idx, llDumpList2String(entry, "\t"));
}

// Wipe the entire qs:prop:* LSD namespace. Used on notecard-key change
// and when prop_count gets out of sync. Single LSD call, no key-list
// allocation.
prop_clear_all()
{
    llLinksetDataDeleteFound("^qs:prop:.*", "");
    prop_count_cached = 0;
    sequential_prop_groups = [];
}

// Write the meta record. Called after notecard EOF and whenever
// sequential_prop_groups / WARN change.
prop_write_meta()
{
    llLinksetDataWrite(LSD_META,
        (string)notecard_key + "\t" + (string)prop_count_cached
        + "\t" + (string)WARN
        + "\t" + llDumpList2String(sequential_prop_groups, "\n"));
}

// ───────────────────────────────────────────────────────────────────
// Rez / remove logic (now using LSD-resident store)
// ───────────────────────────────────────────────────────────────────

rez_prop(integer index)
{
    list entry = prop_load(index);
    integer type = (integer)llList2String(entry, 1);
    string object = llList2String(entry, 2);
    if (object != "")
    {
        vector pos = (vector)llList2String(entry, 4) * llGetRot() + llGetPos();
        rotation rot = llEuler2Rot((vector)llList2String(entry, 5) * DEG_TO_RAD) * llGetRot();
        if (llGetInventoryType(object) != INVENTORY_OBJECT)
        {
            llSay(0, "Could not find prop '" + object + "'.");
            return;
        }
        integer perms = llGetInventoryPermMask(object, MASK_NEXT);
        string next = "  for NEXT owner";
        if (WARN > 1)
        {
            next = "";
            perms = -1;
            if (WARN == 2)
                perms = llGetInventoryPermMask(object, MASK_OWNER);
        }
        if (type == 0 || type == 3)
        {
            if (!(perms & PERM_COPY))
            {
                llSay(0, "Can't rez '" + object + ("'. P"+("rops and their content must be COPY-"+("OK" + next))));
                return;
            }
        }
        else if (type > 0)
        {
            if ((!(perms & PERM_COPY)) || (!(perms & PERM_TRANSFER)))
            {
                llSay(0, "Can't rez '" + object + ("'. Attachment p"+("rops and their content must be COPY-"+("TRANSFER" + next))));
                return;
            }
        }
        perms = get_point(llList2String(entry, 6));
        llRezAtRoot(object, pos, ZERO_VECTOR, rot,
            comm_channel * 100000
            -  (index * 1000
                + perms * 10
                + type)
        );
    }
}

send_command(string command)
{
    llRegionSay(comm_channel, command);
    llSay(comm_channel, command);
}

remove_all_props()
{
    send_command("REM_ALL");
}

rez_props_by_trigger(string pose_name)
{
    list idx_strs = prop_index_list(LSD_TRIG_PFX + pose_name);
    integer n = llGetListLength(idx_strs);
    integer i;
    for (i = 0; i < n; i++)
    {
        rez_prop((integer)llList2String(idx_strs, i));
    }
}

list get_props_by_pose(string pose_name)
{
    list idx_strs = prop_index_list(LSD_TRIG_PFX + pose_name);
    integer n = llGetListLength(idx_strs);
    list result;
    integer i;
    for (i = 0; i < n; i++)
    {
        result += (integer)llList2String(idx_strs, i);
    }
    return result;
}

remove_props_by_sitter(string sitter, integer remove_type3)
{
    list idx_strs = prop_index_list(LSD_SIT_PFX + sitter);
    integer n = llGetListLength(idx_strs);
    list text;
    integer i;
    for (i = 0; i < n; i++)
    {
        integer idx = (integer)llList2String(idx_strs, i);
        integer type = (integer)llList2String(prop_load(idx), 1);
        if (type != 3 || remove_type3)
        {
            text += [idx];
        }
    }
    string command = "REM_INDEX";
    if (!qs_alive)
    {
        command = "REM_WORLD";
    }
    if (text != [])
    {
        send_command(llDumpList2String([command] + text, "|"));
    }
}

remove_worn(key av)
{
    send_command(llDumpList2String(["REM_WORN", av], "|"));
}

remove_sitter_props_by_pose(string sitter_pose, integer remove_type3)
{
    list idx_strs = prop_index_list(LSD_TRIG_PFX + sitter_pose);
    integer n = llGetListLength(idx_strs);
    list text;
    integer i;
    for (i = 0; i < n; i++)
    {
        integer idx = (integer)llList2String(idx_strs, i);
        integer type = (integer)llList2String(prop_load(idx), 1);
        if (type != 3 || remove_type3)
        {
            text += [idx];
        }
    }
    if (text != [])
    {
        send_command(llDumpList2String(["REM_INDEX"] + text, "|"));
    }
}

remove_sitter_props_by_pose_group(string msg)
{
    list props = get_props_by_pose(msg);
    list groups;
    integer n = llGetListLength(props);
    integer i;
    for (i = 0; i < n; i++)
    {
        integer idx = llList2Integer(props, i);
        string prop_group = llList2String(prop_load(idx), 3);
        if (llListFindList(groups, [prop_group]) == -1)
        {
            groups += prop_group;
            remove_props_by_group(llListFindList(sequential_prop_groups, [prop_group]));
        }
    }
}

remove_props_by_group(integer gp)
{
    string group = llList2String(sequential_prop_groups, gp);
    list idx_strs = prop_index_list(LSD_GRP_PFX + group);
    integer n = llGetListLength(idx_strs);
    string text = "";
    integer i;
    for (i = 0; i < n; i++)
    {
        text += "|" + llList2String(idx_strs, i);
    }
    if (text != "")
    {
        if (qs_alive)
        {
            send_command("REM_INDEX" + text);
        }
        else
        {
            send_command("REM_WORLD" + text);
            if (llList2Key(SITTERS, 0))
            {
                llRegionSayTo(llList2Key(SITTERS, 0), comm_channel, "REM_INDEX" + text);
            }
        }
    }
}

Readout_Say(string say)
{
    llSleep(0.2);
    llMessageLinked(LINK_THIS, 90022, say, "");
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

init_channel()
{
    llListenRemove(listen_handle);
    comm_channel = ((integer)llFrand(8999) + 1000) * -1;
    listen_handle = llListen(comm_channel, "", "", "");
}

string element(string text, integer x)
{
    return llList2String(llParseStringKeepNulls(text, ["|"], []), x);
}

default
{
    state_entry()
    {
        // Pick up the boot-written verbose level before any Out() call.
        string v = llLinksetDataRead("qs:cfg:verbose");
        if (v != "") verbose = (integer)v;
        Out(1, "Mem=" + (string)(65536 - llGetUsedMemory()));
        qs_alive = FALSE;
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
        // Announce DUMP capability so boot's cascade doesn't need to
        // hardcode "[QS]prop" — see qs/PROTOCOL.md § QSDUMP.
        llMessageLinked(LINK_SET, QSDUMP_HELLO, "", llGetScriptName());
        // Publish presence to LSD, read on-demand by adjuster's [PROP]
        // gate and boot's self-check. See PROTOCOL.md § qs:alive.
        llLinksetDataWrite("qs:alive:prop", "1");
        init_sitters();
        init_channel();
        notecard_key = llGetInventoryKey(notecard_name);

        // [QS] 0.018: check if the LSD store is still current. If the
        // notecard key matches, props are already in LSD — skip the
        // dataserver loop entirely (sub-second boot). If mismatch
        // (notecard edited), wipe and re-read.
        string meta = llLinksetDataRead(LSD_META);
        if (meta != "")
        {
            list mp = llParseStringKeepNulls(meta, ["\t"], []);
            if (llList2String(mp, 0) == (string)notecard_key)
            {
                prop_count_cached = (integer)llList2String(mp, 1);
                WARN = (integer)llList2String(mp, 2);
                string groups = llList2String(mp, 3);
                if (groups != "")
                    sequential_prop_groups = llParseStringKeepNulls(groups, ["\n"], []);
                Out(1, (string)prop_count_cached
                    + " Props Ready (LSD), Mem=" + (string)llGetFreeMemory());
                return;
            }
            // Notecard changed — flush stale LSD before re-parse.
            prop_clear_all();
        }
        if (llGetInventoryType(notecard_name) == INVENTORY_NOTECARD)
        {
            Out(2, "Loading...");
            notecard_query = llGetNotecardLine(notecard_name, 0);
        }
    }

    on_rez(integer start)
    {
        init_channel();
        qs_alive = FALSE;
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
        llMessageLinked(LINK_SET, QSDUMP_HELLO, "", llGetScriptName());
        llLinksetDataWrite("qs:alive:prop", "1");
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QSDUMP_PROBE)
        {
            // Boot is asking who's DUMP-capable. Re-announce.
            llMessageLinked(LINK_SET, QSDUMP_HELLO, "", llGetScriptName());
            return;
        }
        if (num == QS_ALIVE_CENSUS)
        {
            // boot wiped presence on a plugin add/remove — re-publish ours.
            llLinksetDataWrite("qs:alive:prop", "1");
            return;
        }
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

        if (num == 90280)
        {
            list params = llParseStringKeepNulls(msg, ["|"], []);
            if (llGetListLength(params) < 4) return;
            string  obj     = llList2String(params, 0);
            integer type    = (integer)llList2String(params, 1);
            string  point   = llList2String(params, 2);
            integer sitter  = (integer)llList2String(params, 3);
            string  postSay = "";
            if (llGetListLength(params) > 4)
                postSay = llDumpList2String(llList2List(params, 4, -1), "|");
            if (obj == "") return;
            if (sitter < 0 || sitter >= llGetListLength(SITTERS)) return;

            string trig = (string)sitter + "|" + obj;
            integer idx = prop_find_trigger(trig);
            if (idx == -1)
            {
                string grp = (string)sitter + "|QSDYN";
                idx = prop_add(trig, type, obj, grp,
                               <0.0, 0.0, 0.0>, <0.0, 0.0, 0.0>,
                               point, postSay, "1", "", "");
                if (llListFindList(sequential_prop_groups, [grp]) == -1)
                {
                    sequential_prop_groups += grp;
                    prop_write_meta();
                }
            }
            else
            {
                prop_update_pt_prs(idx, point, postSay);
            }
            if (id != NULL_KEY)
                SITTERS = llListReplaceList(SITTERS, [id], sitter, sitter);
            rez_prop(idx);
            return;
        }

        if (sender == llGetLinkNumber())
        {
            if (num == 90045)
            {
                list data = llParseStringKeepNulls(msg, ["|"], []);
                integer sitter = (integer)llList2String(data, 0);
                if (id == llList2Key(SITTERS, sitter))
                {
                    remove_sitter_props_by_pose(llList2String(SITTER_POSES, sitter), FALSE);
                    string given_posename = llList2String(data, 1);
                    given_posename = (string)sitter + "|" + given_posename;
                    SITTER_POSES = llListReplaceList(SITTER_POSES, [given_posename], sitter, sitter);
                    remove_sitter_props_by_pose_group(given_posename);
                    rez_props_by_trigger(given_posename);
                }
                return;
            }
            if (num == 90200 || num == 90220)
            {
                list ids = llParseStringKeepNulls(id, ["|"], []);
                key sitting_av_or_sitter = (key)llList2String(ids, -1);
                if (!qs_alive)
                {
                    SITTERS = [sitting_av_or_sitter];
                }
                integer i;
                if (!llSubStringIndex(msg, "remprop_"))
                {
                    for (; i < llGetListLength(SITTERS); i++)
                    {
                        if (llList2Key(SITTERS, i) == sitting_av_or_sitter || id == "" || (string)sitting_av_or_sitter == (string)i)
                        {
                            remove_sitter_props_by_pose((string)i + "|" + llGetSubString(msg, 8, 99999), TRUE);
                        }
                    }
                }
                else
                {
                    integer flag;
                    for (; i < llGetListLength(SITTERS); i++)
                    {
                        if (prop_find_trigger((string)i + "|" + msg) != -1)
                        {
                            flag = TRUE;
                        }
                    }
                    for (i = 0; i < llGetListLength(SITTERS); i++)
                    {
                        if (llList2Key(SITTERS, i) == sitting_av_or_sitter || id == "" || (string)sitting_av_or_sitter == (string)i)
                        {
                            integer index = prop_find_trigger((string)i + "|" + msg);
                            if (index == -1)
                            {
                                if (!qs_alive)
                                {
                                    remove_all_props();
                                }
                                else if (!flag)
                                {
                                    remove_props_by_sitter((string)i, TRUE);
                                }
                            }
                            else
                            {
                                remove_sitter_props_by_pose_group((string)i + "|" + msg);
                                rez_props_by_trigger((string)i + "|" + msg);
                            }
                        }
                    }
                }
                if (sitting_av_or_sitter)
                {
                    if (num == 90200)
                    {
                        llMessageLinked(LINK_THIS, 90005, "", id);
                    }
                }
                return;
            }
            if (num == 90101)
            {
                list data = llParseString2List(msg, ["|"], []);
                if (llList2String(data, 1) == "[SAVE]")
                {
                    llRegionSay(comm_channel, "PROPSEARCH");
                }
                return;
            }
            if (num == 90065)
            {
                remove_props_by_sitter(msg, FALSE);
                remove_worn(id);
                integer index = llListFindList(SITTERS, [id]);
                if (index != -1)
                {
                    SITTERS = llListReplaceList(SITTERS, [NULL_KEY], index, index);
                }
                return;
            }
            // 90031 (QS_SWAP_QUIET, HUD-initiated swap) carries the same
            // slot payload as stock 90030 and needs the same cleanup.
            // Without it the old worn Quicky-HUD stayed attached until
            // the replacement HUD's LOCAT broadcast evicted it AFTER the
            // new HUD had already captured the (still RLV-zeroed) hover
            // height as its "original" — the post-swap hover-height
            // loss. Removing both slots' props here lets the old HUD
            // detach and restore BEFORE the 90070-driven re-attach rezzes
            // its successor, matching the stock 90030 path's behavior.
            if (num == 90030 || num == 90031)
            {
                remove_props_by_sitter(msg, FALSE);
                remove_props_by_sitter((string)id, FALSE);
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)msg, (integer)msg);
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)((string)id), (integer)((string)id));
                return;
            }
            if (num == 90070)
            {
                SITTERS = llListReplaceList(SITTERS, [id], (integer)msg, (integer)msg);
                return;
            }
            if (num == 90171 || num == 90173)
            {
                integer sitter;
                string trig;
                if (num == 90171)
                {
                    sitter = (integer)msg;
                    trig = llList2String(SITTER_POSES, sitter);
                }
                else
                {
                    sitter = 0;
                    SITTER_POSES = ["0|" + msg];
                    trig = "0|" + msg;
                }
                string prop_group = (string)sitter + "|G1";
                integer new_idx = prop_add(trig, 0, (string)id, prop_group,
                                           <0,0,1>, <0,0,0>, "", "", "1", "", "");
                if (llListFindList(sequential_prop_groups, [prop_group]) == -1)
                {
                    sequential_prop_groups += prop_group;
                }
                prop_write_meta();
                rez_prop(new_idx);
                string text = "PROP added: '" + (string)id + "' to '" + element(llList2String(SITTER_POSES, sitter), 1) + "'";
                if (llGetListLength(SITTERS) > 1)
                {
                    text += " for SITTER " + (string)sitter;
                }
                llSay(0, text);
                llSay(0, "Position your prop and click [SAVE].");
                return;
            }
            if (num == 90020 && (string)id == llGetScriptName())
            {
                // Dump matching props (sitter prefix) — iterate all
                // indices since there's no direct sitter-pose index.
                // Rare admin path; the O(count) LSD reads are fine.
                integer count = prop_count_cached;
                integer i;
                for (i = 0; i < count; i++)
                {
                    list entry = prop_load(i);
                    string trig = llList2String(entry, 0);
                    if (llSubStringIndex(trig, msg + "|") == 0)
                    {
                        string type = (string)llList2Integer(entry, 1);
                        if (type == "0")
                        {
                            type = "";
                        }
                        string dump_line = "PROP" + type + " " + llDumpList2String([
                            element(trig, 1),
                            llList2String(entry, 2),
                            element(llList2String(entry, 3), 1),
                            llList2String(entry, 4),
                            llList2String(entry, 5),
                            llList2String(entry, 6)
                        ], "|") + prop_line_suffix(entry);
                        Readout_Say(dump_line);
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
                remove_all_props();
                prop_clear_all();
                llResetScript();
            }
            else
            {
                qs_alive = FALSE;
                llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
                if (get_number_of_scripts() != llGetListLength(SITTERS))
                {
                    init_sitters();
                }
            }
        }
        if (change & CHANGED_LINK)
        {
            if (llGetAgentSize(llGetLinkKey(llGetNumberOfPrims())) == ZERO_VECTOR)
            {
                HAVENTNAGGED = TRUE;
                if (qs_alive)
                {
                    remove_all_props();
                }
            }
        }
    }

    listen(integer channel, string name, key id, string message)
    {
        list data = llParseStringKeepNulls(message, ["|"], []);
        if (llList2String(data, 0) == "SAVEPROP")
        {
            integer index = (integer)llList2String(data, 1);
            if (index >= 0 && index < prop_count_cached)
            {
                if (llList2Vector(llGetObjectDetails(id, [OBJECT_POS]), 0) != ZERO_VECTOR)
                {
                    list details = [OBJECT_POS, OBJECT_ROT];
                    rotation f = llList2Rot((details = llGetObjectDetails(llGetKey(), details) + llGetObjectDetails(id, details)), 1);
                    vector target_rot = llRot2Euler(llList2Rot(details, 3) / f) * RAD_TO_DEG;
                    vector target_pos = (llList2Vector(details, 2) - llList2Vector(details, 0)) / f;
                    prop_update_pos_rot(index, target_pos, target_rot);
                    list entry = prop_load(index);
                    string type = (string)llList2Integer(entry, 1);
                    if (type == "0")
                    {
                        type = "";
                    }
                    string trig = llList2String(entry, 0);
                    string grp  = llList2String(entry, 3);
                    string text = "PROP Saved to memory, SITTER " + element(trig, 0) + ": PROP" + type + " " + element(trig, 1) + "|" + name + "|" + element(grp, 1) + "|" + (string)target_pos + "|" + (string)target_rot + "|" + llList2String(entry, 6) + prop_line_suffix(entry);
                    llSay(0, text);
                }
            }
            else
            {
                Out(0, "ERROR: cannot find prop: " + name);
            }
            return;
        }
        if (llList2String(data, 0) == "QSSAVESCALE")
        {
            // [QS]propadjust replying to the [SAVE]-triggered PROPSEARCH
            // broadcast with its current scale factor (vs inventory size).
            integer index = (integer)llList2String(data, 1);
            if (index >= 0 && index < prop_count_cached)
            {
                float f = (float)llList2String(data, 2);
                if (f > 0.0)
                {
                    // Snap near-1 to exactly 1 so untouched props keep
                    // stock-format notecard lines.
                    if (f > 0.995 && f < 1.005) f = 1.0;
                    string scl = "1";
                    if (f != 1.0) scl = (string)f;
                    string prev = llList2String(prop_load(index), 8);
                    if (prev == "") prev = "1";
                    if (scl != prev)
                    {
                        prop_update_scale(index, scl);
                        llSay(0, "PROP size saved: " + (string)llRound(f * 100.0)
                            + "% ('" + name + "').");
                    }
                }
            }
            else
            {
                Out(0, "ERROR: cannot find prop: " + name);
            }
            return;
        }
        if (llList2String(data, 0) == "QSSAVEWORN")
        {
            // [QS]propadjust on a WORN prop replying to PROPSEARCH with its
            // current attach-point-local pos/rot (Euler deg).
            integer index = (integer)llList2String(data, 1);
            if (index >= 0 && index < prop_count_cached)
            {
                string wpos = llList2String(data, 2);
                string wrot = llList2String(data, 3);
                if (wpos != "")
                {
                    list entry = prop_load(index);
                    if (wpos != llList2String(entry, 9) || wrot != llList2String(entry, 10))
                    {
                        prop_update_worn(index, wpos, wrot);
                        llSay(0, "PROP fit saved: " + wpos + " / " + wrot
                            + " ('" + name + "').");
                    }
                }
            }
            else
            {
                Out(0, "ERROR: cannot find prop: " + name);
            }
            return;
        }
        if (llList2String(data, 0) == "ATTACHED" || llList2String(data, 0) == "DETACHED" || llList2String(data, 0) == "REZ" || llList2String(data, 0) == "DEREZ")
        {
            integer prop_index = (integer)llList2String(data, 1);
            list entry = prop_load(prop_index);
            string trig = llList2String(entry, 0);
            integer sitter = (integer)llList2String(llParseStringKeepNulls(trig, ["|"], []), 0);
            key sitter_key = llList2Key(SITTERS, sitter);
            if (sitter_key != NULL_KEY && llList2String(data, 0) == "REZ" && (integer)llList2String(entry, 1) == 1)
            {
                llSay(comm_channel, "ATTACHTO|" + (string)sitter_key + "|" + (string)id);
            }
            if (llList2String(data, 0) == "REZ")
            {
                string postSay = llList2String(entry, 7);
                if (postSay != "")
                {
                    llSay(comm_channel, postSay);
                }
                // Persisted scale factor + worn fit → [QS]propadjust in the
                // prop. Props without the companion ignore the commands.
                string scl = llList2String(entry, 8);
                if (scl != "" && (float)scl != 1.0)
                {
                    llSay(comm_channel, "QSSCALE|" + llList2String(data, 1) + "|" + scl);
                }
                string wpos = llList2String(entry, 9);
                if (wpos != "")
                {
                    llSay(comm_channel, "QSWORN|" + llList2String(data, 1)
                        + "|" + wpos + "|" + llList2String(entry, 10));
                }
            }
            llMessageLinked(LINK_SET, 90500, llDumpList2String([
                llList2String(data, 0),
                trig,
                llList2String(entry, 2),
                element(llList2String(entry, 3), 1),
                id
            ], "|"), sitter_key);
            return;
        }
        if (llList2String(data, 0) == "NAG" && HAVENTNAGGED && (!llGetAttached()))
        {
            llRegionSayTo(llGetOwner(), 0, "To enable auto-attachments, please enable the experience '" + llList2String(data, 1) + "' by Code Violet in 'About Land'.");
            HAVENTNAGGED = FALSE;
        }
    }

    dataserver(key query_id, string data)
    {
        if (query_id == notecard_query)
        {
            if (data == EOF)
            {
                prop_write_meta();
                Out(1, (string)prop_count_cached
                    + " Props Ready, Mem=" + (string)llGetFreeMemory());
                return;
            }

            data = llGetSubString(data, llSubStringIndex(data, "◆") + 1, 99999);
            data = llStringTrim(data, STRING_TRIM);
            string command = llGetSubString(data, 0, llSubStringIndex(data, " ") - 1);
            list parts = llParseStringKeepNulls(llGetSubString(data, llSubStringIndex(data, " ") + 1, 99999), [" | ", " |", "| ", "|"], []);
            if (command == "SITTER")
            {
                notecard_section = (integer)llList2String(parts, 0);
            }
            if (llGetSubString(command, 0, 3) == "PROP")
            {
                if (prop_count_cached == 100)
                {
                    Out(0, "ERROR: max props is 100, could not add prop!");
                }
                else
                {
                    integer prop_type;
                    if (command == "PROP1") prop_type = 1;
                    if (command == "PROP2") prop_type = 2;
                    if (command == "PROP3") prop_type = 3;
                    string prop_group = (string)notecard_section + "|" + llList2String(parts, 2);
                    // Optional fields 7-9 (1.25+): uniform scale factor
                    // (missing/zero/negative → "1", stock line format) +
                    // worn-fit pos/rot vectors ("" = unset).
                    string prop_scl = llList2String(parts, 6);
                    if ((float)prop_scl <= 0.0)
                    {
                        prop_scl = "1";
                    }
                    prop_add(
                        (string)notecard_section + "|" + llList2String(parts, 0),
                        prop_type,
                        llList2String(parts, 1),
                        prop_group,
                        (vector)llList2String(parts, 3),
                        (vector)llList2String(parts, 4),
                        llList2String(parts, 5),
                        "",
                        prop_scl,
                        llList2String(parts, 7),
                        llList2String(parts, 8));
                    if (llListFindList(sequential_prop_groups, [prop_group]) == -1)
                    {
                        sequential_prop_groups += prop_group;
                    }
                }
            }
            if (command == "WARN")
            {
                WARN = (integer)llList2String(parts, 0);
            }
            notecard_query = llGetNotecardLine(notecard_name, ++notecard_line);
        }
    }
}
