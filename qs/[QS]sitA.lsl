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
string version = "1.02";

// Verbose convention: 0=error/warn floor (default), 1=boot banner,
// 2=runtime status, 3=debug. OutForce() bypasses for critical messages.
// Set globally via AVpos `VERBOSE n` → qs:cfg:verbose LSD key (read in
// state_entry below).
integer verbose = 0;
Out(integer level, string msg)
{
    if (verbose >= level)
        llOwnerSay(llGetScriptName() + "[" + version + "] " + msg);
}
OutForce(string msg)
{
    llOwnerSay(llGetScriptName() + "[" + version + "] " + msg);
}
// Derived in state_entry from llGetScriptName() (strip any " N" slot
// suffix). Lets creators rename "[QS]sitA" → "[AV]sitA" etc. without
// touching this file; count loops + QSALIVE-reply use the dynamic
// value.
string main_script;
// Derived in state_entry from main_script (s/sitA/sitB/). Lets renamed
// sitter packs ([FOO]sitA + [FOO]sitB) work without touching this file.
// Removal-detection at changed(CHANGED_INVENTORY) still inventory-probes
// — a deleted script can't broadcast goodbye, so QSALIVE doesn't fit.
string memoryscript;
// helper_object removed in 0.910 — only used by the migrated
// options_menu builder. sitB owns the helper_object inventory probe now.

// Plugin presence (adjuster / faces / select) is not tracked in sitA: the
// consumers (sitB, adjuster) read the qs:alive:* LSD flags on-demand — see
// PROTOCOL.md § qs:alive. has_texture moved to sitB in the 0.910 ADJUST-
// submenu refactor (90203, still LINK_SET-fed). has_security stays here
// because sitA's L1454 dispatch + llPassTouches need it.
integer SCRIPT_CHANNEL;
list SITTERS;
integer SWAPPED;
// Set TRUE when the swap was triggered by a "quiet" sender (90031 =
// QS_SWAP_QUIET, used by [QS]hudadmin SWAP-picker, [QS]hudproxy
// 2-slot quick-swap, [QS]debug stress test). Gates the post-swap menu
// reopen in run_time_permissions so HUD-driven swaps don't stack a
// fresh pose menu on top of whatever the user was looking at. Stays
// FALSE for stock 90030 senders (pose-menu [SWAP], [QS]select seat
// picker) so they keep the stock-AVsitter reopen behavior.
integer bSilentSwap;
key MY_SITTER;
key CONTROLLER;
// ADJUST_MENU global removed in 0.910 — sitB now loads qs:cfg slot 14
// and renders the ADJUST submenu directly. Phase 2 of the sitB-as-UI
// refactor.
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
integer SEQUENCE_POINTER;
vector FIRST_POSITION;
vector FIRST_ROTATION;
vector DEFAULT_POSITION;
vector DEFAULT_ROTATION;
vector CURRENT_POSITION;
vector CURRENT_ROTATION;
integer wrong_primcount;
integer prims;
// Per-sitter RAM-tier mirror pushed by [QS]offset for offsets that
// don't fit in LSD. Layout: [pose_name, pos_diff, rot_diff, ...].
// NOT persisted — volatile by design, fully replaced on sit-down
// (90261 request → 90260 push) and cleared on stand-up + 90265 broadcast.
//
// LSD-tier offsets are NOT mirrored here — sitA reads them directly
// from QSO:<short>:<slot>:<pose> in apply_current_anim. RAM_OVERFLOW
// only carries values that [QS]offset stored in its own RAM (CUSTOMS)
// because LSD was at the floor.
list RAM_OVERFLOW;
integer HASKEYFRAME = FALSE;
integer REFERENCE;
key reused_key;
integer boot_done;
integer my_sittarget;
integer original_my_sittarget;
list SITTERS_SITTARGETS;
list ORIGINAL_SITTERS_SITTARGETS;
integer has_security;
// has_texture migrated to sitB in 0.910 — ADJUST submenu lives there
// now. has_security stays because sitA still needs it for the L1454
// dispatch (90006 vs 90005) and llPassTouches.
integer increment_pointer;
integer pos_rot_adjust_toggle;
integer menu_channel;
integer menu_handle;
integer speed_index;
// SEP = U+FFFD. Initialized at runtime via llUnescapeURL because the
// SL script editor mangles a literal U+FFFD to 0x20 (space) on upload,
// which silently splits anim names containing spaces.
string SEP;

// QuickySitter: notecard parsing + LSD writing moved to [QS]boot.lsl.
// sitA reads its channel's LSD directly via qs_load_from_lsd() — no
// message round-trip during boot. Event-driven since 0.904: state_entry
// runs qs_load_from_lsd() only if qs:meta:<ch> is already there;
// otherwise the QS_BOOT_RELOAD (90023) handler triggers it once boot
// finishes. The boot_done flag (was a dead-code marker before 0.904)
// gates user-facing events so we don't dispatch on stale defaults
// while waiting. sitB's slot-0 changed(CHANGED_LINK) handles pre-boot
// sit-attempts by ejecting the avatar with a chat hint.

qs_load_from_lsd()
{
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
    // Slots 11 (BRAND), 12 (onSit), 13 (CUSTOM_TEXT), 14 (ADJUST_MENU),
    // 15 (RLVDesignations) are read by [QS]sitB direct from the same
    // qs:cfg:N blob — not mirrored here. Saves ~200-400 B steady state
    // and ~1-2 KB transient peak (the CUSTOM_TEXT parse used to be the
    // largest allocation in this loader). sitA has no reader for these
    // strings. ADJUST_MENU joined slot 13 etc. in 0.910 when the ADJUST
    // submenu migrated to sitB.
    GENDERS = [];
    list gp = llCSV2List(llList2String(p, 16));
    integer gj;
    integer gn = llGetListLength(gp);
    for (gj = 0; gj < gn; ++gj)
        GENDERS += (integer)llList2String(gp, gj);

    // Iterate poses; derive FIRST_POSENAME / MALE / FEMALE / FIRST_POSITION etc.
    FIRST_POSENAME = "";
    FIRST_ANIMATION_SEQUENCE = "";
    MALE_POSENAME = "";
    FIRST_MALE_ANIMATION_SEQUENCE = "";
    FEMALE_POSENAME = "";
    FIRST_FEMALE_ANIMATION_SEQUENCE = "";
    FIRST_POSITION = ZERO_VECTOR;
    FIRST_ROTATION = ZERO_VECTOR;
    integer i;
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
    // Wipe + place sit targets. Two layered protections against force-unsitting
    // an already-seated avatar (reseed-while-seated, script-reset-with-resume):
    //   (a) Wipe loop skips occupied seats — clearing a sit target (ZERO)
    //       under a seated avatar unsits them.
    //   (b) sittargets() at its end skips the trailing set_sittarget() call
    //       when MY's sit target is currently occupied — re-placing with a
    //       non-zero value on a seated avatar can also unsit (observed on
    //       reseed-while-seated in 0.9958, which only had (a)). 0.9959 tried
    //       to gate the whole block on boot_done, but the 90024 QS_BOOT_WIPE
    //       handler resets boot_done to FALSE in the reseed window, so that
    //       guard never engaged on a reseed.
    // Empty seats and the initial boot still run the full wipe+place — only
    // occupied seats are spared. Pose-play / swap / reset paths call
    // set_sittarget() directly (not via sittargets()), so their explicit
    // refresh on the occupied seat still works.
    if (!SCRIPT_CHANNEL)
    {
        integer k;
        for (k = 0; k <= llGetNumberOfPrims(); k++)
        {
            if (llAvatarOnLinkSitTarget(k) == NULL_KEY)
            {
                string desc = (string)llGetLinkPrimitiveParams(k, [PRIM_DESC]);
                if (desc != "-1" && "#-1" != llGetSubString(desc, -3, -1))
                    llLinkSitTarget(k, ZERO_VECTOR, ZERO_ROTATION);
            }
        }
    }
    sittargets();
    boot_done = TRUE;

    // Reset-resume: a script reset (Reset Scripts / re-rez / region
    // restart) leaves an avatar physically seated but untracked —
    // changed(CHANGED_LINK) never fired for them, so no 90060 went out
    // and hudproxy's per-sitter listen/JSON was never (re)built, locking
    // the HUD out. If our seat is occupied and we hold no sitter yet,
    // replay the sit: re-request the anim perm (auto-granted for an
    // already-seated avatar, no dialog) and emit 90060 so
    // run_time_permissions resumes the pose and hudproxy reconnects.
    // Pose snaps to FIRST_POSENAME (RAM was wiped); personal offsets
    // return via the 90260 push. Empty-key guard: MY_SITTER is "" until
    // run_time_permissions sets it (standup/reset clear it to "", never
    // NULL_KEY — see L1299), so == "" keeps a 90023 reload (notecard
    // save, no reset) of an already-tracked sitter a no-op.
    if (MY_SITTER == "")
    {
        key resume = llAvatarOnLinkSitTarget(llList2Integer(SITTERS_SITTARGETS, SCRIPT_CHANNEL));
        if (llGetListLength(SITTERS) == 1) resume = llAvatarOnSitTarget();
        if (resume) // OSS::if (osIsUUID(resume) && resume != NULL_KEY)
        {
            // Resume guard: adopt the physically-seated avatar on this slot
            // regardless of gender. A pre-reseed-seated avatar on a slot whose
            // GENDERS doesn't match their body-shape-type would otherwise stay
            // orphaned (no menu, no animation, no HUD) because no new
            // CHANGED_LINK fires for an already-seated avatar on a reseed
            // (qs_load is event-driven, not sit-driven), and auto-assign in
            // changed() only fires on actual sit-events.
            llRequestPermissions(resume, PERMISSION_TRIGGER_ANIMATION);
            llMessageLinked(LINK_SET, 90060, (string)SCRIPT_CHANNEL, resume); // 90060=new sitter
        }
    }

    // QSALIVE boot-announce: plugins that came up before us missed any
    // earlier replies, so emit one unsolicited 90097 once we're done
    // booting. Plugins that came up after us still get an answer via
    // the 90096 probe path. Only slot 0 emits — see qs_alive_reply().
    if (!SCRIPT_CHANNEL) qs_alive_reply();
    Out(1, "Ready, Mem=" + (string)(65536 - llGetUsedMemory()));
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

adjust_pose_menu()
{
    string posrot_button = "Position";
    string value_button = llList2String(["0.05m", "0.25m", "0.01m"], increment_pointer);
    if (pos_rot_adjust_toggle)
    {
        posrot_button = "Rotation";
        value_button = llList2String(["5°", "25°", "1°"], increment_pointer);
    }
    dialog("Personal adjustment:", ["[BACK]", posrot_button, value_button, "[DEFAULT]", "[SAVE]", "[OFFSET ALL]", "X+", "Y+", "Z+", "X-", "Y-", "Z-"]);
}

integer IsInteger(string data)
{
    // This should allow for leading zeros, hence the "1"
    return data != "" && (string)((integer)("1" + data)) == "1" + data;
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
    has_security = FALSE;
    if (!SCRIPT_CHANNEL)
    {
        llMessageLinked(LINK_SET, 90201, "", ""); // 90201=Ask for info about plugins
    }

    // Skip the trailing set_sittarget() when MY sit target is currently
    // occupied — re-placing a non-zero sit target on a seated avatar can
    // force-unsit them (reseed-while-seated, script-reset-with-resume,
    // 90150 cross-channel re-place). Pose-play / swap / reset call
    // set_sittarget() directly for their explicit refresh; this guard only
    // affects the sittargets()-driven refresh, which is non-essential for
    // an already-seated occupant (their existing target stays valid).
    if (llAvatarOnLinkSitTarget(my_sittarget) == NULL_KEY)
        set_sittarget();
}

release_sitter(integer i)
{
    SITTERS = llListReplaceList(SITTERS, [""], i, i);
    if (i == SCRIPT_CHANNEL)
    {
        // 90065 + local cleanup must fire on EVERY standup. On a fast
        // sit-TP or region cross the animation permission is auto-revoked
        // before this runs; bundling the notify inside the perm gate (as
        // stock does) then skips it, orphaning hudproxy's per-sitter
        // listener. The orphan then answers the HUD's region-wide pose
        // broadcast and leaks this furniture's seat labels. Only
        // llStopAnimation actually needs the permission, so only it stays
        // gated.
        if (MY_SITTER) // OSS::if (osIsUUID(MY_SITTER) && MY_SITTER != NULL_KEY)
        {
            llMessageLinked(LINK_SET, 90065, (string)SCRIPT_CHANNEL, MY_SITTER); // 90065=sitter gone
        }
        if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
        {
            if (llGetAgentSize(MY_SITTER) != ZERO_VECTOR && CURRENT_ANIMATION_FILENAME != "")
            {
                llStopAnimation(CURRENT_ANIMATION_FILENAME);
            }
        }
        MY_SITTER = "";
        RAM_OVERFLOW = [];   // drop sitter-specific cache
        llListenRemove(menu_handle);
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

// Manual Re-Sync trigger — see qs/PROTOCOL.md § Re-Sync trigger (90271).
// Convention: SYNC poses are stored without the "P:" prefix; POSE-type
// poses get "P:<name>" by boot's parser. We only re-sync SYNC because
// only multi-avatar SYNC suffers from cross-viewer drift.
integer is_sync_pose()
{
    return CURRENT_POSE_NAME != ""
        && llSubStringIndex(CURRENT_POSE_NAME, "P:") != 0;
}

// Stop+Start the main pose anim across a Sim-frame boundary, forcing
// every viewer to remove the anim and re-add it — the only mechanism
// that re-phases a running loop locally on each viewer. The 50 ms gap
// is just long enough to defeat Sim coalescing (Sim ~45 Hz / 22 ms
// per frame) without lingering long enough for viewers to render the
// gap as a visible "stand-up" flicker. No-op when the gating
// conditions aren't met (e.g. POSE-type pose, no permissions, no
// sitter). Triggered by LinkMsg 90271 from hudproxy or any in-prim
// source. See TESTPLAN TC-029 for the iteration history that landed
// on the HUD-owned manual-trigger model.
do_resync_tick()
{
    if (!is_sync_pose()) return;
    if (!(llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)) return;
    if (llGetAgentSize(MY_SITTER) == ZERO_VECTOR) return;
    if (CURRENT_ANIMATION_FILENAME == "") return;
    llStopAnimation(CURRENT_ANIMATION_FILENAME);
    llSleep(0.05);
    llStartAnimation(CURRENT_ANIMATION_FILENAME);
}

// Single-source-of-truth lookup for this sitter's personal offset on the
// given pose name. LSD wins (persistent tier, read direct via the
// documented QSO:<short>:<slot>:<pose> convention — see PROTOCOL.md).
// RAM_OVERFLOW is the fallback for the rare case where [QS]offset
// stored the value in its own RAM (CUSTOMS) because LSD was at the
// floor — those values arrive via 90260 push.
//
// Returns [pos_offset, rot_offset] (two-element list) on hit, empty
// list on miss. Caller is responsible for the M#T! fallback semantics
// (specific pose wins over global) by calling this twice if needed.
list lookup_personal_offset(string pose_name)
{
    string short = llGetSubString(MY_SITTER, 0, 7);
    string lsdKey = "QSO:" + short + ":" + (string)SCRIPT_CHANNEL + ":" + pose_name;
    string val = llLinksetDataRead(lsdKey);
    if (val != "") {
        // LSD-tier hit. Value format is "<pos>|<rot>" (vector strings).
        list parts = llParseString2List(val, ["|"], []);
        return [(vector)llList2String(parts, 0),
                (vector)llList2String(parts, 1)];
    }
    integer ri = llListFindList(RAM_OVERFLOW, [pose_name]);
    if (ri >= 0) {
        // RAM-tier hit (offset.lsl pushed it via 90260 because LSD was full).
        return [llList2Vector(RAM_OVERFLOW, ri + 1),
                llList2Vector(RAM_OVERFLOW, ri + 2)];
    }
    return [];
}

apply_current_anim(integer broadcast)
{
    SEQUENCE_POINTER = 0;
    update_current_anim_name();
    CURRENT_POSITION = DEFAULT_POSITION;
    CURRENT_ROTATION = DEFAULT_ROTATION;
    // Apply this sitter's personal offset. SSoT lives in [QS]offset:
    // LSD QSO:<short>:<slot>:<pose> for the persistent tier (read direct
    // here, no cache), RAM_OVERFLOW for the rare RAM-tier values pushed
    // via 90260 when LSD was at the floor. Pose-specific entries always
    // win over M#T! (the all-poses fallback), regardless of tier.
    list off = lookup_personal_offset(CURRENT_POSE_NAME);
    if (llGetListLength(off) == 0)
        off = lookup_personal_offset("M#T!");
    if (llGetListLength(off) == 2)
    {
        CURRENT_POSITION += llList2Vector(off, 0);
        CURRENT_ROTATION += llList2Vector(off, 1);
    }
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
    llSetLinkPrimitiveParamsFast(sitter_prim, [PRIM_ROT_LOCAL, llEuler2Rot((CURRENT_ROTATION + <0,0,0.002>) * DEG_TO_RAD) * localrot, PRIM_POS_LOCAL, CURRENT_POSITION * localrot + localpos]);
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
        // Pick up the boot-written verbose level before any Out() call.
        string vstr = llLinksetDataRead("qs:cfg:verbose");
        if (vstr != "") verbose = (integer)vstr;
        // Derive own basename — strip the " N" slot suffix if present.
        // Used by the count loops below + get_number_of_scripts() so the
        // hardcoded "[QS]sitA" goes away (creator-renamed scripts still
        // work as long as all sitA copies share the same basename).
        main_script = llGetScriptName();
        integer space = llSubStringIndex(main_script, " ");
        if (space != -1)
            main_script = llGetSubString(main_script, 0, space - 1);
        // Derive paired sitB basename via s/sitA/sitB/ on main_script.
        // KeepNulls so a leading/trailing "sitA" doesn't drop empty fields.
        memoryscript = llDumpList2String(llParseStringKeepNulls(main_script, ["sitA"], []), "sitB");
        // Mixed-prefix compat — a creator pack might mix prefixes for
        // AVsitter plugin discovery (e.g. [AV]sitA + [QS]sitB so stock
        // [AV]faces / [AV]camera find sitter slots via [AV]sitA N probes).
        // The s/sitA/sitB/ derivation above only works when both halves
        // share a prefix; scan inventory for any "sitB" script when the
        // derived name misses.
        if (llGetInventoryType(memoryscript) != INVENTORY_SCRIPT)
        {
            integer iScan = llGetInventoryNumber(INVENTORY_SCRIPT);
            while (iScan-- > 0)
            {
                string sname = llGetInventoryName(INVENTORY_SCRIPT, iScan);
                if (llSubStringIndex(sname, "sitB") != -1)
                {
                    integer sp = llSubStringIndex(sname, " ");
                    if (sp != -1) sname = llGetSubString(sname, 0, sp - 1);
                    memoryscript = sname;
                    jump scanDone;
                }
            }
            @scanDone;
        }
        SCRIPT_CHANNEL = (integer)llGetSubString(llGetScriptName(), llSubStringIndex(llGetScriptName(), " "), 99999);
        // Install-time sitB-wait dropped in 0.283 (same fix boot got in
        // 0.025). The LSD-meta wait below covers the "boot is ready"
        // sanity check; the changed(CHANGED_INVENTORY) sibling check
        // resets the script if sitB appears/disappears later.
        integer i;
        while (llGetInventoryType(main_script + " " + (string)(++i)) == INVENTORY_SCRIPT)
            ;
        while (i--)
            SITTERS += "";
        if (SCRIPT_CHANNEL)
            memoryscript += " " + (string)SCRIPT_CHANNEL;

        // Event-driven boot. If boot's already done seeding this channel,
        // load now. Otherwise just return — link_message will dispatch
        // qs_load_from_lsd() when boot broadcasts QS_BOOT_RELOAD (90023).
        // No sleep-loop, so the furniture stays event-responsive even
        // before boot finishes (sitB slot-0 ejects pre-boot sit attempts).
        boot_done = FALSE;
        if (llLinksetDataRead("qs:meta:" + (string)SCRIPT_CHANNEL) != "")
            qs_load_from_lsd();
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
        // ADJUST submenu rendering + ADJUST_MENU notecard dispatch + builtin
        // catch-all (TEXTURE/FACES/SECURITY/HELPER/QUICKYHUD/[BACK]→90005)
        // all migrated to sitB in 0.910 (Phase 2 sitB-as-UI refactor). This
        // listen handler is now only triggered by sitA's own dialog() calls
        // — currently only adjust_pose_menu (Position/Rotation/X+/Y+/Z+/…)
        // and the [OFFSET ALL] confirmation sub-dialog.
        integer index = llListFindList(["Position", "Rotation", "X+", "Y+", "Z+", "X-", "Y-", "Z-", "0.05m", "0.25m", "0.01m", "5°", "25°", "1°"], [msg]);
        if (msg == "[BACK]")
        {
            llMessageLinked(LINK_SET, 90005, "", (string)CONTROLLER + "|" + (string)MY_SITTER); // 90005=send menu to user
        }
        else if (msg == "[DEFAULT]")
        {
            CURRENT_POSITION = DEFAULT_POSITION;
            CURRENT_ROTATION = DEFAULT_ROTATION;
            sit_using_prim_params();
            adjust_pose_menu();
        }
        else if (msg == "[OFFSET ALL]")
        {
            dialog("Save personal position offset for all poses?", ["[BACK]", "[ALL POSES]"]);
        }
        else if (msg == "[ALL POSES]")
        {
            vector pd = CURRENT_POSITION - DEFAULT_POSITION;
            vector rd = CURRENT_ROTATION - DEFAULT_ROTATION;
            // Persist to [QS]offset (SSoT). Don't touch RAM_OVERFLOW
            // here — offset.lsl owns the storage decision and pushes
            // 90260 back if it landed in RAM tier; LSD-tier saves
            // are read direct by apply_current_anim on next pose.
            // adjust_pose_menu doesn't re-apply, so there's no race
            // window where the user would land at DEFAULT.
            llMessageLinked(LINK_THIS, 90262, (string)SCRIPT_CHANNEL + "|M#T!|" + (string)pd + "|" + (string)rd, MY_SITTER);
            adjust_pose_menu();
            // Gated confirmation: when [QS]offset is missing the 90262
            // above goes into the void and nothing is persisted. The
            // `qs:offset:alive` LSD flag is owned by [QS]offset (state_entry
            // write); boot's CENSUS wipes it on a plugin add/remove, so a
            // removed offset.lsl leaves it cleared. See PROTOCOL.md § qs:alive.
            if (llLinksetDataRead("qs:offset:alive") == "1")
                llRegionSayTo(id, 0, "Personal offset saved for all poses.");
            else
                llRegionSayTo(id, 0, "Personal offset storage not installed - position not saved.");
        }
        else if (msg == "[SAVE]")
        {
            vector pd = CURRENT_POSITION - DEFAULT_POSITION;
            vector rd = CURRENT_ROTATION - DEFAULT_ROTATION;
            // Persist to [QS]offset (SSoT). See [ALL POSES] note above
            // for why we don't pre-populate RAM_OVERFLOW.
            llMessageLinked(LINK_THIS, 90262, (string)SCRIPT_CHANNEL + "|" + CURRENT_POSE_NAME + "|" + (string)pd + "|" + (string)rd, MY_SITTER);
            adjust_pose_menu();
            // See [ALL POSES] branch above for the gated-confirmation
            // rationale.
            if (llLinksetDataRead("qs:offset:alive") == "1")
                llRegionSayTo(id, 0, "Personal position saved for this pose.");
            else
                llRegionSayTo(id, 0, "Personal offset storage not installed - position not saved.");
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
    }

    link_message(integer sender, integer num, string msg, key id)
    {
        // Boot-done broadcast from [QS]boot.finalize_boot. Triggers the
        // Boot wipe signal (90024 QS_BOOT_WIPE) — notecard re-save
        // invalidated the seeded LSD. Drop boot_done so the
        // !boot_done guards re-engage; sitB slot-0 handles the
        // actual sit-eject loop. finalize_boot will fire QS_BOOT_RELOAD
        // again once the re-seed completes and we wake up via the
        // 90023 handler below.
        if (num == 90024)   // QS_BOOT_WIPE
        {
            boot_done = FALSE;
            return;
        }
        // initial load when boot finishes after our state_entry, or
        // re-load after a notecard save. Always processed even when
        // !boot_done so the wake-up path works.
        if (num == 90023)   // QS_BOOT_RELOAD
        {
            qs_load_from_lsd();
            return;
        }
        // Gate the rest until LSD is populated — pre-boot dispatches
        // would run on default-zeroed globals (MTYPE=0, empty pose list,
        // etc.) and emit nonsense menus / mis-positioned sits.
        if (!boot_done) return;
        integer one = (integer)msg;
        integer two = (integer)((string)id);
        integer target;
        list data;
        // 90303 handler removed — sitA reads settings from LSD directly via
        // qs_load_from_lsd() now (called from state_entry or 90023 handler).
        if (num == 90260 && id == MY_SITTER)
        {
            // RAM-tier mirror push from [QS]offset for the avatar on this
            // sitter. Payload is pose_name|<pos_diff>|<rot_diff>. Post-SSoT-
            // refactor this only carries values that [QS]offset stored in
            // its own RAM (CUSTOMS) because LSD was at the floor —
            // LSD-tier offsets are read direct by apply_current_anim and
            // never pushed via 90260.
            //
            // ZERO/ZERO payload is the delete sentinel — [QS]offset emits
            // this when save_offset cleaned both tiers (user adjusted back
            // to default and saved). We must drop the RAM_OVERFLOW entry
            // to prevent ghost-application after the underlying LSD/RAM
            // store was already cleared.
            list mp = llParseStringKeepNulls(msg, ["|"], []);
            string pname = llList2String(mp, 0);
            vector pdiff = (vector)llList2String(mp, 1);
            vector rdiff = (vector)llList2String(mp, 2);
            integer mi = llListFindList(RAM_OVERFLOW, [pname]);
            if (mi >= 0) RAM_OVERFLOW = llDeleteSubList(RAM_OVERFLOW, mi, mi + 2);
            if (pdiff == ZERO_VECTOR && rdiff == ZERO_VECTOR) {
                // Delete sentinel — entry already removed above, nothing
                // else to do (no insert, no race-fix re-apply since we
                // didn't add a new offset to apply).
                return;
            }
            RAM_OVERFLOW += [pname, pdiff, rdiff];

            // Late-arrival race fix (RAM-tier only post-refactor): on
            // re-sit, run_time_permissions fires 90261 (request RAM-tier
            // push) and 90000 (play pose) back-to-back. The 90000
            // round-trips through sitB → 90055 → apply_current_anim,
            // which checks LSD direct (synchronous, no race) AND
            // RAM_OVERFLOW. If RAM_OVERFLOW was empty at that moment
            // (90260 hadn't arrived yet) and the LSD lookup also missed,
            // CURRENT lands on DEFAULT_POSITION even though the RAM-tier
            // offset is on its way. When that 90260 arrives here, re-run
            // the canonical lookup and re-apply if CURRENT still equals
            // DEFAULT. Mid-session adjustments shift CURRENT away from
            // DEFAULT and break the equality check, so they're not
            // overridden.
            if (CURRENT_POSITION == DEFAULT_POSITION
                && CURRENT_ROTATION == DEFAULT_ROTATION)
            {
                list off = lookup_personal_offset(CURRENT_POSE_NAME);
                if (llGetListLength(off) == 0)
                    off = lookup_personal_offset("M#T!");
                if (llGetListLength(off) == 2)
                {
                    CURRENT_POSITION = DEFAULT_POSITION
                        + llList2Vector(off, 0);
                    CURRENT_ROTATION = DEFAULT_ROTATION
                        + llList2Vector(off, 1);
                    sit_using_prim_params();
                }
            }
            return;
        }
        if (num == 90265)
        {
            // CLEAR-broadcast invalidation paired with 90264. [QS]offset
            // wiped both LSD QSO:* and its own CUSTOMS — sitA's LSD-direct
            // reads are auto-correct (LSD entries are gone), but the
            // RAM_OVERFLOW mirror needs explicit clearing because no
            // individual push tells us about deletes from CUSTOMS.
            // Broadcast on LINK_SET so every sitA slot in the linkset
            // clears in lockstep.
            RAM_OVERFLOW = [];
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
                integer mi = llListFindList(RAM_OVERFLOW, [pname]);
                if (mi >= 0) RAM_OVERFLOW = llDeleteSubList(RAM_OVERFLOW, mi, mi + 2);
            }
            return;
        }
        if (num == 90096) // 90096=QSALIVE probe; only slot-0 sitA replies (90097)
        {
            if (SCRIPT_CHANNEL == 0) qs_alive_reply();
            return;
        }
        // faces / adjuster presence is published to qs:alive:* LSD flags
        // (PROTOCOL.md § qs:alive), read on-demand by sitB/adjuster — sitA
        // neither receives nor caches presence. The former 90090/90091
        // HELLO broadcasts were retired in 0.9951.
        if (num == 90271) // 90271=Re-Sync trigger from hudproxy (or any in-prim source)
        {
            do_resync_tick();
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
        if (num == 90030 || num == 90031) // 90030=swap (stock+select, with reopen); 90031=quiet swap (HUD+debug, no reopen)
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
                    // Per-swap flag for the menu-reopen gate; reset on
                    // consumption in run_time_permissions.
                    bSilentSwap = (num == 90031);
                    llRequestPermissions(reused_key, PERMISSION_TRIGGER_ANIMATION);
                }
                // Clear MY_SITTER only on the slots actually involved in
                // the swap — run_time_permissions will re-set it once
                // the new occupant grants animation permissions. Slots
                // not involved keep their MY_SITTER intact, otherwise
                // any later 90055 from sitB would fail apply_current_anim's
                // llGetAgentSize(MY_SITTER) check and the avatar would
                // freeze on its current pose. Pre-fix the wipe was
                // unconditional — visible as "SYNC pose change only
                // affects one sitter" after a swap-to-self via the
                // seat picker.
                MY_SITTER = "";
            }
            // 0.9968: gate physical re-mapping on REAL 2-sitter swap.
            // For 1-sitter swap (the typical "manual SWAP to put one sitter
            // on the other slot's pose", e.g. user clicks SWAP while alone
            // on a couple to land on the opposite-gender slot), the physical
            // SITTERS_SITTARGETS swap + set_sittarget cause:
            //   1) sitA[other_slot]'s new my_sittarget points to the OCCUPIED
            //      prim; set_sittarget overwrites that prim's sit-target
            //      with wrong-slot pose-offsets (slot-1's M-offsets on the
            //      slot-0 prim, etc.).
            //   2) sitA[swap_initiator]'s new my_sittarget points to the
            //      EMPTY prim; set_sittarget there places wrong-slot offsets
            //      on it — when a 2nd sitter clicks, SL seats them with
            //      mis-aligned pose-offsets, or refuses the sit-target
            //      entirely if the computed position is invalid.
            //   3) Net: 2nd sitter can't physically sit on the empty prim
            //      → no CHANGED_LINK → no auto-assign → no adoption → no menu.
            // The logical SITTERS swap below is sufficient to move ownership
            // from sitA[N] to sitA[M] for the 1-sitter case. Sit-targets
            // stay at their natural per-slot offsets; the new prim's sitter
            // physics work normally.
            // For TRUE 2-sitter swap (both slots occupied, mutual exchange),
            // physical re-mapping IS intended (stock-AVsitter semantics)
            // since each sitter needs to "trade places" — keep the original
            // logic for that case.
            key bothA = llList2Key(SITTERS, one);
            key bothB = llList2Key(SITTERS, two);
            if (bothA != NULL_KEY && bothB != NULL_KEY)
            {
                SITTERS_SITTARGETS = llListReplaceList(llListReplaceList(SITTERS_SITTARGETS, [llList2Integer(SITTERS_SITTARGETS, two)], one, one), [llList2Integer(SITTERS_SITTARGETS, one)], two, two);
                my_sittarget = llList2Integer(SITTERS_SITTARGETS, SCRIPT_CHANNEL);
                set_sittarget();
            }
            // Swap SITTERS instead of clearing both slots. The original
            // stock code sets [empty, empty] and lets run_time_permissions
            // re-register each occupant; CHANGED_LINK fires in between
            // (sit-target update from set_sittarget triggers it once
            // perms grant) and the auto-assign in our changed() handler
            // sees the avatar not in SITTERS and re-claims it on the
            // first empty slot — typically slot 0 — which then races
            // with the swap-target slot's run_time_permissions and
            // ends with both slots claiming the same avatar. Visible as
            // the wrong sit-position (apply_current_anim picks slot 0's
            // offset, sit_using_prim_params on slot 0 then writes to
            // the avatar's prim using slot 0's localrot/localpos basis,
            // resulting in a position that matches slot 1's DEFAULT).
            // Swapping SITTERS up front means CHANGED_LINK already finds
            // the avatar registered on the destination slot.
            key swapA = llList2Key(SITTERS, one);
            key swapB = llList2Key(SITTERS, two);
            SITTERS = llListReplaceList(llListReplaceList(SITTERS, [swapB], one, one), [swapA], two, two);
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
        // 90203 (has_texture) receiver removed in 0.910 — moved to sitB
        // with the ADJUST submenu migration. has_texture was unused in
        // sitA outside the inlined options_menu builder anyway.
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
                msg = llList2String(data, 1);
                // [ADJUST] submenu rendering migrated to sitB in 0.910 —
                // sitB's link_message 90101[ADJUST] handler now renders
                // it. The [POSE] handoff below is the bridge back to
                // adjust_pose_menu, whose Position/Rotation math is
                // still sitA-owned (CURRENT_POSITION + sit_using_prim_params).
                if (msg == "[POSE]")
                {
                    adjust_pose_menu();
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
            // Pre-boot: ignore link changes here entirely. SITTERS, GENDERS,
            // SET etc. are still default-zeroed; running the assignment
            // logic below would mis-route avatars. sitB slot-0 handles
            // pre-boot sit attempts by ejecting + chat-hinting the user.
            //
            // 0.9961: gate on `prims` instead of `boot_done`. boot_done is
            // RESET to FALSE on 90024 QS_BOOT_WIPE, so during the reseed
            // window a force-unsit's CHANGED_LINK was swallowed silently —
            // SITTERS / MY_SITTER stayed stale, the changed handler never
            // ran release_sitter, and on re-sit the SET-branch saw the slot
            // as still-occupied (same UUID), skipped the new-sitter path,
            // never emitted 90070, sitB's MY_SITTER stayed "", and touch
            // was silently dropped by the data[-1]==MY_SITTER check.
            // `prims` is set once in sittargets() (Z.324) on the FIRST load
            // and never reset — exactly the "truly pre-initial-boot" marker
            // we need. boot_done's Z.909 link_message gate stays unchanged:
            // there it correctly means "LSD is currently invalid".
            if (!prims) return;
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
                        // Empty-slot detection via manual scan with llList2String:
                        // stock's `llListFindList(SITTERS, [""])` is type-strict
                        // and only matches "" (string) elements. After a SWAP,
                        // llListReplaceList with [swapB=llList2Key(empty)] inserts
                        // key("") (empty key, NOT NULL_KEY which has the
                        // "00000000-..." UUID), so subsequent llListFindList for
                        // [""] returns -1 and the 2nd sitter never gets adopted
                        // (fa stays -1, no SCRIPT_CHANNEL match). llList2String
                        // catches both representations because (string)key("") = ""
                        // via the key's value.
                        integer first_available = -1;
                        integer k;
                        for (k = 0; k < llGetListLength(SITTERS) && first_available == -1; k++)
                        {
                            if (llList2String(SITTERS, k) == "")
                                first_available = k;
                        }
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
                            // 0.9962: gate on boot_done. The 0.9961 prims-gate
                            // above re-enabled the changed handler during the
                            // seed phase (so a force-unsit's CHANGED_LINK can
                            // clear stale SITTERS) — but we MUST NOT trigger
                            // run_time_permissions while LSD is still seeding:
                            // sitB's 90005 auto-open would render animation_menu
                            // against an empty sidecar (qs:nm:0:-1 == "" →
                            // total_items=0 → only [Adjust] visible). sitB:947
                            // still ejects the pre-boot sit-attempt. The release
                            // path above stays ungated so 0.9961's stale-cleanup
                            // keeps working.
                            if (boot_done)
                            {
                                llRequestPermissions(llGetLinkKey(i), PERMISSION_TRIGGER_ANIMATION);
                                llMessageLinked(LINK_SET, 90060, (string)SCRIPT_CHANNEL, llGetLinkKey(i)); // 90060=new sitter
                            }
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
                            // See release_sitter: notify + cleanup must run
                            // on every standup, not only while the animation
                            // permission is still held. Only llStopAnimation
                            // stays gated.
                            if (MY_SITTER) // OSS::if (osIsUUID(MY_SITTER) && MY_SITTER != NULL_KEY)
                            {
                                llMessageLinked(LINK_SET, 90065, (string)SCRIPT_CHANNEL, MY_SITTER); // 90065=sitter gone
                            }
                            if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION)
                            {
                                if (llGetAgentSize(MY_SITTER) != ZERO_VECTOR && CURRENT_ANIMATION_FILENAME != "")
                                {
                                    // Stock used (integer)CURRENT_ANIMATION_FILENAME
                                    // which casts any anim name to 0 → llStopAnimation
                                    // was silently skipped in this branch.
                                    llStopAnimation(CURRENT_ANIMATION_FILENAME);
                                }
                            }
                            MY_SITTER = "";
                            llListenRemove(menu_handle);
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
                            // 0.9962: see auto-assign branch comment above —
                            // gate new-sitter perm-request on boot_done so the
                            // seed-phase sit-attempt doesn't trigger an empty
                            // animation_menu via 90005 auto-open.
                            if (boot_done)
                            {
                                llRequestPermissions(actual_sitter, PERMISSION_TRIGGER_ANIMATION);
                                llMessageLinked(LINK_SET, 90060, (string)SCRIPT_CHANNEL, actual_sitter); // 90060=new sitter
                            }
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
                has_security = FALSE;
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
                has_security = FALSE;
                if (!SCRIPT_CHANNEL)
                {
                    llMessageLinked(LINK_SET, 90201, "", ""); // 90201=Ask for info about plugins
                }
            }
        }
        if (change & CHANGED_INVENTORY)
        {
            // Reset i: CHANGED_LINK loops above may have left it at
            // llGetListLength(SITTERS), which would make ++i probe past
            // the last slot and trip a false-positive self-reset when
            // CHANGED_LINK | CHANGED_INVENTORY fire together.
            i = 0;
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
            RAM_OVERFLOW = [];
            llMessageLinked(LINK_THIS, 90261, (string)SCRIPT_CHANNEL, MY_SITTER);
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
            else if (!MTYPE && !bSilentSwap)
            {
                // Stock-AVsitter reopen path (since 0.9912 gated on
                // bSilentSwap): close + reopen the pose menu after the
                // perm-grant for stock 90030 senders (pose-menu [SWAP]
                // click, [QS]select seat picker), but stay quiet for
                // 90031 (QS_SWAP_QUIET) senders ([QS]hudadmin SWAP-
                // picker, [QS]hudproxy quick-swap, [QS]debug stress).
                // The HUD paths use external dialogs that already give
                // the user feedback on their action; thrusting a fresh
                // pose menu on top would stack windows in viewers that
                // don't auto-replace cross-script dialogs.
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
            // Consume the silent-swap flag whether we reopened or not.
            bSilentSwap = FALSE;
        }
    }

    // dataserver event removed — [QS]boot.lsl owns notecard parsing now.
}
