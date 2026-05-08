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

string version = "0.01";
integer chan = 88;
integer listen_handle;
integer LSD_TOTAL_BYTES = 131072;  // 128 KB linkset cap

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
      + "  nuke / nuke yes       wipe ALL Linkset Data");
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
}
