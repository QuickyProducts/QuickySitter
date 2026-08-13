/*
 * oneprim - can ONE prim hold several seated avatars?
 *
 * Throwaway probe, same purpose as permtest was for the permission
 * question: settle a design assumption in-world before anything gets
 * built on it.
 *
 * THE CLAIM UNDER TEST. A sit target binds exactly one avatar to a
 * prim, which is why v1 needs one prim per seat. But the target is only
 * needed for the INSTANT of sitting: afterwards the avatar is a link of
 * its own and is positioned through PRIM_POS_LOCAL on that link, which
 * is what [QS]seat's move_occupant already does. So the target could be
 * a door handle rather than a seat: re-aim it at the next free slot the
 * moment somebody comes through.
 *
 * That gives three questions, and this answers them in order:
 *
 *   Q1  Does re-aiming the sit target EJECT or MOVE the avatar who is
 *       already sitting on it?
 *   Q2  Can a second avatar then sit on the same prim?
 *   Q3  Can both be positioned independently by link afterwards?
 *
 * Any "no" kills the single-prim idea outright, and it is better to
 * find that out now than after the seat model has been rebuilt around
 * it.
 *
 * HOW TO RUN. Drop it into a SINGLE-PRIM object, on its own, with no
 * other QS script present. Sit avatar A, wait for the report, sit
 * avatar B, read the verdict. Touch to reset and run it again.
 *
 * WHAT IT DOES NOT TEST, and would still have to be answered before
 * this becomes a design:
 *   - two avatars sitting inside the same frame, both grabbing the
 *     target before it is re-aimed
 *   - llAvatarOnLinkSitTarget, which reports one avatar per prim and so
 *     stops being usable as the occupancy lookup
 *   - per-seat camera, which is prim-bound
 *   - the "#SET-slot" prim-description pinning, which has no target
 */

vector SLOT0 = <0.0,  0.0, 0.55>;
vector SLOT1 = <0.7,  0.0, 0.55>;
vector SLOT2 = <-0.7, 0.0, 0.55>;

list  SEATED;          // avatar keys in arrival order
integer step;          // how many have come through the door

Say(string s)
{
    llOwnerSay(s);
}

// Seated agents occupy the TOP link numbers. Returns them in link order.
list agent_links()
{
    list out;
    integer n = llGetNumberOfPrims();
    integer l = 2;                     // 1 is the prim itself
    while (l <= n)
    {
        if (llGetAgentSize(llGetLinkKey(l)) != ZERO_VECTOR) out += l;
        ++l;
    }
    return out;
}

integer link_of(key av)
{
    integer n = llGetNumberOfPrims();
    integer l = 2;
    while (l <= n)
    {
        if (llGetLinkKey(l) == av) return l;
        ++l;
    }
    return 0;
}

vector pos_of(integer link)
{
    return llList2Vector(llGetLinkPrimitiveParams(link, [PRIM_POS_LOCAL]), 0);
}

vector slot(integer i)
{
    if (i == 0) return SLOT0;
    if (i == 1) return SLOT1;
    return SLOT2;
}

report()
{
    list a = agent_links();
    Say("--- seated now: " + (string)llGetListLength(a) + " ---");
    integer i = 0;
    while (i < llGetListLength(a))
    {
        integer l = llList2Integer(a, i);
        Say("   link " + (string)l + "  " + llKey2Name(llGetLinkKey(l))
            + "  at " + (string)pos_of(l));
        ++i;
    }
    // The lookup the current engine relies on. Expected to name at most
    // one of them, which is the part that would have to be replaced.
    Say("   llAvatarOnLinkSitTarget(1) says: "
        + llKey2Name(llAvatarOnLinkSitTarget(1)));
}

arm(integer i)
{
    // llSitTarget, not llLinkSitTarget: a single-prim object has no link
    // 1 until somebody sits on it, and the number shifts underneath you
    // exactly when this test cares.
    llSitTarget(slot(i), ZERO_ROTATION);
    Say(">>> target re-aimed at slot " + (string)i + " " + (string)slot(i)
        + " - now sit the NEXT avatar.");
}

default
{
    state_entry()
    {
        SEATED = [];
        step = 0;
        arm(0);
        Say("oneprim ready. Sit avatar A.");
    }

    touch_start(integer n)
    {
        Say("=== reset ===");
        llResetScript();
    }

    changed(integer c)
    {
        if (!(c & CHANGED_LINK)) return;

        list a = agent_links();
        integer now = llGetListLength(a);

        // Somebody left. Nothing to prove here, just resync.
        if (now < llGetListLength(SEATED))
        {
            Say("somebody stood up.");
            SEATED = [];
            integer i = 0;
            while (i < now) { SEATED += (string)llGetLinkKey(llList2Integer(a, i)); ++i; }
            return;
        }
        if (now == llGetListLength(SEATED)) return;

        // A new arrival.
        integer l = llList2Integer(a, now - 1);
        key av = llGetLinkKey(l);
        SEATED += (string)av;
        ++step;
        Say("### arrival " + (string)step + ": " + llKey2Name(av)
            + " on link " + (string)l + " at " + (string)pos_of(l));

        if (step == 1)
        {
            // Q1. Re-aim the target out from under the sitter and see
            // whether they survive it. Position is sampled again on the
            // timer, because a move would not be visible in this event.
            report();
            arm(1);
            llSetTimerEvent(2.0);
            return;
        }

        if (step == 2)
        {
            // Q2 answered by the fact that we got here at all.
            Say("### Q2: a SECOND avatar sat on the same prim. It works.");
            report();

            // Q3. Push them apart by link and see if both hold.
            Say(">>> moving them apart by link...");
            integer i = 0;
            while (i < llGetListLength(SEATED))
            {
                integer lk = link_of((key)llList2String(SEATED, i));
                if (lk) llSetLinkPrimitiveParamsFast(lk,
                    [PRIM_POS_LOCAL, slot(i),
                     PRIM_ROT_LOCAL, llEuler2Rot(<0.0, 0.0, 0.002> * DEG_TO_RAD)]);
                ++i;
            }
            arm(2);
            llSetTimerEvent(2.0);
            return;
        }

        report();
    }

    timer()
    {
        llSetTimerEvent(0.0);
        if (step == 1)
        {
            list a = agent_links();
            if (llGetListLength(a) == 0)
            {
                Say("### Q1: FAILED - re-aiming the target EJECTED the"
                    + " sitter. Single-prim seating is dead here.");
                return;
            }
            integer l = llList2Integer(a, 0);
            Say("### Q1: still seated at " + (string)pos_of(l)
                + ". Compare with slot 0 " + (string)SLOT0
                + " - if it moved, the target drags whoever is on it and"
                + " every re-aim would shove the existing sitter.");
            return;
        }
        Say("### Q3: final positions, they should be apart:");
        report();
    }
}
