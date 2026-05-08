/*
 * [QS]offset - QuickySitter personal-offset store
 *
 * Per-user pose offsets keyed by (pose_name, sitter UUID short prefix).
 * Two storage tiers:
 *
 *   1. LSD QSO:<short>:<pose>  (persistent across script reset / re-rez)
 *      Used when llLinksetDataAvailable() leaves room for at least
 *      LSD_MIN_FREE_POSES more entries (after honoring QPP_CFG:RESERVE
 *      if QuickyHUD's hudprop set one). Keys are written UNPROTECTED:
 *      the proprietary QuickyHUD/QuickyProp LSD_PASS is intentionally
 *      not in this MPL-licensed source. QPP_CFG:* keys (license,
 *      adjustmode, reserve) remain protected by hudproxy/hudprop. Pose
 *      offsets aren't security-sensitive (they're sit positions), so
 *      unprotected reads/writes are acceptable.
 *
 *   2. RAM CUSTOMS list  (volatile fallback, lost on reset)
 *      Used when LSD is too tight or there is no LSD at all (legacy /
 *      stock AVsitter setups). LRU-evicted via cull_to_cap.
 *
 * QSALIVE capability advertised by [QS]sitA: "offsetlsd_v1" — plugins
 * (notably hudproxy's pose-storage migration) gate their behavior on
 * this so a mixed deploy with an older offset.lsl does not lose data.
 *
 * Link-message protocol (paired with [QS]sitA):
 *   90260  offset → sitA   pose_name|pos|rot   (id = sitter UUID)
 *                          "Apply this offset for sitter UUID."
 *   90261  sitA → offset   ""                  (id = sitter UUID)
 *                          "Push this sitter's offsets to me."
 *   90262  sitA → offset   pose_name|pos|rot   (id = sitter UUID)
 *                          "Save this offset." Use the magic name M#T!
 *                          for the [ALL POSES] / [SAVE ALL] flow.
 *   90263  adjuster→offset ""                  (id = pose_name as key)
 *                          "Pose default was overwritten via [HELPER]
 *                          [SAVE] — drop every pose-specific entry that
 *                          matches, regardless of user. M#T! is left
 *                          alone." sitA also handles this for its own
 *                          MY_CUSTOMS cache.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.05";

// LSD storage —————————————————————————————————————————————————————————

// LSD key prefix used for our pose offsets. Stays distinct from
// QuickyHUD/QuickyProp's QPP:* / QPP_CFG:* namespace — those are
// LSD_PASS-protected and we don't have the password.
string LSD_PREFIX = "QSO:";

// QuickyHUD's hudprop (when present) writes the bytes-to-keep-free
// budget here. Reads are unprotected so we can honor it without the
// password. Default: nothing reserved.
string LSD_RESERVE_KEY = "QPP_CFG:RESERVE";

// Conservative per-entry size estimate for the threshold check. Each
// entry is one key (~25 bytes) plus value "<pos>|<rot>" (~40 bytes)
// plus LSD bookkeeping. 80 covers worst-case pose names.
integer LSD_BYTES_PER_ENTRY = 80;

// Use LSD only when at least this many entries still fit. Below it,
// save_offset routes to RAM CUSTOMS so we don't burn the last LSD
// margin on personal offsets.
integer LSD_MIN_FREE_POSES = 200;

// RAM fallback ————————————————————————————————————————————————————————

// Flat list: [pose_name, user_short, pos_offset, rot_offset, ...]
// New entries go at the END; LRU eviction trims from the FRONT.
list CUSTOMS;

// Hard cap on entries. Picked so that 200 × ~150 bytes worst-case
// (long Unicode pose names + list overhead) plus ~12 KB of script
// code/state stays well under Mono's 64 KB cap with ~22 KB headroom.
// The defensive shrink in save_offset is the actual safety net —
// this cap just bounds the steady state.
integer LRU_CAP = 200;

// Below this many bytes free, save_offset evicts aggressively before
// adding the new entry instead of risking Stack-Heap on the `+=`. The
// 100-bytes/entry estimate below LRU_CAP is conservative; this kicks
// in only if reality diverges from estimate (very long pose names,
// other scripts in the prim fragmenting the heap, etc).
integer EMERGENCY_FREE_BYTES = 3000;

// Set to TRUE to enable verbose owner-chat diagnostics on boot and
// emergency-shrink events. Off by default.
integer bDebug = FALSE;

debugSay(string s)
{
    if (bDebug)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + s);
}

// LSD helpers —————————————————————————————————————————————————————————

string lsdMakeKey(key sitter, string pose)
{
    return LSD_PREFIX + llGetSubString(sitter, 0, 7) + ":" + pose;
}

// How many MORE pose entries fit before we hit the reserve floor?
// Negative means we're already past it.
integer lsdRoomLeft()
{
    integer reserved = 0;
    string sRes = llLinksetDataRead(LSD_RESERVE_KEY);
    if (sRes != "") {
        integer r = (integer)sRes;
        if (r > 0) reserved = r;
    }
    integer free = llLinksetDataAvailable() - reserved;
    return free / LSD_BYTES_PER_ENTRY;
}

integer lsdHasRoom()
{
    return (lsdRoomLeft() >= LSD_MIN_FREE_POSES);
}

// RAM helpers —————————————————————————————————————————————————————————

// Drop the oldest entries from the front of CUSTOMS until the list is
// at or under LRU_CAP. Single batch llDeleteSubList — cheaper than
// looping one-at-a-time when many entries need to go.
cull_to_cap()
{
    integer over = llGetListLength(CUSTOMS) / 4 - LRU_CAP;
    if (over > 0)
        CUSTOMS = llDeleteSubList(CUSTOMS, 0, over * 4 - 1);
}

// Defensive: if free memory is below threshold, evict from the front
// until back above threshold (or the list is empty). Loops one entry
// at a time because the per-entry memory recovery isn't predictable
// (varies with pose-name length, list fragmentation), so we can't
// pre-compute the batch size like cull_to_cap.
emergency_shrink()
{
    integer evicted;
    while (llGetFreeMemory() < EMERGENCY_FREE_BYTES
           && llGetListLength(CUSTOMS) > 0)
    {
        CUSTOMS = llDeleteSubList(CUSTOMS, 0, 3);
        ++evicted;
    }
    if (evicted)
        debugSay("Emergency shrink: evicted " + (string)evicted
            + " entries; free=" + (string)llGetFreeMemory()
            + " list=" + (string)(llGetListLength(CUSTOMS) / 4));
}

ramDelete(string short, string pose_name)
{
    integer idx = llListFindList(CUSTOMS, [pose_name, short]);
    if (idx >= 0)
        CUSTOMS = llDeleteSubList(CUSTOMS, idx, idx + 3);
}

// Push helpers ————————————————————————————————————————————————————————

// Send 90260 for every entry in BOTH stores whose user_short matches
// this sitter. LSD wins over RAM if the same pose appears in both
// (saves shouldn't double-write but a stale RAM entry can survive a
// later LSD save that promoted to LSD via lsdHasRoom() flipping).
push_customs_for(key sitter)
{
    string short = llGetSubString(sitter, 0, 7);
    integer pushed_count;

    // Pass 1 — LSD QSO:<short>:* keys.
    string keyPrefix = LSD_PREFIX + short + ":";
    integer prefixLen = llStringLength(keyPrefix);
    list pushed_poses;
    integer offset = 0;
    integer batch = 20;
    do {
        list keys = llLinksetDataFindKeys("^" + keyPrefix, offset, batch);
        integer n = llGetListLength(keys);
        llOwnerSay("[QS]offset[" + version + "] LSD scan offset="
            + (string)offset + " regex=^" + keyPrefix
            + " batch=" + (string)batch + " hits=" + (string)n);
        integer i;
        for (i = 0; i < n; i++) {
            string k = llList2String(keys, i);
            string val = llLinksetDataRead(k);
            llOwnerSay("[QS]offset[" + version + "] LSD key=" + k
                + " val=" + val);
            if (val != "") {
                string poseName = llGetSubString(k, prefixLen, -1);
                llMessageLinked(LINK_THIS, 90260,
                    poseName + "|" + val,
                    sitter);
                ++pushed_count;
                pushed_poses += [poseName];
            }
        }
        if (n < batch) jump lsdScanDone;
        offset += batch;
    } while (TRUE);
    @lsdScanDone;

    // Pass 2 — RAM CUSTOMS, skipping anything already pushed from LSD.
    integer i = 0;
    integer total = llGetListLength(CUSTOMS);
    while (i < total)
    {
        if (llList2String(CUSTOMS, i + 1) == short)
        {
            string poseName = llList2String(CUSTOMS, i);
            if (llListFindList(pushed_poses, [poseName]) == -1)
            {
                llMessageLinked(LINK_THIS, 90260,
                    poseName + "|"
                    + (string)llList2Vector(CUSTOMS, i + 2) + "|"
                    + (string)llList2Vector(CUSTOMS, i + 3),
                    sitter);
                ++pushed_count;
            }
        }
        i += 4;
    }

    llOwnerSay("[QS]offset[" + version + "] push_customs_for sitter="
        + (string)sitter + " short=" + short
        + " pushed=" + (string)pushed_count);
}

// Save / drop —————————————————————————————————————————————————————————

save_offset(key sitter, string pose_name, vector pos, vector rot)
{
    string short = llGetSubString(sitter, 0, 7);

    if (lsdHasRoom())
    {
        // Persistent path. Drop any RAM duplicate so we don't push the
        // stale value alongside the LSD-stored one on next 90261.
        ramDelete(short, pose_name);
        string val = (string)pos + "|" + (string)rot;
        llLinksetDataWrite(lsdMakeKey(sitter, pose_name), val);
        return;
    }

    // RAM fallback path.
    emergency_shrink();
    ramDelete(short, pose_name);
    CUSTOMS += [pose_name, short, pos, rot];
    cull_to_cap();
}

// Drop all entries (LSD + RAM) for this pose_name across all users.
// Used by 90263 after [HELPER] [SAVE] invalidates pose-specific offsets.
// M#T! is never sent here per the adjuster's contract.
drop_pose_all_users(string pose_name)
{
    // LSD: scan for keys ending in ":<pose_name>" (any user_short).
    // We collect first, delete after, to avoid mid-scan reordering.
    string suffix = ":" + pose_name;
    integer suffixLen = llStringLength(suffix);
    list toDelete;
    integer offset = 0;
    integer batch = 20;
    do {
        list keys = llLinksetDataFindKeys("^" + LSD_PREFIX, offset, batch);
        integer n = llGetListLength(keys);
        integer i;
        for (i = 0; i < n; i++) {
            string k = llList2String(keys, i);
            integer kLen = llStringLength(k);
            if (kLen > suffixLen
                && llGetSubString(k, kLen - suffixLen, -1) == suffix)
            {
                toDelete += [k];
            }
        }
        if (n < batch) jump scanDone;
        offset += batch;
    } while (TRUE);
    @scanDone;
    integer j;
    integer m = llGetListLength(toDelete);
    for (j = 0; j < m; j++)
        llLinksetDataDelete(llList2String(toDelete, j));

    // RAM: same as before.
    integer i = 0;
    while (i < llGetListLength(CUSTOMS))
    {
        if (llList2String(CUSTOMS, i) == pose_name)
            CUSTOMS = llDeleteSubList(CUSTOMS, i, i + 3);
        else
            i += 4;
    }
}

default
{
    state_entry()
    {
        debugSay("Ready. LSD room=" + (string)lsdRoomLeft()
            + " poses; RAM cap=" + (string)LRU_CAP
            + "; Free=" + (string)llGetFreeMemory()
            + "; Used=" + (string)llGetUsedMemory());
    }

    on_rez(integer p)
    {
        // RAM CUSTOMS resets when the object rezzes; LSD QSO:* survives.
        llResetScript();
    }

    changed(integer c)
    {
        // CHANGED_OWNER means we're moving to a new account. Personal
        // offsets are tied to sitter UUIDs of *previous* visitors and
        // would be stale at best, surveillance-ish at worst. Wipe both
        // tiers cleanly before resetting.
        if (c & CHANGED_OWNER)
        {
            list toDelete;
            integer offset = 0;
            integer batch = 20;
            do {
                list keys = llLinksetDataFindKeys("^" + LSD_PREFIX, offset, batch);
                integer n = llGetListLength(keys);
                integer i;
                for (i = 0; i < n; i++) toDelete += [llList2String(keys, i)];
                if (n < batch) jump ownerScanDone;
                offset += batch;
            } while (TRUE);
            @ownerScanDone;
            integer j;
            integer m = llGetListLength(toDelete);
            for (j = 0; j < m; j++)
                llLinksetDataDelete(llList2String(toDelete, j));
            llResetScript();
        }
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
        if (num == 90263)
        {
            drop_pose_all_users((string)id);
            return;
        }
    }
}
