/*
 * [QS]prop - Rez props when playing poses (QuickySitter fork of [AV]prop)
 *
 * Minimally-invasive fork of avstock/Plugins/AVprop/[AV]prop.lsl (2.2p04).
 * Goal: stay as close to stock as possible. Diff against stock is:
 *   1. Sitter presence via QSALIVE (90096/90097) — NOT llGetInventoryType
 *      on a hardcoded script name. Stock's `string main_script = "[AV]sitA"`
 *      is replaced by `qs_alive` + `qs_sitter_count_cached`. See
 *      qs/PROTOCOL.md § QSALIVE. Plugin convention: never probe by script
 *      name (forks, renames, splits all break that).
 *   2. New global list `prop_post_rez_say` (parallel to prop_triggers).
 *      Notecard-loaded props get "" appended; only dynamic-attach props
 *      carry content. Out-of-range access returns "" so unaligned indexes
 *      degrade gracefully.
 *   3. In listen()'s comm_channel REZ branch, after the ATTACHTO say,
 *      emit prop_post_rez_say[prop_index] on comm_channel if non-empty.
 *      Generic — [QS]prop stays HUD-agnostic. hudadmin uses it to push
 *      "*QUICKYTEXTURE*|<uuid>" to a freshly-rezzed Quicky-Pose-HUD.
 *   4. New link_message handler num=90280 (QSPROP_ATTACH):
 *      Dynamic prop registration + immediate rez, without going through
 *      the AVpos notecard. Used by [QS]hudadmin to attach the HUD prop
 *      on sitter sit / manual button.
 *      msg = "<object>|<type>|<point>|<sitter_idx>|<post_rez_say>"
 *      id  = sitter_key
 *      Idempotent per (sitter_idx, object) — re-issue updates point /
 *      post_rez_say and re-rezzes.
 *
 * Removal of dynamically-attached props happens via the stock 90065
 * (stand-up) handler — remove_props_by_sitter wipes all type!=3 props
 * for the standing sitter without further coordination. No new linkmsg
 * needed for cleanup.
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
 *
 * Please consider supporting continued development of AVsitter and
 * receive automatic updates and other benefits! All details and user
 * instructions can be found at http://avsitter.github.io
 */

string version = "0.013"; // [QS] fork: own QS version (forked from stock [AV]prop 2.2p04)
string notecard_name = "AVpos";
// [QS] fork: sitter presence via QSALIVE handshake (qs/PROTOCOL.md § QSALIVE).
// Stock's `string main_script = "[AV]sitA"` is gone — script-name probes break
// across forks/renames. 90097 reply populates these caches.
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;
integer qs_alive = FALSE;
integer qs_sitter_count_cached = 1; // default until first 90097 reply
key key_request;
integer comm_channel;
integer WARN = 1;
key notecard_key;
key notecard_query;
integer notecard_line;
integer notecard_section;
integer listen_handle;
list prop_triggers;
list prop_types;
list prop_objects;
list prop_positions;
list prop_rotations;
list prop_groups;
list prop_points;
list prop_post_rez_say; // [QS] fork: parallel to prop_triggers. "" for stock entries; dynamic-attach payload for QSPROP_ATTACH entries.
list sequential_prop_groups;
integer HAVENTNAGGED = TRUE;
list SITTERS = [key_request]; //OSS::list SITTERS; // Force error in LSO
list SITTER_POSES;
// [QS] fork: ATTACH_POINTS lifted from global into get_point() as a
// function-local — used only there, so making it global cost ~2 KB
// of persistent heap for no benefit. The literal still costs the same
// bytecode either way, but at runtime the 80-element list is only
// instantiated for the duration of a get_point() call (rez_prop path,
// not the cache-load hot path), then freed on return. Gives the cache
// load ~2 KB extra headroom under heap pressure.

integer verbose = 5;

Out(integer level, string out)
{
    if (verbose >= level)
    {
        llOwnerSay(llGetScriptName() + "[" + version + "] " + out);
    }
}

// [QS] fork: was a stock inventory-walk on `main_script + " " + i`.
// Now uses the QSALIVE cache. Default 7 (Quicky's per-furniture hard
// cap on simultaneous sitters) so SITTERS is wide enough during the
// brief boot window before the first 90097 reply lands — otherwise a
// fast Sit on slot ≥ 1 would hit the `sitter >= len(SITTERS)` guard in
// the 90280 handler and get rejected, dropping the HUD-rez. The reply
// handler re-runs init_sitters() with the actual count once 90097 lands.
integer get_number_of_scripts()
{
    if (qs_alive) return qs_sitter_count_cached;
    return 7;
}

integer get_point(string text)
{
    // [QS] fork: ATTACH_POINTS is now a function-local — see global
    // declaration comment above. Allocated on entry, freed on return.
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

rez_prop(integer index)
{
    integer type = llList2Integer(prop_types, index);
    string object = llList2String(prop_objects, index);
    if (object != "")
    {
        vector pos = llList2Vector(prop_positions, index) * llGetRot() + llGetPos();
        rotation rot = llEuler2Rot(llList2Vector(prop_rotations, index) * DEG_TO_RAD) * llGetRot();
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
        // Param must be:
        //   - Negative
        //   - 4 digits comm_channel
        //   - 2 digits prop_id (index)
        //   - 2 digits attachment point
        //   - 1 digit prop_type
        // HACK: reuse 'perms' rather than calling the function in the
        // expression, to reduce stack usage
        perms = get_point(llList2String(prop_points, index));
        llRezAtRoot(object, pos, ZERO_VECTOR, rot,
            comm_channel * 100000 // negative, so we subtract everything else instead of adding
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
    integer i;
    for (; i < llGetListLength(prop_triggers); i++)
    {
        if (llList2String(prop_triggers, i) == pose_name)
        {
            rez_prop(i);
        }
    }
}

list get_props_by_pose(string pose_name)
{
    list props_to_do;
    integer i;
    for (; i < llGetListLength(prop_triggers); i++)
    {
        if (llList2String(prop_triggers, i) == pose_name)
        {
            props_to_do += i;
        }
    }
    return props_to_do;
}

remove_props_by_sitter(string sitter, integer remove_type3)
{
    list text;
    integer i;
    for (; i < llGetListLength(prop_triggers); i++)
    {
        if (llSubStringIndex(llList2String(prop_triggers, i), sitter + "|") == 0)
        {
            if (llList2Integer(prop_types, i) != 3 || remove_type3)
            {
                text += [i];
            }
        }
    }
    string command = "REM_INDEX";
    if (!qs_alive) // [QS] fork: was llGetInventoryType(main_script) != INVENTORY_SCRIPT
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
    list text;
    integer i;
    for (; i < llGetListLength(prop_triggers); i++)
    {
        if (llList2String(prop_triggers, i) == sitter_pose)
        {
            if (llList2Integer(prop_types, i) != 3 || remove_type3)
            {
                text += [i];
            }
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
    integer i;
    for (; i < llGetListLength(props); i++)
    {
        string prop_group = llList2String(prop_groups, llList2Integer(props, i));
        if (llListFindList(groups, [prop_group]) == -1)
        {
            groups += prop_group;
            remove_props_by_group(llListFindList(sequential_prop_groups, [prop_group]));
        }
    }
}

remove_props_by_group(integer gp)
{
    string text = "";
    string group = llList2String(sequential_prop_groups, gp);
    integer i;
    for (; i < llGetListLength(prop_groups); i++)
    {
        if (llList2String(prop_groups, i) == group)
        {
            text += "|" + (string)i;
        }
    }
    if (text != "")
    {
        if (qs_alive) // [QS] fork: was llGetInventoryType(main_script) == INVENTORY_SCRIPT
        {
            // sitA is in the prim — send the command to all sitters
            send_command("REM_INDEX" + text);
        }
        else
        {
            // Presumed to be launched from [AV]menu; avoid removing attachments from others
            send_command("REM_WORLD" + text); // this removes inworld props only
            if (llList2Key(SITTERS, 0)) // OSS::if (osIsUUID(llList2Key(SITTERS, 0)) && llList2Key(SITTERS, 0) != NULL_KEY)
            {
                // send command privately to current sitter
                llRegionSayTo((string)SITTERS, comm_channel, "REM_INDEX" + text);
            }
        }
    }
}

Readout_Say(string say)
{
    llSleep(0.2);
    llMessageLinked(LINK_THIS, 90022, say, ""); // dump to [AV]adjuster
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

// LSD-cache layer over the AVpos notecard parse. Big notecards take 5-10
// minutes to read on busy regions; caching the parsed prop data in
// linkset_data lets follow-up restarts skip the dataserver storm.
//
// Layout:
//   "qs:prop:meta" = "<notecard_key>\t<count>\t<warn>\t<sequential_groups>"
//     where sequential_groups is "\n"-joined.
//   "qs:prop:<i>"  = "<trigger>\t<type>\t<object>\t<group>\t<pos>\t<rot>\t<point>"
//     for i in 0..count-1.
//
// Validation: notecard_key in meta is compared against the current
// llGetInventoryKey(notecard_name). Mismatch ⇒ stale cache, fall back to
// the notecard read. Empty meta ⇒ never cached, same fallback.
//
// Tab is used as the field separator because pipe occurs inside
// prop_triggers ("<sitter>|<trigger>") and prop_groups ("<sitter>|<group>").
string LSD_PROP_META   = "qs:prop:meta";
string LSD_PROP_PREFIX = "qs:prop:";

// Async-load state. pending_load_count > 0 ⇒ timer is reading batches.
// Doing all 60 reads + 7-field parses in one frame Stack-Heap-collides
// intermittently because there are no frame boundaries between iters
// for LSL to free transients (unlike the notecard path, where the
// dataserver replies arrive across frames). The 0.05 s timer tick
// gives the runtime breathing room every BATCH_SIZE entries.
integer pending_load_count;
integer pending_load_index;
// One entry per tick. 5 still Stack-Heaped on a 60-prop notecard with
// ~13 KB free at state_entry, so we drop to a strict one-per-frame.
// 60 entries × 0.05 s = ~3 s total — still much better than the
// multi-minute notecard read.
integer BATCH_SIZE = 1;

// Helper for the notecard-key fingerprint comparison.
string current_notecard_key()
{
    if (llGetInventoryType(notecard_name) == INVENTORY_NOTECARD)
        return (string)llGetInventoryKey(notecard_name);
    return "";
}

// Validate the LSD cache and start an async load. Returns TRUE if the
// cache is valid and a batched read is now in progress (timer armed);
// FALSE if cache is empty / stale / count invalid — caller falls back
// to the notecard read. List population happens incrementally in the
// timer event; final meta-derived fields (WARN, sequential_prop_groups)
// are filled in on the closing batch.
integer load_props_from_lsd()
{
    string meta = llLinksetDataRead(LSD_PROP_META);
    if (meta == "") return FALSE;
    list metaParts = llParseStringKeepNulls(meta, ["\t"], []);
    if (llGetListLength(metaParts) < 4) return FALSE;
    if (llList2String(metaParts, 0) != current_notecard_key()) return FALSE;
    integer count = (integer)llList2String(metaParts, 1);
    if (count <= 0) return FALSE;

    pending_load_count = count;
    pending_load_index = 0;
    // 0.2 s tick instead of 0.05 — sim is heavily contested at boot
    // (4× Hand Poses, LoveBridge, [QS]* etc. all parse their own
    // notecards in parallel), so we need wider frame breaks for the
    // LSL runtime to free per-iteration transients before the next
    // batch piles on. 60 entries × 0.2 s ≈ 12 s; still acceptable
    // compared to the multi-minute notecard read.
    llSetTimerEvent(0.2);
    return TRUE;
}

// Persist current parsed prop state to LSD. Called once after a successful
// dataserver EOF. Heap-tight on purpose: at this point the lists are full
// (~10 KB), heap is around 6 KB free, so no intermediate list allocations.
//
// Atomicity: meta is the commit marker. We delete it first so a Stack-Heap
// crash mid-write leaves the cache invalid (load() returns FALSE on empty
// meta and falls back to the notecard read). Old-count is read once at the
// top so we know which dangling indices to delete past the new count —
// avoids llLinksetDataFindKeys, which allocates a key-list we can't afford.
save_props_to_lsd()
{
    integer oldCount = 0;
    string oldMeta = llLinksetDataRead(LSD_PROP_META);
    if (oldMeta != "")
        oldCount = (integer)llList2String(llParseStringKeepNulls(oldMeta, ["\t"], []), 1);
    llLinksetDataDelete(LSD_PROP_META);  // invalidate before mutation

    integer count = llGetListLength(prop_triggers);
    integer i;
    for (i = 0; i < count; i++)
    {
        // Inline string-concat instead of llDumpList2String([...], "\t"):
        // skips the 7-element temporary list allocation per iteration.
        llLinksetDataWrite(LSD_PROP_PREFIX + (string)i,
            llList2String(prop_triggers, i) + "\t"
            + (string)llList2Integer(prop_types, i) + "\t"
            + llList2String(prop_objects, i) + "\t"
            + llList2String(prop_groups, i) + "\t"
            + (string)llList2Vector(prop_positions, i) + "\t"
            + (string)llList2Vector(prop_rotations, i) + "\t"
            + llList2String(prop_points, i));
    }
    for (i = count; i < oldCount; i++)
        llLinksetDataDelete(LSD_PROP_PREFIX + (string)i);

    string currentKey = "";
    if (llGetInventoryType(notecard_name) == INVENTORY_NOTECARD)
        currentKey = (string)llGetInventoryKey(notecard_name);
    // Meta last — this is the commit point that re-validates the cache.
    llLinksetDataWrite(LSD_PROP_META,
        currentKey + "\t" + (string)count + "\t" + (string)WARN
        + "\t" + llDumpList2String(sequential_prop_groups, "\n"));
}

default
{
    state_entry()
    {
        Out(0, "Mem=" + (string)(65536 - llGetUsedMemory()));
        // [QS] fork: probe QSALIVE first so the reply can update SITTERS
        // asynchronously while we keep initializing. init_sitters() runs
        // against the default count; the 90097 handler re-runs it if
        // the cached count disagrees.
        qs_alive = FALSE;
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
        init_sitters();
        init_channel();
        notecard_key = llGetInventoryKey(notecard_name);
        // [QS] fork: try LSD cache first. On hit we arm a timer that
        // batches the reads across frames (avoids Stack-Heap on big
        // notecards); the "Props Ready (cached)" announcement comes
        // from the closing batch in timer(). On miss fall through to
        // the notecard read.
        if (load_props_from_lsd())
        {
            Out(0, "Loading " + (string)pending_load_count + " props from cache...");
        }
        else if (llGetInventoryType(notecard_name) == INVENTORY_NOTECARD)
        {
            Out(0, "Loading...");
            notecard_query = llGetNotecardLine(notecard_name, 0);
        }
    }

    // Async LSD-cache batch loader. Only runs when pending_load_count > 0
    // (set by load_props_from_lsd). Reads BATCH_SIZE entries per tick to
    // keep peak heap below the Stack-Heap line on big notecards, then
    // finalizes meta-derived state on the closing batch and disarms.
    timer()
    {
        if (pending_load_count == 0) {
            llSetTimerEvent(0);
            return;
        }
        integer batchEnd = pending_load_index + BATCH_SIZE;
        if (batchEnd > pending_load_count) batchEnd = pending_load_count;
        integer i;
        for (i = pending_load_index; i < batchEnd; i++)
        {
            string entry = llLinksetDataRead(LSD_PROP_PREFIX + (string)i);
            if (entry == "")
            {
                // Corrupt cache mid-load: drop everything and start over
                // from the notecard. Clean slate is safer than partial.
                pending_load_count = 0;
                llSetTimerEvent(0);
                prop_triggers     = [];
                prop_types        = [];
                prop_objects      = [];
                prop_groups       = [];
                prop_positions    = [];
                prop_rotations    = [];
                prop_points       = [];
                prop_post_rez_say = [];
                if (llGetInventoryType(notecard_name) == INVENTORY_NOTECARD)
                {
                    Out(0, "Cache corrupt, loading from notecard...");
                    notecard_query = llGetNotecardLine(notecard_name, 0);
                }
                return;
            }
            // Manual tab-split instead of llParseStringKeepNulls — saves
            // ~250 B per iter (the 7-element parse-list allocation). Each
            // llDeleteSubString shrinks the remaining entry transient by
            // its already-consumed prefix, so peak per field stays small.
            integer p = llSubStringIndex(entry, "\t");
            prop_triggers  += llGetSubString(entry, 0, p - 1);
            entry = llDeleteSubString(entry, 0, p);
            p = llSubStringIndex(entry, "\t");
            prop_types     += (integer)llGetSubString(entry, 0, p - 1);
            entry = llDeleteSubString(entry, 0, p);
            p = llSubStringIndex(entry, "\t");
            prop_objects   += llGetSubString(entry, 0, p - 1);
            entry = llDeleteSubString(entry, 0, p);
            p = llSubStringIndex(entry, "\t");
            prop_groups    += llGetSubString(entry, 0, p - 1);
            entry = llDeleteSubString(entry, 0, p);
            p = llSubStringIndex(entry, "\t");
            prop_positions += (vector)llGetSubString(entry, 0, p - 1);
            entry = llDeleteSubString(entry, 0, p);
            p = llSubStringIndex(entry, "\t");
            prop_rotations += (vector)llGetSubString(entry, 0, p - 1);
            entry = llDeleteSubString(entry, 0, p);
            prop_points    += entry;  // last field, no more separator
            prop_post_rez_say += "";  // runtime-only, never cached
        }
        pending_load_index = batchEnd;

        if (pending_load_index >= pending_load_count)
        {
            // Closing batch — re-read meta to harvest WARN + sequential
            // groups. Avoids keeping a stale large string in a module
            // variable across the whole load.
            string meta = llLinksetDataRead(LSD_PROP_META);
            list mp = llParseStringKeepNulls(meta, ["\t"], []);
            WARN = (integer)llList2String(mp, 2);
            string seqJoined = llList2String(mp, 3);
            if (seqJoined != "")
                sequential_prop_groups = llParseStringKeepNulls(seqJoined, ["\n"], []);
            Out(0, (string)pending_load_count
                + " Props Ready (cached), Mem=" + (string)llGetFreeMemory());
            pending_load_count = 0;
            llSetTimerEvent(0);
        }
    }

    on_rez(integer start)
    {
        init_channel();
        // [QS] fork: re-probe QSALIVE — the rez may have changed which
        // sitter scripts are present (e.g. furniture handed to a new
        // owner, scripts swapped).
        qs_alive = FALSE;
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        // [QS] fork: QSALIVE reply from [QS]sitA slot 0. Cache the sitter
        // count and mark sitA present so subsequent checks take the fast
        // path. Payload is pipe-delimited <product>|<ver>|<sitters>|<caps>.
        // Both solicited (response to our 90096) and unsolicited (slot-0
        // boot broadcast) replies arrive here. See qs/PROTOCOL.md § QSALIVE.
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

        // [QS] fork: dynamic attach without notecard.
        // Sender can be any link (hudadmin lives in the same prim as us
        // today, but allow LINK_SET in case that changes). Idempotent
        // per (sitter_idx, object): re-issue updates point + post_rez_say
        // and re-rezzes.
        if (num == 90280)
        {
            // Fixed-position payload: object|type|point|sitter|post_rez_say
            // Use KeepNulls (matches stock [AV]prop's listen() convention) so
            // an empty point at position 2 doesn't collapse subsequent fields.
            list params = llParseStringKeepNulls(msg, ["|"], []);
            if (llGetListLength(params) < 4) return;
            string  obj     = llList2String(params, 0);
            integer type    = (integer)llList2String(params, 1);
            string  point   = llList2String(params, 2);
            integer sitter  = (integer)llList2String(params, 3);
            // postSay may itself contain '|' (e.g. "*QUICKYTEXTURE*|<uuid>" or
            // multi-command "<cmd1>;;<cmd2>" where each cmd is pipe-formatted).
            // Rejoin everything from index 4 onward so the payload survives.
            string  postSay = "";
            if (llGetListLength(params) > 4)
                postSay = llDumpList2String(llList2List(params, 4, -1), "|");
            if (obj == "") return;
            if (sitter < 0 || sitter >= llGetListLength(SITTERS)) return;

            string  trig = (string)sitter + "|" + obj;
            integer idx  = llListFindList(prop_triggers, [trig]);
            if (idx == -1)
            {
                idx = llGetListLength(prop_triggers);
                prop_triggers     += trig;
                prop_types        += type;
                prop_objects      += obj;
                string grp        = (string)sitter + "|QSDYN";
                prop_groups       += grp;
                if (llListFindList(sequential_prop_groups, [grp]) == -1)
                    sequential_prop_groups += grp;
                prop_positions    += <0.0, 0.0, 0.0>;
                prop_rotations    += <0.0, 0.0, 0.0>;
                prop_points       += point;
                prop_post_rez_say += postSay;
            }
            else
            {
                // Update mutable fields (point + post_rez_say); type/object stay stable per trigger
                prop_points       = llListReplaceList(prop_points,       [point],   idx, idx);
                prop_post_rez_say = llListReplaceList(prop_post_rez_say, [postSay], idx, idx);
            }
            // Keep SITTERS in sync so the listen() REZ branch can resolve sitter_key
            if (id != NULL_KEY)
                SITTERS = llListReplaceList(SITTERS, [id], sitter, sitter);
            rez_prop(idx);
            return;
        }

        if (sender == llGetLinkNumber())
        {
            if (num == 90045) // play pose
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
            if (num == 90200 || num == 90220) // rez or clear prop with/without sending menu back
            {
                list ids = llParseStringKeepNulls(id, ["|"], []);
                key sitting_av_or_sitter = (key)llList2String(ids, -1);
                if (!qs_alive) // [QS] fork: was llGetInventoryType(main_script) != INVENTORY_SCRIPT
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
                        if (llListFindList(prop_triggers, [(string)i + "|" + msg]) != -1)
                        {
                            flag = TRUE;
                        }
                    }
                    for (i = 0; i < llGetListLength(SITTERS); i++)
                    {
                        if (llList2Key(SITTERS, i) == sitting_av_or_sitter || id == "" || (string)sitting_av_or_sitter == (string)i)
                        {
                            integer index = llListFindList(prop_triggers, [(string)i + "|" + msg]);
                            if (index == -1)
                            {
                                if (!qs_alive) // [QS] fork: was llGetInventoryType(main_script) != INVENTORY_SCRIPT
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
                if (sitting_av_or_sitter) // OSS::if (osIsUUID(sitting_av_or_sitter) && sitting_av_or_sitter != NULL_KEY)
                {
                    if (num == 90200) // send menu back?
                    {
                        // send menu to same id
                        llMessageLinked(LINK_THIS, 90005, "", id);
                    }
                }
                return;
            }
            if (num == 90101) // menu choice
            {
                list data = llParseString2List(msg, ["|"], []);
                if (llList2String(data, 1) == "[SAVE]")
                {
                    llRegionSay(comm_channel, "PROPSEARCH");
                }
                return;
            }
            if (num == 90065) // stand up
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
            if (num == 90030) // swap
            {
                remove_props_by_sitter(msg, FALSE);
                remove_props_by_sitter((string)id, FALSE);
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)msg, (integer)msg);
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)((string)id), (integer)((string)id));
                return;
            }
            if (num == 90070) // update list of sitters
            {
                SITTERS = llListReplaceList(SITTERS, [id], (integer)msg, (integer)msg);
                return;
            }
            if (num == 90171 || num == 90173) // [AV]adjuster/[AV]menu add PROP line
            {
                integer sitter;
                if (num == 90171) // [AV]adjuster?
                {
                    sitter = (integer)msg;
                    prop_triggers += [llList2String(SITTER_POSES, sitter)];
                }
                else
                {
                    sitter = 0;
                    SITTER_POSES = ["0|" + msg];
                    prop_triggers += "0|" + msg;
                }
                prop_types += 0;
                prop_objects += (string)id;
                string prop_group = (string)sitter + "|G1";
                prop_groups += prop_group;
                if (llListFindList(sequential_prop_groups, [prop_group]) == -1)
                {
                    sequential_prop_groups += prop_group;
                }
                prop_positions += <0,0,1>;
                prop_rotations += <0,0,0>;
                prop_points += "";
                prop_post_rez_say += ""; // [QS] fork: keep parallel-list aligned
                rez_prop(llGetListLength(prop_triggers) - 1);
                string text = "PROP added: '" + (string)id + "' to '" + element(llList2String(SITTER_POSES, sitter), 1) + "'";
                if (llGetListLength(SITTERS) > 1)
                {
                    text += " for SITTER " + (string)sitter;
                }
                llSay(0, text);
                llSay(0, "Position your prop and click [SAVE].");
                return;
            }
            if (num == 90020 && (string)id == llGetScriptName()) // dump our settings
            {
                integer i;
                for (; i < llGetListLength(prop_triggers); i++)
                {
                    if (llSubStringIndex(llList2String(prop_triggers, i), msg + "|") == 0)
                    {
                        string type = (string)llList2Integer(prop_types, i);
                        if (type == "0")
                        {
                            type = "";
                        }
                        Readout_Say("PROP" + type + " " + llDumpList2String([element(llList2String(prop_triggers, i), 1), llList2String(prop_objects, i), element(llList2String(prop_groups, i), 1), llList2String(prop_positions, i), llList2String(prop_rotations, i), llList2String(prop_points, i)], "|"));
                    }
                }
                llMessageLinked(LINK_THIS, 90021, msg, llGetScriptName()); // notify finished dumping
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
                llResetScript();
            }
            else
            {
                // [QS] fork: re-probe QSALIVE — sitA may have been added
                // / removed / its slot count changed. Reply re-inits
                // SITTERS if the cached count disagrees.
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
                if (qs_alive) // [QS] fork: was llGetInventoryType(main_script) == INVENTORY_SCRIPT
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
            if (index >= 0 && index < llGetListLength(prop_triggers))
            {
                if (llList2Vector(llGetObjectDetails(id, [OBJECT_POS]), 0) != ZERO_VECTOR)
                {
                    list details = [OBJECT_POS, OBJECT_ROT];
                    rotation f = llList2Rot((details = llGetObjectDetails(llGetKey(), details) + llGetObjectDetails(id, details)), 1);
                    vector target_rot = llRot2Euler(llList2Rot(details, 3) / f) * RAD_TO_DEG;
                    vector target_pos = (llList2Vector(details, 2) - llList2Vector(details, 0)) / f;
                    prop_positions = llListReplaceList(prop_positions, [target_pos], index, index);
                    prop_rotations = llListReplaceList(prop_rotations, [target_rot], index, index);
                    string type = llList2String(prop_types, index);
                    if (type == "0")
                    {
                        type = "";
                    }
                    string text = "PROP Saved to memory, SITTER " + element(llList2String(prop_triggers, index), 0) + ": PROP" + type + " " + element(llList2String(prop_triggers, index), 1) + "|" + name + "|" + element(llList2String(prop_groups, index), 1) + "|" + (string)target_pos + "|" + (string)target_rot + "|" + llList2String(prop_points, index);
                    llSay(0, text);
                }
            }
            else
            {
                Out(0, "Error, cannot find prop: " + name);
            }
            return;
        }
        if (llList2String(data, 0) == "ATTACHED" || llList2String(data, 0) == "DETACHED" || llList2String(data, 0) == "REZ" || llList2String(data, 0) == "DEREZ")
        {
            integer prop_index = (integer)llList2String(data, 1);
            integer sitter = (integer)llList2String(llParseStringKeepNulls(llList2String(prop_triggers, prop_index), ["|"], []), 0);
            key sitter_key = llList2Key(SITTERS, sitter);
            if (sitter_key != NULL_KEY && llList2String(data, 0) == "REZ" && llList2Integer(prop_types, prop_index) == 1)
            {
                llSay(comm_channel, "ATTACHTO|" + (string)sitter_key + "|" + (string)id);
            }
            // [QS] fork: optional post-rez extra say (e.g. hudadmin pushing
            // "*QUICKYTEXTURE*|<uuid>" to a freshly-rezzed Quicky-Pose-HUD).
            // Generic — [QS]prop holds the payload verbatim and forwards it.
            if (llList2String(data, 0) == "REZ")
            {
                string postSay = llList2String(prop_post_rez_say, prop_index);
                if (postSay != "")
                {
                    llSay(comm_channel, postSay);
                }
            }
            // send prop event notification
            llMessageLinked(LINK_SET, 90500, llDumpList2String([llList2String(data, 0), llList2String(prop_triggers, prop_index), llList2String(prop_objects, prop_index), llList2String(llParseStringKeepNulls(llList2String(prop_groups, prop_index), ["|"], []), 1), id], "|"), sitter_key);
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
                // [QS] fork: persist parse result to LSD so the next state_entry
                // can skip the dataserver loop. See load_props_from_lsd above.
                save_props_to_lsd();
                Out(0, (string)llGetListLength(prop_triggers) + " Props Ready, Mem=" + (string)llGetFreeMemory());
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
                if (llGetListLength(prop_triggers) == 100)
                {
                    Out(0, "Max props is 100, could not add prop!"); // the real limit is less than this due to memory running out first :)
                }
                else
                {
                    integer prop_type;
                    if (command == "PROP1")
                    {
                        prop_type = 1;
                    }
                    if (command == "PROP2")
                    {
                        prop_type = 2;
                    }
                    if (command == "PROP3")
                    {
                        prop_type = 3;
                    }
                    prop_triggers += [(string)notecard_section + "|" + llList2String(parts, 0)];
                    prop_types += prop_type;
                    prop_objects += llList2String(parts, 1);
                    string prop_group = (string)notecard_section + "|" + llList2String(parts, 2);
                    prop_groups += prop_group;
                    if (llListFindList(sequential_prop_groups, [prop_group]) == -1)
                    {
                        sequential_prop_groups += prop_group;
                    }
                    prop_positions += (vector)llList2String(parts, 3);
                    prop_rotations += (vector)llList2String(parts, 4);
                    prop_points += llList2String(parts, 5);
                    prop_post_rez_say += ""; // [QS] fork: keep parallel-list aligned with notecard-loaded props
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
