/*
 * zprobe - measure where a seated avatar actually ends up
 *
 * The remaining v2 defect is that poses sit lower than under v1, with no
 * way to see it except by eye. This makes it a number.
 *
 * IT IS PASSIVE. No sit target, no animation, no permission, no link
 * message. Drop it into the running furniture - either engine - and it
 * only reads. It cannot change what it is measuring.
 *
 * HOW TO RUN
 *   1. put it in the v1 copy, sit, wait for the settled line, note it
 *   2. put it in the v2 copy, sit the SAME avatar on the SAME seat,
 *      play the SAME pose, note it
 *   3. paste both
 *
 * The same avatar matters: SL derives part of a seated avatar's offset
 * from the shape, so two different bodies are not comparable.
 *
 * IT SAMPLES OVER TIME, deliberately. Both engines place the avatar
 * twice: the sit target puts them somewhere first, the pose moves them
 * afterwards. A single reading at CHANGED_LINK catches the first one and
 * says nothing about the second, so this reports at 0.5 s, 1.5 s and
 * 3 s. The LAST line is the one to compare; if the three differ, the two
 * placements are fighting and that is itself the finding.
 *
 * WHAT EACH FIELD IS FOR
 *   avatar Z    what we are actually comparing
 *   prim Z      the seat prim's own height. Pose positions are measured
 *               relative to it, so if THIS differs between the copies,
 *               the difference is in which prim got bound to the seat
 *               and not in the arithmetic at all.
 *   target Z    what the engine asked the sit target for. v1 and v2
 *               deliberately differ here (v1 subtracts 0.4), so a gap is
 *               expected; it is printed because avatar minus target says
 *               how much SL added on its own.
 */

integer SAMPLE;
list    WATCH;          // avatar keys being followed

Say(string s) { llOwnerSay(s); }

list agent_links()
{
    list out;
    integer n = llGetNumberOfPrims();
    integer l = 2;
    while (l <= n)
    {
        if (llGetAgentSize(llGetLinkKey(l)) != ZERO_VECTOR) out += l;
        ++l;
    }
    return out;
}

// The prim an avatar is seated on, which is the frame its pose position
// is expressed in. Found by asking every prim who is on its sit target.
integer seat_prim_of(key av)
{
    integer n = llGetObjectPrimCount(llGetKey());
    integer l = 1;
    while (l <= n)
    {
        if (llAvatarOnLinkSitTarget(l) == av) return l;
        ++l;
    }
    return 0;
}

report(string when)
{
    list a = agent_links();
    integer i = 0;
    while (i < llGetListLength(a))
    {
        integer l = llList2Integer(a, i);
        key av = llGetLinkKey(l);
        vector p = llList2Vector(
            llGetLinkPrimitiveParams(l, [PRIM_POS_LOCAL]), 0);

        integer sp = seat_prim_of(av);
        string primz = "?";
        string targz = "?";
        if (sp > 0)
        {
            vector pp = ZERO_VECTOR;
            if (sp > 1) pp = llList2Vector(
                llGetLinkPrimitiveParams(sp, [PRIM_POS_LOCAL]), 0);
            primz = (string)pp.z;
            // PRIM_SIT_TARGET reads back what the engine asked for.
            list st = llGetLinkPrimitiveParams(sp, [PRIM_SIT_TARGET]);
            vector tv = llList2Vector(st, 1);
            targz = (string)tv.z;
        }

        Say(when + "  " + llKey2Name(av)
            + "  link " + (string)l + " on prim " + (string)sp
            + "\n    avatar Z " + (string)p.z
            + "   prim Z " + primz
            + "   target Z " + targz
            + "\n    full pos " + (string)p);
        ++i;
    }
    if (llGetListLength(a) == 0) Say(when + "  nobody seated.");
}

default
{
    state_entry()
    {
        WATCH = [];
        SAMPLE = 0;
        Say("zprobe ready, passive. Sit down and wait for three lines.");
    }

    touch_start(integer n)
    {
        Say("--- manual reading ---");
        report("now  ");
    }

    changed(integer c)
    {
        if (!(c & CHANGED_LINK)) return;
        // Restart the sampling window on any seating change, so a pose
        // switch or a second arrival gets its own three readings.
        SAMPLE = 0;
        llSetTimerEvent(0.5);
    }

    timer()
    {
        ++SAMPLE;
        if (SAMPLE == 1) { report("t+0.5"); llSetTimerEvent(1.0); return; }
        if (SAMPLE == 2) { report("t+1.5"); llSetTimerEvent(1.5); return; }
        report("t+3.0  <- COMPARE THIS LINE");
        llSetTimerEvent(0.0);
    }
}
