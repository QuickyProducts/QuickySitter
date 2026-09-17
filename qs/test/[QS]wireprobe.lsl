string VERSION = "0.1"; // [QS]wireprobe - passive link-message probe (test tool, never shipped)
// ------------------------------------------------------------------------
// Drop this script into the SAME prim as the QS scripts (all QS base
// scripts live in one inventory). It sends NOTHING on the QS wire and
// changes no state: it only mirrors link_message traffic in the QS band
// (90000-90299) to the owner while armed.
//
// Owner chat commands (channel /7):
//   /7 on      arm the probe (starts disarmed to survive the reseed storm
//              that adding a script to the inventory can trigger)
//   /7 off     disarm
//   /7 who     report physically seated avatars and the slot adoptions
//              observed since arming (90060/90065), plus qs:sitter labels
//   /7 all     toggle logging of census/alive chatter (90079/90096/90097),
//              off by default
//   /7 help    command list
//
// Field-case protocol (MFM cuddle, Female1 not animating):
//   1. /7 on
//   2. all three stand up, then sit in order: man, woman, man
//   3. /7 who   -> expect slots 0/1/2 with the woman on slot 1
//   4. click the failing MFM cuddle pose
//   5. copy everything the probe said and send it in
// ------------------------------------------------------------------------

integer PROBE_CHAN = 7;
integer armed = FALSE;
integer log_census = FALSE;
list SLOTMAP; // strided [slot, key-as-string, legacy name] from 90060/90065

// Labels lifted verbatim from the QS sources (comment annotations).
list LABELS = [
    90000, "play pose",
    90001, "overlay start",
    90002, "overlay stop",
    90005, "send menu to user",
    90010, "play pose",
    90011, "set link camera",
    90030, "swap",
    90031, "quiet swap",
    90033, "clear menu listener",
    90045, "broadcast pose playing",
    90055, "anim info from sitB",
    90056, "send anim info",
    90057, "helper moved",
    90060, "new sitter",
    90065, "sitter gone",
    90070, "update SITTERS after perm grant",
    90075, "old helper animate",
    90076, "old helper stop",
    90079, "census",
    90096, "QSALIVE probe",
    90097, "QSALIVE reply",
    90100, "menu broadcast",
    90101, "menu option chosen",
    90150, "re-place sittargets",
    90201, "plugin info request",
    90202, "security present",
    90210, "sequence",
    90263, "adjuster overwrote default",
    90271, "re-sync trigger",
    90298, "show sittargets"
];

say(string msg)
{
    llOwnerSay("[probe] " + msg);
}

string stamp()
{
    // UTC clock time only; enough to correlate lines within one test run.
    return llGetSubString(llGetTimestamp(), 11, 22);
}

string name_or_key(key id)
{
    string n = llKey2Name(id);
    if (n != "")
    {
        return n;
    }
    if ((string)id == "")
    {
        return "-";
    }
    return (string)id;
}

report_who()
{
    // Physical view: seated avatars are appended to the linkset as
    // pseudo-prims at the end.
    integer i = llGetNumberOfPrims();
    string seated = "";
    while (llGetAgentSize(llGetLinkKey(i)) != ZERO_VECTOR)
    {
        seated = llKey2Name(llGetLinkKey(i)) + " (link " + (string)i + ") " + seated;
        --i;
    }
    if (seated == "")
    {
        seated = "nobody";
    }
    say("physically seated: " + seated);
    // Logical view: adoptions observed on the wire since arming.
    if (llGetListLength(SLOTMAP) == 0)
    {
        say("no 90060 adoptions observed yet (arm first, then re-sit)");
    }
    integer j;
    for (j = 0; j < llGetListLength(SLOTMAP); j += 3)
    {
        say("slot " + llList2String(SLOTMAP, j)
            + " adopted " + llList2String(SLOTMAP, j + 2));
    }
    // Card view: sitter labels as boot seeded them.
    integer ch;
    for (ch = 0; ch < 8; ++ch)
    {
        string info = llLinksetDataRead("qs:sitter:" + (string)ch);
        if (info != "")
        {
            say("qs:sitter:" + (string)ch + " = " + llGetSubString(info, 0, 79));
        }
    }
}

default
{
    state_entry()
    {
        llListen(PROBE_CHAN, "", llGetOwner(), "");
        say("wireprobe " + VERSION + " ready, disarmed. /7 on to arm, /7 help for commands.");
    }

    on_rez(integer p)
    {
        llResetScript();
    }

    listen(integer chan, string speaker, key id, string msg)
    {
        msg = llToLower(llStringTrim(msg, STRING_TRIM));
        if (msg == "on")
        {
            armed = TRUE;
            SLOTMAP = [];
            say("armed. QS band 90000-90299 is being mirrored.");
        }
        else if (msg == "off")
        {
            armed = FALSE;
            say("disarmed.");
        }
        else if (msg == "who")
        {
            report_who();
        }
        else if (msg == "all")
        {
            log_census = !log_census;
            if (log_census)
            {
                say("census/alive chatter is now logged too.");
            }
            else
            {
                say("census/alive chatter is muted again.");
            }
        }
        else if (msg == "help")
        {
            say("/7 on | off | who | all | help");
        }
    }

    link_message(integer sender, integer num, string str, key id)
    {
        if (!armed)
        {
            return;
        }
        if (num < 90000)
        {
            return;
        }
        if (num > 90299)
        {
            return;
        }
        if (!log_census)
        {
            if (num == 90079)
            {
                return;
            }
            if (num == 90096)
            {
                return;
            }
            if (num == 90097)
            {
                return;
            }
        }
        if (num == 90060)
        {
            integer slot = (integer)str;
            integer at = llListFindList(SLOTMAP, [(string)slot]);
            if (at != -1)
            {
                SLOTMAP = llDeleteSubList(SLOTMAP, at, at + 2);
            }
            SLOTMAP += [(string)slot, (string)id, name_or_key(id)];
        }
        else if (num == 90065)
        {
            integer gone = llListFindList(SLOTMAP, [str]);
            if (gone != -1)
            {
                SLOTMAP = llDeleteSubList(SLOTMAP, gone, gone + 2);
            }
        }
        string lbl = "";
        integer li = llListFindList(LABELS, [num]);
        if (li != -1)
        {
            lbl = " " + llList2String(LABELS, li + 1);
        }
        string line = stamp() + " #" + (string)num + lbl
            + " | " + llGetSubString(str, 0, 119)
            + " | " + name_or_key(id);
        llOwnerSay(line);
    }
}
