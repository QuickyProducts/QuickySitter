/*
 * [QS]select - QuickySitter seat-select menu
 *
 * Fork of [AV]select from AVsitter2 (MPL 2.0). Four functional changes
 * vs stock:
 *   1. Sitter count comes from the QSALIVE handshake (90096/90097)
 *      instead of llGetInventoryType("[AV]sitA <n>") probes; stock
 *      probes by literal script name which fails against the [QS]sitA
 *      runtime name.
 *   2. Notecard parsing replaced with on-demand LSD reads. Boot has
 *      already parsed the AVpos contents into qs:cfg / qs:sitter / qs:p
 *      keys — re-parsing the whole notecard here costs minutes on
 *      multi-thousand-pose stress decks. state_entry calls
 *      load_from_lsd() immediately if qs:meta:0 is already there;
 *      otherwise the QS_BOOT_RELOAD (90023) link_message dispatches it
 *      once boot finishes. Same event-driven pattern as sitA 0.904 /
 *      sitB 0.905 — no sleep-poll.
 *   3. Empty/duplicate seat labels keep the "Sitter N" default (0.9953);
 *      stock overwrites it with the first pose name. Pose names as
 *      seat-picker buttons are confusing, so the fallback was dropped.
 *   4. menu() self-heals SITTERS (0.9954/0.9955): occupants no longer seated
 *      on this linkset (missed 90065) AND duplicate listings of one avatar
 *      across seats (missed clear on a seat-move) are dropped before render;
 *      90070 also dedupes on claim. Every avatar shows in exactly one seat.
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Original work: Copyright © the AVsitter Contributors
 * AVsitter™ is a trademark. For trademark use policy see:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string product = "QuickySitter™ seat select";
string version = "1.0";
integer select_type;
list BUTTONS;

// QSALIVE — sitter-count cache (replaces the legacy
// llGetInventoryType("[QS]sitA " + i) loop). See qs/PROTOCOL.md § QSALIVE.
// Fallback default 7 is a sensible upper bound until slot-0 sitA replies.
integer QSALIVE_PROBE = 90096;
integer QSALIVE_REPLY = 90097;
integer qs_alive = FALSE;
integer qs_sitter_count_cached = 1;

// Presence is published to the qs:alive:select LSD flag (written in
// state_entry, re-written on QS_ALIVE_CENSUS). sitB's select_present()
// reads it on-demand; the legacy [AV]select inventory probe stays in
// sitB as a stock-AVsitter backward-compat fallback. See PROTOCOL.md
// § qs:alive.
integer QS_ALIVE_CENSUS = 90079;

// QS_BOOT_RELOAD — broadcast by [QS]boot at the end of its seed cascade.
// Triggers a fresh load_from_lsd() so a notecard re-save doesn't require
// a manual reset to pick up the new BUTTONS / menu_type / select_type.
integer QS_BOOT_RELOAD = 90023;

// SEP must match the U+FFFD separator that [QS]boot uses when packing
// SITTER_INFO into qs:sitter:<ch>. Initialized at runtime via
// llUnescapeURL because the SL script editor mangles a literal U+FFFD
// to 0x20 (space) on upload.
string SEP;

string CUSTOM_TEXT;
list SITTERS;
list SYNCS = [CUSTOM_TEXT]; //OSS::list SYNCS; // Force error in LSO
integer menu_channel;
integer menu_handle;
integer menu_type;
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

string strReplace(string str, string search, string replace)
{
    return llDumpList2String(llParseStringKeepNulls(str, [search], []), replace);
}

list order_buttons(list buttons)
{
    return llList2List(buttons, -3, -1) + llList2List(buttons, -6, -4) + llList2List(buttons, -9, -7) + llList2List(buttons, -12, -10);
}

menu(key av)
{
    integer sitter_index = llListFindList(SITTERS, [av]);
    if (sitter_index != -1)
    {
        // 0.9954/0.9955: self-heal SITTERS before rendering. SL drops
        // link/standup events (region crossings, TP-outs, script-time
        // throttling), so a missed 90065/90030 can (a) leave a vacated avatar
        // in SITTERS — a ghost name — or (b) leave an avatar double-listed
        // across seats after a seat-move. The viewer (av) is seated here, so
        // its OBJECT_ROOT is this furniture's root; clear any occupant whose
        // root differs (gone/elsewhere) OR who already appeared in an earlier
        // slot, so every avatar shows in exactly one seat. key("")/NULL_KEY
        // empties skipped via the string guard (feedback_lsl_list_empty_slot_polymorphism).
        key this_root = llList2Key(llGetObjectDetails(av, [OBJECT_ROOT]), 0);
        if (this_root != av)   // av genuinely seated on a linkset (root != self)
        {
            list seen;
            integer sj;
            for (sj = 0; sj < llGetListLength(SITTERS); ++sj)
            {
                string occ = llList2String(SITTERS, sj);
                if (occ != "" && occ != (string)NULL_KEY)
                {
                    if (llList2Key(llGetObjectDetails((key)occ, [OBJECT_ROOT]), 0) != this_root
                        || llListFindList(seen, [occ]) != -1)
                        SITTERS = llListReplaceList(SITTERS, [NULL_KEY], sj, sj);
                    else
                        seen += occ;
                }
            }
        }
        list menu_buttons;
        integer i;
        for (i = 0; i < llGetListLength(BUTTONS); i++)
        {
            string avname = llKey2Name(llList2Key(SITTERS, i));
            if ((select_type == 0 && llList2Integer(SYNCS, i) == FALSE || select_type == 2) && avname != "" && av != llList2Key(SITTERS, i))
            {
                menu_buttons += "⊘" + llGetSubString(strReplace(avname, " Resident", " "), 0, 11);
            }
            else
            {
                menu_buttons += llList2String(BUTTONS, i);
            }
        }
        while ((llGetListLength(menu_buttons) + 1) % 3)
        {
            menu_buttons += " ";
        }
        menu_buttons += "[ADJUST]";
        llListenControl(menu_handle, TRUE);
        llDialog(av, product + " " + version + "\n\n" + CUSTOM_TEXT + "[" + llList2String(BUTTONS, sitter_index) + "]", order_buttons(menu_buttons), menu_channel);
    }
}
integer get_number_of_scripts()
{
    if (qs_alive) return qs_sitter_count_cached;
    return 7;  // pre-QSALIVE-reply fallback — sensible upper bound.
}

// Resize SITTERS / SYNCS / BUTTONS to the cached count. Preserves
// existing entries when growing (NULL_KEY / FALSE / "Sitter N" for
// new slots) and trims only the tail when shrinking — keeps the
// LSD-derived BUTTONS labels intact across QSALIVE-reply-driven
// resizes during boot.
init_lists()
{
    // Use get_number_of_scripts() so the 7-fallback applies before
    // the QSALIVE_REPLY arrives — otherwise state_entry pre-sizes
    // to qs_sitter_count_cached's default (1), the load_from_lsd
    // pass drops SITTER 1+ slots, and the late grow appends
    // "Sitter N" defaults instead of the LSD-supplied labels.
    integer count = get_number_of_scripts();
    if (count < 1) count = 1;
    while (llGetListLength(SITTERS) > count)
    {
        SITTERS = llDeleteSubList(SITTERS, -1, -1);
        SYNCS   = llDeleteSubList(SYNCS,   -1, -1);
        BUTTONS = llDeleteSubList(BUTTONS, -1, -1);
    }
    integer i = llGetListLength(SITTERS);
    while (i < count)
    {
        SITTERS += NULL_KEY;
        SYNCS   += FALSE;
        BUTTONS += "Sitter " + (string)i;
        i++;
    }
}

// first_pose_name() removed in 0.9953 — the seat-picker no longer falls back
// to a pose name for empty/duplicate seat labels (see load_from_lsd).

// Populate menu_type / select_type / CUSTOM_TEXT / BUTTONS from LSD
// keys that [QS]boot wrote during its seed cascade. Replaces the
// previous notecard-read pass — boot has already parsed AVpos, no
// reason to re-parse it here. Also re-publishes qs:select:btn:<i>
// so [QS]hudproxy picks up the freshest slot labels.
load_from_lsd()
{
    // Global config — see qs_cfg_pack in [QS]boot for the field order.
    string cfg = llLinksetDataRead("qs:cfg:0");
    list p = llParseStringKeepNulls(cfg, ["\n"], []);
    menu_type   = (integer)llList2String(p, 0);
    select_type = (integer)llList2String(p, 4);
    string ctext = llList2String(p, 13);
    if (ctext != "")
        CUSTOM_TEXT = llDumpList2String(llParseStringKeepNulls(ctext, ["\\n"], []), "\n") + "\n";
    else
        CUSTOM_TEXT = "";

    // Per-sitter button labels.
    integer count = llGetListLength(SITTERS);
    integer ch;
    for (ch = 0; ch < count; ++ch)
    {
        string info = llLinksetDataRead("qs:sitter:" + (string)ch);
        list info_fields = llParseStringKeepNulls(info, [SEP], []);
        string button_text = llList2String(info_fields, 0);

        if (button_text != "" && llListFindList(BUTTONS, [button_text]) == -1)
        {
            BUTTONS = llListReplaceList(BUTTONS, [button_text], ch, ch);
        }
        // 0.9953: empty or duplicate seat label keeps the init_lists
        // "Sitter N" default. Deliberate divergence from stock [AV]select,
        // which overwrites it with the first pose name here — pose names as
        // seat-picker buttons are confusing.
    }

    // Publish BUTTONS to LSD so [QS]hudproxy can use the notecard-
    // derived names ("Male", "Female", …) for empty-slot labels in
    // the SWAP dialog instead of generic "Sitter N". Hudproxy reads
    // qs:select:btn:<i> by slot index; stale entries past the
    // current count are harmless (hudproxy iterates 0..iSlots-1).
    integer n = llGetListLength(BUTTONS);
    integer i;
    for (i = 0; i < n; ++i)
    {
        llLinksetDataWrite("qs:select:btn:" + (string)i, llList2String(BUTTONS, i));
    }
}

default
{
    state_entry()
    {
        SEP = llUnescapeURL("%EF%BF%BD");
        menu_channel = ((integer)llFrand(0x7FFFFF80) + 1) * -1; // 7FFFFF80 = max float < 2^31
        menu_handle = llListen(menu_channel, "", "", "");
        llListenControl(menu_handle, FALSE);
        // QSALIVE probe — slot-0 sitA replies with the real count.
        // init_lists pre-sizes via get_number_of_scripts() (returns
        // 7 until qs_alive flips); the reply handler re-runs it once
        // we know the actual count and shrinks the tail.
        qs_alive = FALSE;
        // Pick up the boot-written verbose level before any Out() call.
        string v = llLinksetDataRead("qs:cfg:verbose");
        if (v != "") verbose = (integer)v;
        llMessageLinked(LINK_SET, QSALIVE_PROBE, "", "");
        // Publish presence to LSD, read on-demand by sitB's
        // select_present(). See PROTOCOL.md § qs:alive.
        llLinksetDataWrite("qs:alive:select", "1");
        init_lists();
        // Event-driven boot — same pattern as [QS]sitA 0.904 /
        // [QS]sitB 0.905. If boot already seeded qs:meta:0, load now;
        // otherwise just return and let QS_BOOT_RELOAD (90023) dispatch
        // load_from_lsd() once boot finishes. No sleep-poll, so the
        // script stays event-responsive even before boot lands.
        if (llLinksetDataRead("qs:meta:0") != "")
        {
            load_from_lsd();
            Out(1, "Ready");
        }
        else
        {
            Out(2, "Loading...");
        }
    }
    listen(integer listen_channel, string name, key id, string message)
    {
        integer av_index = llListFindList(SITTERS, [id]);
        integer button_index = llListFindList(BUTTONS, [message]);
        if (av_index != -1)
        {
            if (message == "[ADJUST]" || message == "[HELPER]" || message == "[QUICKYHUD]")
            {
                // [QUICKYHUD] is sitA's hudproxy-gated entry into
                // ADJUSTMODE. Adjuster opens its own submenu with
                // [ADJUST OFF] / [BACK] from there.
                llMessageLinked(LINK_SET, 90101, llDumpList2String(["X", message, id], "|"), id);
            }
            // 0.9956: revert the 0.9952 llList2String change — it was wrong
            // for [QS]select and broke swapping onto empty slots. Unlike
            // [QS]sitA (where empty slots are "" string or key("") after a
            // llListReplaceList swap), [QS]select stores empty slots as
            // NULL_KEY EVERYWHERE: init_lists pads with NULL_KEY, and the
            // 90030/90065/security/dedup handlers all clear to NULL_KEY (never
            // "" or key("")). So the original `llList2Key(...) != NULL_KEY`
            // correctly identifies an empty slot here, while llList2String !=
            // "" reads NULL_KEY's "00000000-..." form as non-empty → every
            // empty slot looked occupied → the picker re-rendered instead of
            // dispatching the 90030 swap (the "pick a seat, avatar doesn't
            // move" bug). The polymorphism caveat applies to sitA's mixed
            // ""/key("") lists, NOT to select's uniformly-NULL_KEY list.
            else if (llGetSubString(message, 0, 0) == "⊘" || (select_type == 0 && llList2Integer(SYNCS, button_index) == FALSE && llList2Key(SITTERS, button_index) != NULL_KEY && llList2Key(SITTERS, button_index) != id))
            {
                menu(id);
            }
            else if (button_index != -1)
            {
                llMessageLinked(LINK_SET, 90030, (string)av_index, (string)button_index);
            }
        }
    }
    changed(integer change)
    {
        if (change & CHANGED_LINK)
        {
            if (llGetAgentSize(llGetLinkKey(llGetNumberOfPrims())) == ZERO_VECTOR)
            {
                llListenControl(menu_handle, FALSE);
            }
        }
        // CHANGED_INVENTORY handling removed: boot's own changed handler
        // resets + re-seeds on notecard swap, then broadcasts 90023.
        // We pick the new state up via QS_BOOT_RELOAD below — no
        // independent notecard-key tracking needed.
    }
    link_message(integer sender, integer num, string msg, key id)
    {
        if (num == QS_ALIVE_CENSUS)
        {
            // boot wiped presence on a plugin add/remove — re-publish ours.
            llLinksetDataWrite("qs:alive:select", "1");
            return;
        }
        if (num == QSALIVE_REPLY)
        {
            // Slot-0 sitA reports the real sitter count. Resize the
            // tracking lists if needed (preserves existing entries).
            list d = llParseString2List(msg, ["|"], []);
            if (llList2String(d, 0) == "QuickySitter")
            {
                integer new_count = (integer)llList2String(d, 2);
                qs_alive = TRUE;
                if (new_count != qs_sitter_count_cached)
                {
                    qs_sitter_count_cached = new_count;
                    init_lists();
                }
            }
            return;
        }
        if (num == QS_BOOT_RELOAD)
        {
            // Boot finished seeding (initial boot or notecard re-save).
            // Loads / refreshes BUTTONS, menu_type, select_type,
            // CUSTOM_TEXT from the just-written LSD. Doubles as the
            // event-driven wake-up for state_entry's "boot not ready
            // yet" branch.
            load_from_lsd();
            Out(1, "Ready");
            return;
        }
        if (sender == llGetLinkNumber())
        {
            if (num == 90055)
            {
                list data = llParseStringKeepNulls(id, ["|"], []);
                if (llGetSubString(llList2String(data, 0), 0, 1) != "P:")
                {
                    SYNCS = llListReplaceList(SYNCS, [TRUE], (integer)msg, (integer)msg);
                }
                else
                {
                    SYNCS = llListReplaceList(SYNCS, [FALSE], (integer)msg, (integer)msg);
                }
            }
            else if (num == 90065)
            {
                integer index = llListFindList(SITTERS, [id]);
                if (index != -1)
                {
                    SITTERS = llListReplaceList(SITTERS, [NULL_KEY], index, index);
                }
            }
            else if (num == 90030)
            {
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)msg, (integer)msg);
                SITTERS = llListReplaceList(SITTERS, [NULL_KEY], (integer)((string)id), (integer)((string)id));
            }
            else if (num == 90070)
            {
                // 0.9955: dedupe on claim. A missed 90065/90030 on a prior
                // seat can leave this avatar in an old slot; clear every slot
                // still holding them before claiming msg, so they never show
                // in two seats at once. Read-before-check (no assign-in-cond).
                integer dupe = llListFindList(SITTERS, [id]);
                while (dupe != -1)
                {
                    SITTERS = llListReplaceList(SITTERS, [NULL_KEY], dupe, dupe);
                    dupe = llListFindList(SITTERS, [id]);
                }
                SITTERS = llListReplaceList(SITTERS, [id], (integer)msg, (integer)msg);
            }
            else if (num == 90009)
            {
                menu(id);
            }
        }
    }
}
