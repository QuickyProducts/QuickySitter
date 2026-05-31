/*
 * [QS]debug - QuickySitter LSD inspector
 *
 * Drop into a QuickySitter prim. Owner-only chat commands on /88
 * (e.g. "/88 help") inspect and manipulate the qs:* Linkset Data
 * keys. Output goes to owner via llOwnerSay. Safe to leave in;
 * harmless if not used.
 *
 * Commands:
 *   help                    list commands
 *   keys [pattern]          list qs:* keys (or matching regex)
 *   count <ch>              pose count for channel
 *   meta <ch>               show qs:meta:<ch>
 *   cfg <ch>                show qs:cfg:<ch>
 *   sitter <ch>             show qs:sitter:<ch>
 *   pose <ch> <i>           show qs:p:<ch>:<i> with parsed fields
 *   poses <ch>              dump all poses for channel
 *   raw <key>               show raw value of any qs:* key
 *   mem                     show LSD memory usage
 *   nuke                    wipe ALL Linkset Data (with confirmation)
 *   nuke yes                actually wipe (no further confirmation)
 *   delch <ch>              delete all qs:*:<ch> keys for one channel
 *
 * MPL 2.0. Original work © the AVsitter Contributors. Trademark policy:
 * https://avsitter.github.io/TRADEMARK.mediawiki
 */

string version = "0.999";
integer chan = 88;
integer listen_handle;
integer LSD_TOTAL_BYTES = 131072;  // 128 KB linkset cap

// === STRESS TEST STATE ===
//
// Fires synthetic sitter LinkMsg traffic to stress hudproxy and the
// downstream sitA/sitB/offset chain. Phases: RAMP (sitter joins, one
// per tick), CHAOS (random pose changes / swaps / saves), CLEANUP
// (90065 each, one per tick). UUIDs from llGenerateKey, so each run
// exercises a fresh keyspace in offset.lsl's QSO:<short>:* keys.
//
// Note: if [QS]debug is reset mid-stress, fake sitters orphan in
// hudproxy's sJsonSitters and consume listen slots. Reset hudproxy
// (or the prim) to recover.
integer STRESS_IDLE    = 0;
integer STRESS_RAMP    = 1;
integer STRESS_CHAOS   = 2;
integer STRESS_CLEANUP = 3;
integer stress_state;
integer stress_count;
list    stress_sitters;
integer stress_ops;
float   stress_tick    = 0.5;
list    stress_poses   = ["P:Sit", "P:Lounge", "Cuddle", "Hug",
                          "Hold", "Spoon", "Kiss", "Embrace", "M#T!"];

show_help()
{
    llOwnerSay(
        "\n[QS]debug — chat /" + (string)chan + " <cmd>:\n"
      + "  help                  this list\n"
      + "  keys [pattern]        list qs:* keys (regex optional)\n"
      + "  count <ch>            pose count for channel\n"
      + "  meta <ch>             show qs:meta:<ch>\n"
      + "  cfg <ch>              show qs:cfg:<ch>\n"
      + "  sitter <ch>           show qs:sitter:<ch>\n"
      + "  pose <ch> <i>         show qs:p:<ch>:<i> parsed\n"
      + "  poses <ch>            dump all poses for channel\n"
      + "  grep <text>           find all qs:p:* whose value contains <text>\n"
      + "  raw <key>             show raw value of any key\n"
      + "  mem                   LSD bytes used / free\n"
      + "  delch <ch>            delete all qs:*:<ch> keys\n"
      + "  nuke / nuke yes       wipe ALL Linkset Data\n"
      + "  stress {start|stop|status|speed}  hudproxy stress test");
}

cmd_keys(string pattern)
{
    if (pattern == "") pattern = "^qs:";
    integer start = 0;
    integer batch = 256;
    integer total = 0;
    while (TRUE)
    {
        list keys = llLinksetDataFindKeys(pattern, start, batch);
        integer n = llGetListLength(keys);
        if (n == 0) jump done;
        integer i;
        for (i = 0; i < n; ++i)
        {
            llOwnerSay("  " + llList2String(keys, i));
        }
        total += n;
        if (n < batch) jump done;
        start += batch;
    }
    @done;
    llOwnerSay("[QS]debug: " + (string)total + " key(s) match '" + pattern + "'.");
}

cmd_count(integer ch)
{
    integer n = 0;
    while (llLinksetDataRead("qs:p:" + (string)ch + ":" + (string)n) != "")
        ++n;
    llOwnerSay("[QS]debug: channel " + (string)ch + " has " + (string)n + " pose(s).");
}

cmd_meta(integer ch)
{
    string v = llLinksetDataRead("qs:meta:" + (string)ch);
    if (v == "")
    {
        llOwnerSay("[QS]debug: qs:meta:" + (string)ch + " — NOT SET (channel will re-seed on next reset).");
    }
    else
    {
        llOwnerSay("[QS]debug: qs:meta:" + (string)ch + " = " + v);
    }
}

cmd_cfg(integer ch)
{
    string v = llLinksetDataRead("qs:cfg:" + (string)ch);
    if (v == "")
    {
        llOwnerSay("[QS]debug: qs:cfg:" + (string)ch + " — empty.");
        return;
    }
    llOwnerSay("[QS]debug: qs:cfg:" + (string)ch + ":\n" + v);
}

cmd_sitter(integer ch)
{
    string v = llLinksetDataRead("qs:sitter:" + (string)ch);
    if (v == "")
    {
        llOwnerSay("[QS]debug: qs:sitter:" + (string)ch + " — empty.");
    }
    else
    {
        llOwnerSay("[QS]debug: qs:sitter:" + (string)ch + " = " + v);
    }
}

cmd_pose(integer ch, integer i)
{
    string val = llLinksetDataRead("qs:p:" + (string)ch + ":" + (string)i);
    if (val == "")
    {
        llOwnerSay("[QS]debug: qs:p:" + (string)ch + ":" + (string)i + " — not found.");
        return;
    }
    list parts = llParseStringKeepNulls(val, ["|"], []);
    llOwnerSay("[QS]debug: qs:p:" + (string)ch + ":" + (string)i + ":"
      + "\n  name = " + llList2String(parts, 0)
      + "\n  type = " + llList2String(parts, 1) + "  (P=POSE, S=SYNC, M=MENU, T=TOMENU, B=BUTTON)"
      + "\n  anim = " + llList2String(parts, 2)
      + "\n  pos  = " + llList2String(parts, 3)
      + "\n  rot  = " + llList2String(parts, 4));
}

cmd_poses(integer ch)
{
    integer i = 0;
    string val;
    while ((val = llLinksetDataRead("qs:p:" + (string)ch + ":" + (string)i)) != "")
    {
        list parts = llParseStringKeepNulls(val, ["|"], []);
        llOwnerSay("  [" + (string)i + "] "
          + llList2String(parts, 1) + " "
          + llList2String(parts, 0)
          + " | " + llList2String(parts, 2)
          + " | " + llList2String(parts, 3)
          + llList2String(parts, 4));
        ++i;
    }
    llOwnerSay("[QS]debug: " + (string)i + " pose(s) on channel " + (string)ch + ".");
}

// Scan every qs:p:<ch>:<i> across all channels (0..7) and print rows
// whose VALUE contains the given substring. Useful for hunting down
// "which entry has 'GM.CT-Suck' in its anim slot?" type questions.
cmd_grep(string query)
{
    if (query == "")
    {
        llOwnerSay("[QS]debug: usage: grep <text>");
        return;
    }
    integer total = 0;
    integer ch;
    for (ch = 0; ch < 8; ++ch)
    {
        integer i = 0;
        string val;
        while ((val = llLinksetDataRead("qs:p:" + (string)ch + ":" + (string)i)) != "")
        {
            if (llSubStringIndex(val, query) != -1)
            {
                llOwnerSay("  qs:p:" + (string)ch + ":" + (string)i + " = " + val);
                ++total;
            }
            ++i;
        }
    }
    llOwnerSay("[QS]debug: " + (string)total + " match(es) for '" + query + "'.");
}

cmd_raw(string lkey)
{
    if (lkey == "")
    {
        llOwnerSay("[QS]debug: usage: raw <key>");
        return;
    }
    string v = llLinksetDataRead(lkey);
    if (v == "")
    {
        llOwnerSay("[QS]debug: " + lkey + " — not found.");
        return;
    }
    llOwnerSay("[QS]debug: " + lkey + " = " + v);
}

cmd_mem()
{
    integer avail = llLinksetDataAvailable();
    integer used = LSD_TOTAL_BYTES - avail;
    integer pct = used * 100 / LSD_TOTAL_BYTES;
    // tiny visual bar so the % is easy to read at a glance
    integer bar_width = 20;
    integer filled = used * bar_width / LSD_TOTAL_BYTES;
    if (filled > bar_width) filled = bar_width;
    string bar;
    integer i;
    for (i = 0; i < filled; ++i) bar += "█";
    for (i = filled; i < bar_width; ++i) bar += "░";
    llOwnerSay("[QS]debug: LSD usage:\n  [" + bar + "] " + (string)pct + "%"
      + "\n  used  : " + (string)used + " bytes"
      + "\n  free  : " + (string)avail + " bytes"
      + "\n  total : " + (string)LSD_TOTAL_BYTES + " bytes");
}

cmd_delch(integer ch)
{
    // llLinksetDataDeleteFound returns [status, count] — pull the count out.
    integer n = 0;
    n += llList2Integer(llLinksetDataDeleteFound("^qs:p:" + (string)ch + ":[0-9]+$", ""), 1);
    n += llList2Integer(llLinksetDataDeleteFound("^qs:cfg:" + (string)ch + "$", ""), 1);
    n += llList2Integer(llLinksetDataDeleteFound("^qs:sitter:" + (string)ch + "$", ""), 1);
    n += llList2Integer(llLinksetDataDeleteFound("^qs:meta:" + (string)ch + "$", ""), 1);
    // Also drop boot's skip-marker so the next reset re-seeds. Without
    // this, boot would see qs:boot:asset == current notecard key and
    // skip the re-parse — leaving the deleted channel(s) empty.
    n += llList2Integer(llLinksetDataDeleteFound("^qs:boot:asset$", ""), 1);
    llOwnerSay("[QS]debug: deleted " + (string)n + " key(s) for channel " + (string)ch + ". Reset the prim to re-seed from notecard.");
}

cmd_nuke(integer confirmed)
{
    if (!confirmed)
    {
        llOwnerSay("[QS]debug: This will wipe ALL Linkset Data on this object (every key, not just qs:*). Type '/" + (string)chan + " nuke yes' to proceed.");
        return;
    }
    llLinksetDataReset();
    llOwnerSay("[QS]debug: Linkset Data wiped. Reset the prim to re-seed from notecard.");
}

// === STRESS TEST OPS ===

// 90055 from "sitB" — pose change. hudproxy's handler dispatches to
// applyPoseChange, which triggers a poseBufPush (= 90262 save) for the
// OLD pose's accumulated po/ro. First call for a sitter has empty
// oldPose so no save fires; subsequent calls do.
stress_send_pose(integer slot, string pose)
{
    vector pos = <llFrand(2.0) - 1.0, llFrand(2.0) - 1.0, llFrand(1.0)>;
    vector rot = <0, 0, llFrand(360)>;
    llMessageLinked(LINK_THIS, 90055,
        (string)slot,
        (key)(pose + "||" + (string)pos + "|" + (string)rot + "|"));
}

// 90262 directly to offset.lsl with non-zero offsets — simulates a
// HUD [Adjust][SAVE] click. Bypasses the ZERO/ZERO delete sentinel
// so each call grows the QSO:* keyspace.
stress_send_save(key uuid, integer slot, string pose)
{
    vector pos = <llFrand(0.4) - 0.2, llFrand(0.4) - 0.2, 0>;
    vector rot = <0, 0, llFrand(20.0) - 10.0>;
    llMessageLinked(LINK_THIS, 90262,
        (string)slot + "|" + pose + "|" + (string)pos + "|" + (string)rot,
        uuid);
}

stress_tick_event()
{
    if (stress_state == STRESS_RAMP)
    {
        integer i = llGetListLength(stress_sitters);
        if (i >= stress_count)
        {
            stress_state = STRESS_CHAOS;
            llOwnerSay("[stress] " + (string)stress_count
                + " sitter(s) joined; entering chaos.");
            return;
        }
        key uuid = llGenerateKey();
        stress_sitters += uuid;
        llMessageLinked(LINK_THIS, 90060, "", uuid);
        llMessageLinked(LINK_THIS, 90070, (string)i, uuid);
        ++stress_ops;
    }
    else if (stress_state == STRESS_CHAOS)
    {
        integer n = llGetListLength(stress_sitters);
        if (n == 0)
        {
            stress_state = STRESS_IDLE;
            llSetTimerEvent(0.0);
            return;
        }
        integer roll = (integer)llFrand(100.0);
        integer slot = (integer)llFrand((float)n);
        string pose  = llList2String(stress_poses,
            (integer)llFrand((float)llGetListLength(stress_poses)));
        if (roll < 70)
        {
            stress_send_pose(slot, pose);
        }
        else if (roll < 85 && n >= 2)
        {
            integer slotB = (slot + 1 + (integer)llFrand((float)(n - 1))) % n;
            // 90031 = QS_SWAP_QUIET — stress-test swaps shouldn't
            // also trigger the post-swap pose-menu reopen in sitA
            // (would spam dialogs). Stock 90030 (with reopen) stays
            // reserved for user-driven pose-menu [SWAP] / seat-picker.
            llMessageLinked(LINK_THIS, 90031,
                (string)slot, (key)((string)slotB));
        }
        else
        {
            stress_send_save(llList2Key(stress_sitters, slot), slot, pose);
        }
        ++stress_ops;
    }
    else if (stress_state == STRESS_CLEANUP)
    {
        integer n = llGetListLength(stress_sitters);
        if (n == 0)
        {
            stress_state = STRESS_IDLE;
            llSetTimerEvent(0.0);
            llOwnerSay("[stress] cleanup done. " + (string)stress_ops
                + " ops total. lsdFree=" + (string)llLinksetDataAvailable());
            return;
        }
        key uuid = llList2Key(stress_sitters, n - 1);
        stress_sitters = llDeleteSubList(stress_sitters, n - 1, n - 1);
        llMessageLinked(LINK_THIS, 90065, "", uuid);
        ++stress_ops;
    }
}

cmd_stress(string sub, string arg)
{
    if (sub == "" || sub == "help")
    {
        llOwnerSay("[stress] subcommands:\n"
          + "  stress start [n]   spawn n fake sitters (default 6, max 7)\n"
          + "  stress stop        run cleanup phase (90065 each)\n"
          + "  stress status      state, sitter/op counts, free LSD\n"
          + "  stress speed <ms>  chaos tick interval (min 100 ms)");
        return;
    }
    if (sub == "start")
    {
        if (stress_state != STRESS_IDLE)
        {
            llOwnerSay("[stress] already running (state=" + (string)stress_state + ").");
            return;
        }
        stress_count = 6;
        if (arg != "") stress_count = (integer)arg;
        if (stress_count < 1) stress_count = 1;
        if (stress_count > 7) stress_count = 7;
        stress_sitters = [];
        stress_ops     = 0;
        stress_state   = STRESS_RAMP;
        llOwnerSay("[stress] ramping " + (string)stress_count
            + " sitter(s), tick=" + (string)stress_tick + "s.");
        llSetTimerEvent(stress_tick);
        return;
    }
    if (sub == "stop")
    {
        if (stress_state == STRESS_IDLE)
        {
            llOwnerSay("[stress] not running.");
            return;
        }
        stress_state = STRESS_CLEANUP;
        llOwnerSay("[stress] entering cleanup phase.");
        return;
    }
    if (sub == "status")
    {
        llOwnerSay("[stress] state=" + (string)stress_state
            + " sitters=" + (string)llGetListLength(stress_sitters)
            + " ops=" + (string)stress_ops
            + " lsdFree=" + (string)llLinksetDataAvailable()
            + " debugMem=" + (string)llGetFreeMemory());
        return;
    }
    if (sub == "speed")
    {
        float t = (float)arg / 1000.0;
        if (t < 0.1) t = 0.1;
        stress_tick = t;
        if (stress_state != STRESS_IDLE) llSetTimerEvent(stress_tick);
        llOwnerSay("[stress] tick=" + (string)stress_tick + "s.");
        return;
    }
    llOwnerSay("[stress] unknown sub-command '" + sub + "'. Try 'stress help'.");
}

handle_command(string cmd)
{
    list args = llParseStringKeepNulls(cmd, [" "], []);
    string verb = llList2String(args, 0);
    if (verb == "" || verb == "help")
    {
        show_help();
    }
    else if (verb == "keys")
    {
        cmd_keys(llList2String(args, 1));
    }
    else if (verb == "count")
    {
        cmd_count(llList2Integer(args, 1));
    }
    else if (verb == "meta")
    {
        cmd_meta(llList2Integer(args, 1));
    }
    else if (verb == "cfg")
    {
        cmd_cfg(llList2Integer(args, 1));
    }
    else if (verb == "sitter")
    {
        cmd_sitter(llList2Integer(args, 1));
    }
    else if (verb == "pose")
    {
        cmd_pose(llList2Integer(args, 1), llList2Integer(args, 2));
    }
    else if (verb == "poses")
    {
        cmd_poses(llList2Integer(args, 1));
    }
    else if (verb == "grep")
    {
        cmd_grep(llList2String(args, 1));
    }
    else if (verb == "raw")
    {
        cmd_raw(llList2String(args, 1));
    }
    else if (verb == "mem")
    {
        cmd_mem();
    }
    else if (verb == "delch")
    {
        cmd_delch(llList2Integer(args, 1));
    }
    else if (verb == "nuke")
    {
        cmd_nuke(llList2String(args, 1) == "yes");
    }
    else if (verb == "stress")
    {
        cmd_stress(llList2String(args, 1), llList2String(args, 2));
    }
    else
    {
        llOwnerSay("[QS]debug: unknown command '" + verb + "'. Try '/" + (string)chan + " help'.");
    }
}

default
{
    state_entry()
    {
        listen_handle = llListen(chan, "", llGetOwner(), "");
        llOwnerSay("[QS]debug ready on /" + (string)chan + ". Type '/" + (string)chan + " help'.");
    }

    on_rez(integer p)
    {
        llResetScript();
    }

    changed(integer c)
    {
        if (c & CHANGED_OWNER) llResetScript();
    }

    listen(integer c, string n, key id, string msg)
    {
        handle_command(msg);
    }

    timer()
    {
        stress_tick_event();
    }
}
