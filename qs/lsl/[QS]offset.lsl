/*
 * [QS]offset - QuickySitter personal-offset store
 *
 * Holds per-user CUSTOMS (pose offsets) in volatile memory only. Per the
 * QuickySitter offset rule (see memory/project_offset_design.md): user
 * offsets NEVER touch LSD. They live here, get pushed to [QS]sitA on sit,
 * and evict LRU-style when the cap is reached.
 *
 * Link-message protocol (paired with [QS]sitA):
 *   90260  offset → sitA   pose_name|pos|rot   (id = sitter UUID)
 *                          "Apply this offset for sitter UUID."
 *   90261  sitA → offset   ""                  (id = sitter UUID)
 *                          "Push this sitter's customs to me."
 *   90262  sitA → offset   pose_name|pos|rot   (id = sitter UUID)
 *                          "Save this offset." Use the magic name M#T!
 *                          for the [ALL POSES] / [SAVE ALL] flow.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "qs1";

// Flat list: [pose_name, user_short, pos_offset, rot_offset, ...]
// New entries go at the END; LRU eviction trims from the FRONT.
list CUSTOMS;

// Soft cap on number of entries before eviction kicks in. Computed from
// free memory at boot; AVsitter uses a similar (free-5000)/100 heuristic.
integer LRU_CAP;

cull_to_cap()
{
    while (llGetListLength(CUSTOMS) / 4 > LRU_CAP && llGetListLength(CUSTOMS) > 0)
    {
        CUSTOMS = llDeleteSubList(CUSTOMS, 0, 3);
    }
}

// Send 90260 for every entry whose user_short matches this sitter.
push_customs_for(key sitter)
{
    string short = llGetSubString(sitter, 0, 7);
    integer i = 0;
    integer n = llGetListLength(CUSTOMS);
    while (i < n)
    {
        if (llList2String(CUSTOMS, i + 1) == short)
        {
            llMessageLinked(LINK_THIS, 90260,
                  llList2String(CUSTOMS, i) + "|"
                + (string)llList2Vector(CUSTOMS, i + 2) + "|"
                + (string)llList2Vector(CUSTOMS, i + 3),
                sitter);
        }
        i += 4;
    }
}

save_offset(key sitter, string pose_name, vector pos, vector rot)
{
    string short = llGetSubString(sitter, 0, 7);
    // Splice out any prior entry for this (pose_name, user_short).
    integer idx = llListFindList(CUSTOMS, [pose_name, short]);
    if (idx >= 0)
        CUSTOMS = llDeleteSubList(CUSTOMS, idx, idx + 3);
    // Append at the tail = most-recently-used.
    CUSTOMS += [pose_name, short, pos, rot];
    cull_to_cap();
}

default
{
    state_entry()
    {
        LRU_CAP = (llGetFreeMemory() - 5000) / 100;
        if (LRU_CAP < 10) LRU_CAP = 10;
        llOwnerSay(llGetScriptName() + "[" + version + "] Ready. CUSTOMS cap=" + (string)LRU_CAP + " entries. Mem=" + (string)(65536 - llGetUsedMemory()));
    }

    on_rez(integer p)
    {
        // Volatile by design — CUSTOMS resets when the object rezzes.
        llResetScript();
    }

    changed(integer c)
    {
        if (c & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == 90261)
        {
            push_customs_for(id);
            return;
        }
        if (num == 90262)
        {
            list parts = llParseStringKeepNulls(msg, ["|"], []);
            save_offset(id,
                llList2String(parts, 0),
                (vector)llList2String(parts, 1),
                (vector)llList2String(parts, 2));
            return;
        }
    }
}
