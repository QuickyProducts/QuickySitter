/*
 * [QS]offset - QuickySitter personal-offset store
 *
 * Per-(user, slot, pose_name) offsets. Two storage tiers:
 *
 *   1. LSD QSO:<short>:<slot>:<pose>  (persistent across script reset
 *      and re-rez). Used when llLinksetDataAvailable() leaves room for
 *      at least LSD_MIN_FREE_POSES more entries (after honoring
 *      QPP_CFG:RESERVE if QuickyHUD's hudprop set one). Keys are
 *      written UNPROTECTED: the proprietary QuickyHUD/QuickyProp
 *      LSD_PASS is intentionally not in this MPL-licensed source.
 *      QPP_CFG:* keys (license, adjustmode, reserve) remain protected
 *      by hudproxy/hudprop. Pose offsets aren't security-sensitive
 *      (they're sit positions), so unprotected reads/writes are
 *      acceptable.
 *
 *   2. RAM CUSTOMS list  (volatile fallback, lost on reset)
 *      Used when LSD is too tight or there is no LSD at all (legacy /
 *      stock AVsitter setups). LRU-evicted via cull_to_cap.
 *
 * Why slot in the key: SYNC couple poses share a pose name across
 * multiple slots, but each slot has its own DEFAULT (sit-target offset
 * relative to root). A user can adjust + save independently per slot
 * — slot 0's saved offset is relative to slot 0's DEFAULT, slot 1's
 * is relative to slot 1's DEFAULT — and SWAP preserves both. The
 * earlier flat (user, pose) key model overwrote one save with the
 * other.
 *
 * QSALIVE capability advertised by [QS]sitA: "offsetlsd_v1" — plugins
 * (notably hudproxy's pose-storage migration) gate their behavior on
 * this so a mixed deploy with an older offset.lsl does not lose data.
 *
 * Link-message protocol (paired with [QS]sitA):
 *   90260  offset → sitA   pose_name|pos|rot       (id = sitter UUID)
 *                          "Apply this offset for sitter UUID on the
 *                          slot the receiver belongs to (the push was
 *                          already slot-filtered by 90261's request)."
 *   90261  sitA → offset   (string)slot            (id = sitter UUID)
 *                          "Push this (sitter, slot) pair's offsets to
 *                          me." Sent by run_time_permissions on sit
 *                          and by hudproxy on pose change.
 *   90262  sitA → offset   slot|pose_name|pos|rot  (id = sitter UUID)
 *                          "Save this offset for (sitter, slot, pose)."
 *                          The magic name M#T! is the [ALL POSES] /
 *                          [OFFSET ALL] all-poses fallback; each slot
 *                          can have its own M#T! offset.
 *   90263  adjuster→offset (string)slot            (id = pose_name)
 *                          "[HELPER] [SAVE] just rewrote pose default
 *                          on this slot — drop every pose-specific
 *                          entry on this slot that matches the pose
 *                          name. M#T! survives." sitA also handles
 *                          this for its own MY_CUSTOMS cache.
 *   90264  hudproxy→offset ""                      (id ignored)
 *                          "Wipe ALL personal offsets — every user's
 *                          QSO:* LSD entries and the entire RAM
 *                          CUSTOMS list." Triggered by the HUD
 *                          settings menu "CLEAR offset storage"
 *                          confirm.
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "1.02";

// Presence: [QS]offset owns the qs:offset:alive LSD flag directly (written
// in state_entry, re-written on QS_ALIVE_CENSUS). [QS]sitA reads it to gate
// personal-offset confirmations; hudproxy reads it cross-repo. The key name
// stays qs:offset:alive (not qs:alive:offset) precisely because hudproxy in
// the HUD repo already reads it. See qs/PROTOCOL.md § qs:alive.
integer QS_ALIVE_CENSUS = 90079;

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

// Flat list: [pose_name, user_short, slot, pos_offset, rot_offset, ...]
// New entries go at the END; LRU eviction trims from the FRONT.
// Stride is 5 — anything iterating CUSTOMS uses i += 5 / mod 5.
list CUSTOMS;
integer CUSTOMS_STRIDE = 5;

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

// Verbose convention: 0=error/warn floor (default), 1=boot banner,
// 2=runtime status, 3=debug. OutForce() bypasses for critical messages.
// Set globally via AVpos `VERBOSE n` → qs:cfg:verbose LSD key (read in
// state_entry below). Replaces the previous bDebug/debugSay scheme.
integer verbose = 0;

Out(integer level, string s)
{
    if (verbose >= level)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + s);
}
OutForce(string s)
{
    llOwnerSay(llGetScriptName() + "[" + version + "] " + s);
}

// LSD helpers —————————————————————————————————————————————————————————

string lsdMakeKey(key sitter, integer slot, string pose)
{
    return LSD_PREFIX + llGetSubString(sitter, 0, 7) + ":"
         + (string)slot + ":" + pose;
}

string lsdMakePrefix(key sitter, integer slot)
{
    return LSD_PREFIX + llGetSubString(sitter, 0, 7) + ":"
         + (string)slot + ":";
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
    integer over = llGetListLength(CUSTOMS) / CUSTOMS_STRIDE - LRU_CAP;
    if (over > 0)
        CUSTOMS = llDeleteSubList(CUSTOMS, 0, over * CUSTOMS_STRIDE - 1);
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
        CUSTOMS = llDeleteSubList(CUSTOMS, 0, CUSTOMS_STRIDE - 1);
        ++evicted;
    }
    if (evicted)
        Out(0, "WARN: emergency shrink — evicted " + (string)evicted
            + " entries; free=" + (string)llGetFreeMemory()
            + " list=" + (string)(llGetListLength(CUSTOMS) / CUSTOMS_STRIDE));
}

// Find a CUSTOMS entry matching (pose, short, slot). Returns the head
// index of the entry or -1. Walks at stride to avoid spurious matches
// across record boundaries (llListFindList on a sub-pattern can match
// inside another entry if pose names happen to collide).
integer ramFind(string short, integer slot, string pose_name)
{
    integer i = 0;
    integer n = llGetListLength(CUSTOMS);
    while (i < n)
    {
        if (llList2String(CUSTOMS, i)     == pose_name
         && llList2String(CUSTOMS, i + 1) == short
         && llList2Integer(CUSTOMS, i + 2) == slot)
            return i;
        i += CUSTOMS_STRIDE;
    }
    return -1;
}

ramDelete(string short, integer slot, string pose_name)
{
    integer idx = ramFind(short, slot, pose_name);
    if (idx >= 0)
        CUSTOMS = llDeleteSubList(CUSTOMS, idx, idx + CUSTOMS_STRIDE - 1);
}

// Push helpers ————————————————————————————————————————————————————————

// Send 90260 for every RAM-tier entry matching (sitter, slot).
// Post-SSoT-refactor: LSD-tier offsets are NOT pushed — sitA reads them
// directly via llLinksetDataRead in apply_current_anim. We only mirror
// the RAM tier into sitA's session-local RAM_OVERFLOW, because sitA
// can't see RAM tier without a push (it's not in LSD by definition).
// Slot filter ensures each sitA's per-instance RAM_OVERFLOW only ever
// contains its own slot's data, so apply_current_anim's lookup needs
// no slot awareness on the receiver side.
push_customs_for(key sitter, integer slot)
{
    string short = llGetSubString(sitter, 0, 7);

    integer i = 0;
    integer total = llGetListLength(CUSTOMS);
    while (i < total)
    {
        if (llList2String(CUSTOMS, i + 1) == short
         && llList2Integer(CUSTOMS, i + 2) == slot)
        {
            llMessageLinked(LINK_THIS, 90260,
                llList2String(CUSTOMS, i) + "|"
                + (string)llList2Vector(CUSTOMS, i + 3) + "|"
                + (string)llList2Vector(CUSTOMS, i + 4),
                sitter);
        }
        i += CUSTOMS_STRIDE;
    }
}

// Save / drop —————————————————————————————————————————————————————————

// Stock-AVsitter "[OFFSET ALL]" semantics. When sitA's [ALL POSES] confirm
// arrives via 90262 with pose_name "M#T!", mirror stock's behavior: wipe
// all per-pose entries for this (sitter, slot) first, then let the caller
// write the new M#T! entry. Without this, pre-existing per-pose entries
// (HUD-saved on pose change, or sitA [SAVE] earlier) keep winning over
// M#T! in sitA's apply_current_anim lookup, defeating the "all poses"
// intent — [OFFSET ALL] would only apply to never-adjusted poses.
//
// Equivalent stock code in [AV]sitA.lsl:
//   while (i > 0) { if (CUSTOMS[i] == short) delete; i -= 4; }
//   CUSTOMS += ["M#T!", short, pd, rd];
//
// We split that into a wipe step + a normal save_offset call, so the
// existing ZERO/ZERO RAM_OVERFLOW invalidation path is reused for each
// purged RAM-tier entry. Skips the M#T! key itself — caller overwrites
// (or deletes via ZERO/ZERO branch) immediately after.
wipe_per_pose_for_sitter_slot(key sitter, integer slot)
{
    string short = llGetSubString(sitter, 0, 7);
    string keyPrefix = LSD_PREFIX + short + ":" + (string)slot + ":";
    string mtKey = keyPrefix + "M#T!";

    // LSD: scan for our prefix, collect for batched delete (avoid mid-
    // scan reordering). Skip M#T! itself.
    list toDelete;
    integer scanOff = 0;
    integer batch = 20;
    do {
        list keys = llLinksetDataFindKeys("^" + keyPrefix, scanOff, batch);
        integer n = llGetListLength(keys);
        integer i;
        for (i = 0; i < n; i++) {
            string k = llList2String(keys, i);
            if (k != mtKey) toDelete += [k];
        }
        if (n < batch) jump scanDone;
        scanOff += batch;
    } while (TRUE);
    @scanDone;
    integer j;
    integer m = llGetListLength(toDelete);
    for (j = 0; j < m; j++)
        llLinksetDataDelete(llList2String(toDelete, j));

    // RAM: walk CUSTOMS at stride, drop matching (short, slot) except
    // M#T!. Send ZERO/ZERO 90260 for each dropped pose_name so sitA's
    // RAM_OVERFLOW drops its cached entry too (same sentinel convention
    // as the delete branch in save_offset below).
    integer i = 0;
    while (i < llGetListLength(CUSTOMS))
    {
        if (llList2String(CUSTOMS, i + 1) == short
         && llList2Integer(CUSTOMS, i + 2) == slot
         && llList2String(CUSTOMS, i) != "M#T!")
        {
            string pname = llList2String(CUSTOMS, i);
            CUSTOMS = llDeleteSubList(CUSTOMS, i, i + CUSTOMS_STRIDE - 1);
            llMessageLinked(LINK_THIS, 90260,
                pname + "|" + (string)ZERO_VECTOR + "|" + (string)ZERO_VECTOR,
                sitter);
        }
        else
        {
            i += CUSTOMS_STRIDE;
        }
    }
    update_ram_tier_count();
}

save_offset(key sitter, integer slot, string pose_name, vector pos, vector rot)
{
    string short = llGetSubString(sitter, 0, 7);

    // ZERO/ZERO is the delete sentinel — sitA's [SAVE] (when the user has
    // dialed all adjustments back to base), hudproxy's poseBufPush, and
    // hudproxy's resetPos all converge on this when there's nothing
    // meaningful to store (or when explicitly deleting). Cleans up both
    // tiers AND notifies sitA's RAM_OVERFLOW to drop any matching entry
    // — without this, a stale RAM_OVERFLOW value from a previous RAM-tier
    // save would survive the LSD/CUSTOMS delete and keep applying via
    // apply_current_anim's RAM fallback.
    //
    // Convention: 90260 with ZERO/ZERO payload is the "remove from
    // RAM_OVERFLOW" signal, distinct from non-zero values which insert.
    //
    // Targeted M#T! deletion: the [OFFSET ALL] per-pose wipe lives in the
    // non-zero branch below, so a ZERO/ZERO M#T! delete clears only the
    // all-poses entry without disturbing other poses' saved offsets.
    // hudproxy's resetPos (>= 0.911) relies on this to wipe M#T! alongside
    // the current pose entry on "RESET pose to default position".
    if (pos == ZERO_VECTOR && rot == ZERO_VECTOR)
    {
        ramDelete(short, slot, pose_name);
        llLinksetDataDelete(lsdMakeKey(sitter, slot, pose_name));
        llMessageLinked(LINK_THIS, 90260,
            pose_name + "|" + (string)ZERO_VECTOR + "|" + (string)ZERO_VECTOR,
            sitter);
        update_ram_tier_count();
        return;
    }

    // [OFFSET ALL] non-zero arrival — wipe per-pose entries first so M#T!
    // becomes effective (stock semantics: setting M#T! supersedes per-pose).
    // Then fall through to the normal write below for M#T! itself. See
    // wipe_per_pose_for_sitter_slot header for the stock-semantics
    // rationale.
    if (pose_name == "M#T!")
        wipe_per_pose_for_sitter_slot(sitter, slot);

    if (lsdHasRoom())
    {
        // Persistent path. Drop any RAM duplicate so we don't double-store.
        // sitA reads LSD direct on next apply, no push needed.
        ramDelete(short, slot, pose_name);
        string val = (string)pos + "|" + (string)rot;
        llLinksetDataWrite(lsdMakeKey(sitter, slot, pose_name), val);
        update_ram_tier_count();
        return;
    }

    // RAM fallback path. Push to sitA's RAM_OVERFLOW immediately so the
    // value is visible to apply_current_anim — sitA can't see CUSTOMS
    // without a push (it only direct-reads LSD).
    emergency_shrink();
    ramDelete(short, slot, pose_name);
    CUSTOMS += [pose_name, short, slot, pos, rot];
    cull_to_cap();
    llMessageLinked(LINK_THIS, 90260,
        pose_name + "|" + (string)pos + "|" + (string)rot,
        sitter);
    update_ram_tier_count();
}

// Mirror the current RAM-tier entry count to QPP_CFG:RAM_TIER_COUNT
// (unprotected) so hudproxy's getStorageReport can show users how many
// offsets are RAM-only (i.e., would be lost on a script reset). Called
// from every CUSTOMS-mutating path. Empty list writes "0".
update_ram_tier_count()
{
    integer count = llGetListLength(CUSTOMS) / CUSTOMS_STRIDE;
    llLinksetDataWrite("QPP_CFG:RAM_TIER_COUNT", (string)count);
}

// Wipe both tiers entirely. Used by CHANGED_OWNER (visitor offsets
// shouldn't follow the prim to a new account) and by 90264 from the
// HUD's "CLEAR offset storage" button. Caller is responsible for
// confirmation prompts; the wipe itself is unconditional.
//
// The 90265 broadcast invalidates every sitA's RAM_OVERFLOW mirror
// — without it, sitA would keep applying RAM-tier offsets that
// CUSTOMS no longer contains (the LSD-tier wipe is auto-visible
// because sitA reads LSD direct, but RAM_OVERFLOW is push-driven
// and needs explicit invalidation).
wipe_all_offsets()
{
    list toDelete;
    integer offset = 0;
    integer batch = 20;
    do {
        list keys = llLinksetDataFindKeys("^" + LSD_PREFIX, offset, batch);
        integer n = llGetListLength(keys);
        integer i;
        for (i = 0; i < n; i++) toDelete += [llList2String(keys, i)];
        if (n < batch) jump scanDone;
        offset += batch;
    } while (TRUE);
    @scanDone;
    integer j;
    integer m = llGetListLength(toDelete);
    for (j = 0; j < m; j++)
        llLinksetDataDelete(llList2String(toDelete, j));
    CUSTOMS = [];
    llMessageLinked(LINK_SET, 90265, "", NULL_KEY);
    update_ram_tier_count();
}

// Drop all entries (LSD + RAM) for this (slot, pose_name) across all
// users. Used by 90263 after [HELPER] [SAVE] invalidates pose-specific
// offsets on a single slot. M#T! is never sent here per the adjuster's
// contract.
drop_pose_for_slot(integer slot, string pose_name)
{
    // LSD: scan for keys ending in ":<slot>:<pose_name>" (any
    // user_short). We collect first, delete after, to avoid mid-scan
    // reordering.
    string suffix = ":" + (string)slot + ":" + pose_name;
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

    // RAM: walk at stride and delete matching entries.
    integer i = 0;
    while (i < llGetListLength(CUSTOMS))
    {
        if (llList2String(CUSTOMS, i) == pose_name
         && llList2Integer(CUSTOMS, i + 2) == slot)
            CUSTOMS = llDeleteSubList(CUSTOMS, i, i + CUSTOMS_STRIDE - 1);
        else
            i += CUSTOMS_STRIDE;
    }
    update_ram_tier_count();
}

default
{
    state_entry()
    {
        // Pick up the boot-written verbose level before any Out() call.
        string vstr = llLinksetDataRead("qs:cfg:verbose");
        if (vstr != "") verbose = (integer)vstr;
        // Reset the RAM-tier counter — CUSTOMS is empty post-state-entry,
        // and we want hudproxy's storage report to reflect that until the
        // first save_offset bumps it.
        update_ram_tier_count();
        // Authoritative presence write: as long as this script is alive,
        // `qs:offset:alive` is "1". sitA reads it directly to gate its
        // "Personal offset saved..." confirmations; hudproxy reads it
        // cross-repo. Removal is detected by boot's CENSUS — it wipes the
        // flag, and a removed offset can't re-write it. See PROTOCOL.md.
        llLinksetDataWrite("qs:offset:alive", "1");
        Out(1, "Ready. LSD room=" + (string)lsdRoomLeft()
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
            wipe_all_offsets();
            llResetScript();
        }
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QS_ALIVE_CENSUS)
        {
            // boot wiped presence (plugin add/remove, or re-seed / full
            // LSD reset) — re-publish ours. This is the sole re-stamp path
            // now that the QS_OFFSET_HELLO broadcast is gone. See
            // PROTOCOL.md § qs:alive.
            llLinksetDataWrite("qs:offset:alive", "1");
            return;
        }
        if (num == 90261)
        {
            // msg = (string)slot
            push_customs_for(id, (integer)msg);
            return;
        }
        if (num == 90262)
        {
            // msg = slot|pose_name|pos|rot
            list parts = llParseStringKeepNulls(msg, ["|"], []);
            save_offset(id,
                (integer)llList2String(parts, 0),
                llList2String(parts, 1),
                (vector)llList2String(parts, 2),
                (vector)llList2String(parts, 3));
            return;
        }
        if (num == 90263)
        {
            // msg = (string)slot, id = pose_name (cast to key)
            drop_pose_for_slot((integer)msg, (string)id);
            return;
        }
        if (num == 90264)
        {
            wipe_all_offsets();
            return;
        }
    }
}
