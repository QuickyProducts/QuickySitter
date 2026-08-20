string version = "0.904";
/*
 * [QS]prop2 - alternative prop engine (wire v2), creator opt-in
 *
 * Sibling of [QS]prop 1.28, NOT its successor. [QS]prop stays frozen on
 * the stock wire (props carry stock [AV]object plus the optional
 * [QS]objectadjust companion); this script pairs with [QS]object and
 * ships in the creator box as an alternative. Exactly ONE of
 * [QS]prop / [QS]prop2 belongs in the prim - both at once double-rez
 * every prop (a HELLO cross-check below warns about that).
 *
 * Wire selection via AVpos `PROP2 ON` (same name as the script),
 * placed BEFORE the first PROP line:
 *   line absent (default) - stock decimal start_param, cap 100 props,
 *     props may keep stock [AV]object.
 *   PROP2 ON - bit-packed POSITIVE start_param, cap 1024 props,
 *     EVERY prop must carry [QS]object. Stock [AV]object cannot decode
 *     the positive param and sits inert on no channel - do not mix.
 *
 * `PROP2` doubles as the type-2 prop command (`PROP2 trigger|object|…`);
 * the switch is told apart by having NO | fields. Legacy parsers
 * ([QS]prop, boot) read a stray `PROP2 ON` as a prop line with an empty
 * object name and drop it at rez time - ugly but harmless.
 *
 * Wire v2 start_param layout (positive; the stock wire is always
 * <= -10000000, so the sign is the discriminator [QS]object switches
 * decoders on):
 *   bits  0-1   type (0-3)
 *   bits  2-7   attach point (0-63, AVsitter numbering)
 *   bits  8-17  prop index (0-1023)
 *   bits 18-30  channel magnitude (1000-8191, channel = -magnitude)
 *
 * Forked from [QS]prop at commit 510f918 (the 1.281 cleanup pass).
 * Original fork notes preserved below.
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
 *      [SAVE]), handled by the [QS]objectadjust companion script inside the
 *      prop (shipped in qs/plugins/propadjust/, named after the stock
 *      [AV]object it sits beside). Props without the companion, and stock
 *      [AV]prop receiving the QSSAVE* replies, ignore the extension
 *      entirely. See qs/PROTOCOL.md § Prop scale for the open wire spec.
 *
 * LSD layout under "qs:prop:*":
 *   qs:prop:meta        = "<notecard_key>\t<count>\t<warn>\t<groups_nl>\t<wire>"
 *                         (groups_nl is "\n"-joined sequential_prop_groups;
 *                         wire field absent in rows written by
 *                         [QS]prop - reads as wire 1)
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
 *   qs:prop2:chan       = last comm_channel. Deliberately OUTSIDE the
 *                         wiped qs:prop:* namespace; swept with REM_ALL
 *                         on the next state_entry (see init_channel).
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
// Wire selection (AVpos `PROP2 ON` line; persisted in the meta record
// so LSD-cached boots keep it without a notecard re-read).
integer WIRE = 1;
integer PROP_CAP = 100;
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
// Wire-2 handshake watchdog (0.902): prop indices rezzed but not yet
// confirmed by a REZ reply. Fed only on WIRE == 2, drained by the REZ
// listen branch, checked by the one-shot timer armed per rez burst.
list PENDING_REZ;

integer HAVENTNAGGED = TRUE;
list SITTERS = [key_request]; //OSS::list SITTERS;
list SITTER_POSES;

// Verbose convention: 0=error/warn floor (default), 1=boot banner,
// 2=runtime status, 3=debug. Level 0 always prints — verbose floors at 0.
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

integer get_number_of_scripts()
{
    if (qs_alive) return qs_sitter_count_cached;
    return 7;
}

integer get_point(string text)
{
    // Attach-point lookup, second memory pass (1.25): the name list is
    // a function-local literal (no global => no resident heap copy),
    // names-only and pre-uppercased (no llToUpper alloc per loop turn).
    // Positions are contiguous: value = list index + 1 = the ATTACH_*
    // constant (chest=1 ... avatar center=40), verified against the
    // stock pair list. Order matters: first substring match wins.
    list pts = llCSV2List("CHEST,HEAD,LEFT SHOULDER,RIGHT SHOULDER,LEFT HAND,RIGHT HAND,LEFT FOOT,RIGHT FOOT,BACK,PELVIS,MOUTH,CHIN,LEFT EAR,RIGHT EAR,LEFT EYE,RIGHT EYE,NOSE,RIGHT UPPER ARM,RIGHT LOWER ARM,LEFT UPPER ARM,LEFT LOWER ARM,RIGHT HIP,RIGHT UPPER LEG,RIGHT LOWER LEG,LEFT HIP,LEFT UPPER LEG,LEFT LOWER LEG,STOMACH,LEFT PECTORAL,RIGHT PECTORAL,HUD CENTER 2,HUD TOP RIGHT,HUD TOP,HUD TOP LEFT,HUD CENTER,HUD BOTTOM LEFT,HUD BOTTOM,HUD BOTTOM RIGHT,NECK,AVATAR CENTER");
    text = llToUpper(text);
    integer i;
    for (i = 0; i < 40; i++)
    {
        if (llSubStringIndex(text, llList2String(pts, i)) != -1)
        {
            return i + 1;
        }
    }
    return 0;
}

// ───────────────────────────────────────────────────────────────────
// LSD storage layer
// ───────────────────────────────────────────────────────────────────

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

// Validated read of a qs:prop:trig:<trig> index row (1.25). A crash
// mid-write (early-1.25 Stack-Heap Collision inside the 90280 handler)
// can leave the row poisoned or stale; the plain (integer) cast turned
// such garbage into index 0 and rezzed the wrong prop. Every element
// must be a well-formed in-range integer whose row's trig field matches
// the requested trigger; otherwise the poisoned key is deleted and []
// returned, so callers treat the trigger as absent and 90280 re-creates
// it via prop_add (self-heal). Transient list only, no resident state.
list prop_trig_indices(string trig)
{
    list idx = prop_index_list(LSD_TRIG_PFX + trig);
    integer n = llGetListLength(idx);
    integer i;
    for (i = 0; i < n; i++)
    {
        string s = llList2String(idx, i);
        integer v = (integer)s;
        if ((string)v != s || v < 0 || v >= prop_count_cached
            || llList2String(prop_load(v), 0) != trig)
        {
            llLinksetDataDelete(LSD_TRIG_PFX + trig);
            Out(0, "WARN: bad prop index '" + trig + "' dropped.");
            return [];
        }
    }
    return idx;
}

// Return the first index matching `trig`, or -1 if no entry.
// (90280 dynamic-attach uses this for idempotent re-attach.)
integer prop_find_trigger(string trig)
{
    list idx = prop_trig_indices(trig);
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
    if (prop_count_cached >= PROP_CAP)
    {
        // Cap enforced HERE, not in the notecard reader: the authoring
        // paths (90171/90173 world-add, 90280 dynamic attach) used to
        // walk straight past the dataserver-only check, and an index
        // past the cap overflows the start_param encoding - the prop
        // decodes a neighbouring channel and never hears REM_ALL.
        Out(0, "ERROR: max props is " + (string)PROP_CAP + ", could not add prop!");
        return -1;
    }
    integer idx = prop_count_cached;
    integer rc = llLinksetDataWrite(LSD_PROP_PFX + (string)idx,
        trig + "\t" + (string)type + "\t" + obj + "\t" + grp
        + "\t" + (string)pos + "\t" + (string)rot + "\t" + pt + "\t" + prs
        + "\t" + scl + "\t" + wpos + "\t" + wrot);
    if (rc != LINKSETDATA_OK)
    {
        // 0.901: a silently failed entry write (LSD store full: rc 1,
        // literal - see house LSD-constants rule) used to leave index
        // rows pointing at nothing, which surfaces much later as the
        // self-heal WARN dropping the trigger. Fail loudly instead,
        // and BEFORE the index writes so nothing dangles.
        Out(0, "ERROR: LSD write failed (" + (string)rc
            + "), prop not stored: " + trig);
        return -1;
    }
    prop_index_append(LSD_TRIG_PFX + trig, idx);
    prop_index_append(LSD_SIT_PFX  + prop_trig_sit(trig), idx);
    prop_index_append(LSD_GRP_PFX  + grp, idx);
    prop_count_cached++;
    return idx;
}

// Generic field update on an existing prop row (1.25 memory trim —
// replaces the four per-field updaters: pos/rot from SAVEPROP, pt/prs
// from 90280 re-attach, scale from QSSAVESCALE, worn from QSSAVEWORN).
// Pads to 11 fields first so index-writes land correctly on rows
// written by older versions (8 or 9 fields).
prop_update(integer idx, integer field, list vals)
{
    list entry = prop_load(idx);
    while (llGetListLength(entry) < 11)
        entry += "";
    entry = llListReplaceList(entry, vals,
        field, field + llGetListLength(vals) - 1);
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
        + "\t" + llDumpList2String(sequential_prop_groups, "\n")
        + "\t" + (string)WIRE);
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
        integer start_param;
        if (WIRE == 2)
        {
            // Wire v2: positive, bit-packed (see header). [QS]object
            // switches decoders on the sign.
            start_param = ((-comm_channel) << 18) | (index << 8) | (perms << 2) | type;
        }
        else
        {
            // Stock decimal wire, decoded by digit-slicing in
            // [AV]object and [QS]object alike.
            start_param = comm_channel * 100000
                - (index * 1000
                    + perms * 10
                    + type);
        }
        llRezAtRoot(object, pos, ZERO_VECTOR, rot, start_param);
        if (WIRE == 2)
        {
            // Handshake watchdog: [QS]object answers REZ on both wires,
            // stock [AV]object cannot decode the positive v2 param and
            // stays silent. Re-arming per rez in a burst is deliberate:
            // the check runs once, after the LAST rez settles.
            if (llListFindList(PENDING_REZ, [index]) == -1)
            {
                PENDING_REZ += index;
            }
            llSetTimerEvent(10.0);
        }
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
    list idx_strs = prop_trig_indices(pose_name);
    integer n = llGetListLength(idx_strs);
    integer i;
    for (i = 0; i < n; i++)
    {
        rez_prop((integer)llList2String(idx_strs, i));
    }
}

// Send one REM_INDEX for every prop listed under `lsd_key`, skipping
// type-3 (sequential) props unless remove_type3.
//
// 1.281: merged from the former remove_props_by_sitter (sitter index,
// REM_WORLD fallback) and remove_sitter_props_by_pose (trigger index,
// always REM_INDEX). They differed only in the LSD prefix and in whether
// the pre-QS fallback downgrades the command, so callers now pass the
// built key plus allow_world instead of duplicating the whole loop.
remove_indexed(string lsd_key, integer remove_type3, integer allow_world)
{
    list idx_strs = prop_index_list(lsd_key);
    integer n = llGetListLength(idx_strs);
    list text;
    integer i;
    for (i = 0; i < n; i++)
    {
        integer idx = (integer)llList2String(idx_strs, i);
        if ((integer)llList2String(prop_load(idx), 1) != 3 || remove_type3)
        {
            text += [idx];
        }
    }
    if (text != [])
    {
        string command = "REM_INDEX";
        if (allow_world && !qs_alive)
        {
            command = "REM_WORLD";
        }
        // 0.904: chunked. llSay/llRegionSay truncate at 1024 bytes; a
        // wire-2 removal can carry up to 1024 indices (~5 KB), and the
        // cut-off tail would simply stay rezzed. 60 indices per say
        // stays under ~300 B. Stock never hit this (cap 100 ~ 400 B).
        integer total = llGetListLength(text);
        integer at;
        for (at = 0; at < total; at += 60)
        {
            integer end = at + 59;
            if (end >= total)
            {
                end = total - 1;
            }
            send_command(llDumpList2String(
                [command] + llList2List(text, at, end), "|"));
        }
    }
}

remove_worn(key av)
{
    send_command(llDumpList2String(["REM_WORN", av], "|"));
}

remove_sitter_props_by_pose_group(string msg)
{
    list idx_strs = prop_trig_indices(msg);
    list groups;
    integer n = llGetListLength(idx_strs);
    integer i;
    for (i = 0; i < n; i++)
    {
        integer idx = (integer)llList2String(idx_strs, i);
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
    // 0.904: chunked like remove_indexed - see the 1024-byte say cap.
    integer at;
    for (at = 0; at < n; at += 60)
    {
        integer end = at + 59;
        if (end >= n)
        {
            end = n - 1;
        }
        string text = "|" + llDumpList2String(llList2List(idx_strs, at, end), "|");
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
    // Magnitude 1000-8191: wire v2 has 13 bits for the channel, and
    // the narrower roll costs wire v1 nothing.
    comm_channel = ((integer)llFrand(7191) + 1000) * -1;
    listen_handle = llListen(comm_channel, "", "", "");
    // Persist OUTSIDE qs:prop:* (that namespace is wiped on notecard
    // change): the next state_entry sweeps props left on the old
    // channel. Without this, a script reset or update push while props
    // were out stranded them forever - the prop-side watchdog only
    // checks that the furniture still exists, not that anyone still
    // talks to it.
    llLinksetDataWrite("qs:prop2:chan", (string)comm_channel);
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
        // Sweep props stranded on the previous life's channel before
        // rolling a new one (see init_channel).
        integer old_chan = (integer)llLinksetDataRead("qs:prop2:chan");
        if (old_chan)
        {
            llRegionSay(old_chan, "REM_ALL");
        }
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
                // Wire survives LSD-cached boots via the meta record; a
                // 4-field row written by [QS]prop reads "" here = wire 1.
                WIRE = (integer)llList2String(mp, 4);
                if (WIRE == 2)
                {
                    PROP_CAP = 1024;
                }
                else
                {
                    WIRE = 1;
                }
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
        if (num == QSDUMP_HELLO && (string)id == "[QS]prop")
        {
            // Both prop engines in one prim double-rez every prop. Each
            // broadcasts HELLO on state_entry, so at least one side
            // sees the other regardless of install order.
            Out(0, "ERROR: [QS]prop and [QS]prop2 are both installed - remove one.");
            return;
        }
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
            // Slot 99 = the standing operator (Remote authoring): it has no
            // seat, so no index into SITTERS. Deliberately not -1, because
            // llList2Key counts a negative index from the END of the list
            // and would silently resolve to the last sitter.
            if (sitter != 99)
            {
                if (sitter < 0 || sitter >= llGetListLength(SITTERS)) return;
            }

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
                prop_update(idx, 6, [point, postSay]);
            }
            if (idx == -1)
            {
                // prop_add hit the cap - nothing registered, nothing
                // to rez.
                return;
            }
            // The standing operator owns no seat, so nothing of theirs may
            // be written into the slot table.
            if (sitter != 99 && id != NULL_KEY)
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
                    remove_indexed(LSD_TRIG_PFX + llList2String(SITTER_POSES, sitter), FALSE, FALSE);
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
                            remove_indexed(LSD_TRIG_PFX + (string)i + "|" + llGetSubString(msg, 8, 99999), TRUE, FALSE);
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
                                    remove_indexed(LSD_SIT_PFX + (string)i, TRUE, TRUE);
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
                remove_indexed(LSD_SIT_PFX + msg, FALSE, TRUE);
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
                remove_indexed(LSD_SIT_PFX + msg, FALSE, TRUE);
                remove_indexed(LSD_SIT_PFX + (string)id, FALSE, TRUE);
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
                if (new_idx == -1)
                {
                    return;
                }
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
                // Round-trip the wire switch (0.901): without this line
                // a wire-v2 creator's [DUMP] pastes into a card that
                // silently boots on wire 1 - props still run (dual
                // decoder in [QS]object) but the cap drops back to 100.
                // Emitted once, in sitter 0's block, which the cascade
                // streams before any PROP line - satisfying the parser's
                // before-first-PROP rule on re-read.
                if (WIRE == 2 && msg == "0")
                {
                    Readout_Say("PROP2 ON");
                }
                // Dump matching props (sitter prefix) — iterate all
                // indices since there's no direct sitter-pose index.
                // Rare admin path; the O(count) LSD reads are fine.
                integer count = prop_count_cached;
                integer i;
                for (i = 0; i < count; i++)
                {
                    list entry = prop_load(i);
                    string trig = llList2String(entry, 0);
                    // QSDYN rows are internal 90280 attach registrations
                    // (re-created on demand by the HUD attach path); a
                    // dumped line would round-trip into customer AVpos
                    // notecards as a bogus attachment prop.
                    if (llSubStringIndex(trig, msg + "|") == 0
                        && element(llList2String(entry, 3), 1) != "QSDYN")
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

    timer()
    {
        // One-shot wire-2 handshake watchdog (0.902), armed per rez
        // burst in rez_prop(). Whatever is still pending after 10 s
        // never opened a listen: stock [AV]object cannot decode the
        // positive v2 param, goes mute AND deaf (comm_channel stays 0,
        // guarded), and becomes an immortal corpse no REM can reach.
        // We cannot kill a foreign object - but we can name it, which
        // is what a creator migrating 60 props actually needs.
        llSetTimerEvent(0.0);
        integer n = llGetListLength(PENDING_REZ);
        integer i;
        for (i = 0; i < n; i++)
        {
            Out(0, "WARN: prop '"
                + llList2String(prop_load(llList2Integer(PENDING_REZ, i)), 2)
                + "' did not answer the v2 handshake."
                + " Does it carry [QS]object? (Stock [AV]object cannot"
                + " run under PROP2 ON - remove the rezzed copy by hand.)");
        }
        PENDING_REZ = [];
    }

    listen(integer channel, string name, key id, string message)
    {
        list data = llParseStringKeepNulls(message, ["|"], []);
        // 1.281: hoisted. This field was re-read eleven times below,
        // four of them inside a single condition.
        string cmd = llList2String(data, 0);
        // Reply scoping (0.903): only props WE rezzed are heard. The
        // speaker's OBJECT_REZZER_KEY survives attachment (measured
        // 2026-08-20, rezzerProbe on a worn type-1), so one blanket
        // check covers world and worn replies alike, and it needs no
        // cooperation from the prop - stock [AV]object props pass too.
        // Closes the last channel-collision flank: a colliding furniture's
        // props can no longer write our prop rows via SAVEPROP/QSSAVE*.
        key spk_rezzer = llList2Key(
            llGetObjectDetails(id, [OBJECT_REZZER_KEY]), 0);
        if (spk_rezzer != llList2Key(
            llGetObjectDetails(llGetKey(), [OBJECT_ROOT]), 0))
        {
            // A prop that says DEREZ and dies in the same frame can be
            // gone before the event arrives - details on a dead key are
            // empty, resolving to NULL_KEY. Let exactly that through: a
            // LIVE foreign speaker always has a real rezzer key and
            // stays rejected.
            if (!(spk_rezzer == NULL_KEY && cmd == "DEREZ"))
            {
                return;
            }
        }
        if (cmd == "SAVEPROP")
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
                    prop_update(index, 4, [(string)target_pos, (string)target_rot]);
                    list entry = prop_load(index);
                    string grp = llList2String(entry, 3);
                    if (element(grp, 1) == "QSDYN")
                    {
                        // Internal 90280 attach row: the new offsets are
                        // persisted for re-attach, but the row must never
                        // round-trip into AVpos, so no paste-format line
                        // ([DUMP] skips QSDYN for the same reason).
                        llSay(0, "PROP Saved to memory (internal attach row).");
                    }
                    else
                    {
                        string type = (string)llList2Integer(entry, 1);
                        if (type == "0")
                        {
                            type = "";
                        }
                        string trig = llList2String(entry, 0);
                        string text = "PROP Saved to memory, SITTER " + element(trig, 0) + ": PROP" + type + " " + element(trig, 1) + "|" + name + "|" + element(grp, 1) + "|" + (string)target_pos + "|" + (string)target_rot + "|" + llList2String(entry, 6) + prop_line_suffix(entry);
                        llSay(0, text);
                    }
                }
            }
            else
            {
                Out(0, "ERROR: cannot find prop: " + name);
            }
            return;
        }
        if (cmd == "QSSAVESCALE")
        {
            // [QS]objectadjust replying to the [SAVE]-triggered PROPSEARCH
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
                        prop_update(index, 8, [scl]);
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
        if (cmd == "QSSAVEWORN")
        {
            // [QS]objectadjust on a WORN prop replying to PROPSEARCH with its
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
                        prop_update(index, 9, [wpos, wrot]);
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
        if (cmd == "ATTACHED" || cmd == "DETACHED" || cmd == "REZ" || cmd == "DEREZ")
        {
            integer prop_index = (integer)llList2String(data, 1);
            if (cmd == "REZ")
            {
                // Handshake confirmed - off the wire-2 watchdog list.
                integer pri = llListFindList(PENDING_REZ, [prop_index]);
                if (pri != -1)
                {
                    PENDING_REZ = llDeleteSubList(PENDING_REZ, pri, pri);
                }
            }
            list entry = prop_load(prop_index);
            string trig = llList2String(entry, 0);
            integer sitter = (integer)llList2String(llParseStringKeepNulls(trig, ["|"], []), 0);
            // Slot 99 is the standing operator. Who that is, the session
            // says: [QS]animeshAuthoring holds qs:hud:standing while it
            // runs. Read rather than assumed, because the door honours the
            // Adjust ACL and the operator need not be the owner.
            //
            // No fallback to the owner when the key is gone. A slot-99 prop
            // record outlives its session in LSD, and firing one with no
            // session running means there IS no standing operator - the
            // empty key resolves to NULL_KEY and the ATTACHTO below is
            // suppressed, which is the safe answer. Falling back would hand
            // the prop to whoever happens to own the piece.
            key sitter_key;
            if (sitter == 99) sitter_key = (key)llLinksetDataRead("qs:hud:standing");
            else              sitter_key = llList2Key(SITTERS, sitter);
            if (sitter_key != NULL_KEY && cmd == "REZ" && (integer)llList2String(entry, 1) == 1)
            {
                llSay(comm_channel, "ATTACHTO|" + (string)sitter_key + "|" + (string)id);
            }
            if (cmd == "REZ")
            {
                string postSay = llList2String(entry, 7);
                if (postSay != "")
                {
                    llSay(comm_channel, postSay);
                }
                // Persisted scale factor + worn fit → [QS]objectadjust in the
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
                cmd,
                trig,
                llList2String(entry, 2),
                element(llList2String(entry, 3), 1),
                id
            ], "|"), sitter_key);
            return;
        }
        if (cmd == "NAG" && HAVENTNAGGED && (!llGetAttached()))
        {
            llRegionSayTo(llGetOwner(), 0, "To enable auto-attachments, please enable the experience '" + llList2String(data, 1) + "' in 'About Land'.");
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
            if (command == "PROP2" && llGetListLength(parts) == 1)
            {
                // Wire switch `PROP2 ON` (see header), told apart from
                // a PROP2 prop definition by having no | fields.
                if (llToUpper(llList2String(parts, 0)) == "ON")
                {
                    WIRE = 2;
                    PROP_CAP = 1024;
                }
                // Blank the command so the PROP* block below does not
                // eat the line as a prop definition.
                command = "";
            }
            if (llGetSubString(command, 0, 3) == "PROP")
            {
                // Cap check lives in prop_add now (it reports its own
                // error and returns -1).
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
                integer added = prop_add(
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
                if (added != -1)
                {
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
