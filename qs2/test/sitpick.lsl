/*
 * sitpick - does the landing position tell us where the user clicked?
 *
 * Follow-up to oneprim.lsl. That probe showed one prim can hold several
 * avatars, at the cost of seat choice by click point: with a single
 * prim there is no longer a prim per seat to click on.
 *
 * THE WAY OUT, and it comes from oneprim's own output. Arrival 2 landed
 * on <0.34, -0.24078, 0.88> - an unrounded value, so SL's own
 * click-relative placement rather than our sit target. If that position
 * tracks the click, then the seat can be chosen FROM IT: read the new
 * link's position on CHANGED_LINK and take the nearest seat.
 *
 * That would be finer than what v1 does. v1 picks by prim, which is
 * discrete; a landing position is continuous, so one long sofa prim
 * could carry seats anywhere along it.
 *
 * NO SIT TARGET AT ALL, which is the point. oneprim only cleared it for
 * arrivals 2+, so arrival 1 still went to the target and carried no
 * click information. Here nobody gets a target, which also tests the
 * second half of the assumption: that a prim with no sit target is
 * still sittable.
 *
 * HOW TO RUN. Put it in a SINGLE prim, on its own, and stretch that prim
 * wide on X - about 2 m - so there is somewhere to aim. Then sit
 * avatars while right-clicking deliberately at the LEFT end, the MIDDLE
 * and the RIGHT end, and read which seat it picked each time. Touch
 * resets.
 *
 * WHAT TO LOOK FOR:
 *   picked seat matches where you clicked   -> click-point choice is
 *                                              recoverable, and better
 *   always the same seat                    -> SL is not using the click
 *                                              point; this is dead
 *   nobody can sit at all                   -> a prim needs a sit target
 *                                              to be sittable; also dead
 */

// Three notional seats spread along X, as a sofa would be.
list SEATS = [ <-0.7, 0.0, 0.55>, <0.0, 0.0, 0.55>, <0.7, 0.0, 0.55> ];

// Z is deliberately WEIGHTED DOWN in the distance test. Landing heights
// come out near the prim surface and say little about intent, while a
// bunk bed would have two seats differing ONLY in Z. Getting this wrong
// is the likeliest way for the whole idea to feel unreliable in use, so
// it is a knob here rather than a constant buried in the engine.
float Z_WEIGHT = 0.3;

list KNOWN;             // avatar keys already accounted for

integer nearest_seat(vector p)
{
    integer best = 0;
    float bestd = -1.0;
    integer i = 0;
    integer n = llGetListLength(SEATS);
    while (i < n)
    {
        vector s = llList2Vector(SEATS, i);
        vector d = p - s;
        d.z = d.z * Z_WEIGHT;
        float dist = llVecMag(d);
        if (bestd < 0.0 || dist < bestd) { bestd = dist; best = i; }
        ++i;
    }
    return best;
}

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

default
{
    state_entry()
    {
        // No target. This is the experiment, not an oversight.
        llSitTarget(ZERO_VECTOR, ZERO_ROTATION);
        KNOWN = [];
        llOwnerSay("sitpick ready, NO sit target set."
            + " Right-click the LEFT end and sit.");
    }

    touch_start(integer n)
    {
        llResetScript();
    }

    changed(integer c)
    {
        if (!(c & CHANGED_LINK)) return;

        list a = agent_links();
        integer i = 0;
        list fresh;
        while (i < llGetListLength(a))
        {
            integer l = llList2Integer(a, i);
            string k = (string)llGetLinkKey(l);
            if (llListFindList(KNOWN, [k]) == -1) fresh += l;
            ++i;
        }
        if (llGetListLength(fresh) == 0)
        {
            // Somebody left; resync so a re-sit reads as fresh again.
            KNOWN = [];
            i = 0;
            while (i < llGetListLength(a))
            {
                KNOWN += (string)llGetLinkKey(llList2Integer(a, i));
                ++i;
            }
            return;
        }

        i = 0;
        while (i < llGetListLength(fresh))
        {
            integer l = llList2Integer(fresh, i);
            KNOWN += (string)llGetLinkKey(l);
            vector p = llList2Vector(
                llGetLinkPrimitiveParams(l, [PRIM_POS_LOCAL]), 0);
            integer pick = nearest_seat(p);
            llOwnerSay("landed at " + (string)p
                + "  -> seat " + (string)pick
                + " " + (string)llList2Vector(SEATS, pick)
                + "   (" + llKey2Name(llGetLinkKey(l)) + ")");
            // Move them there, so a wrong pick is visible and not just
            // a number in chat.
            llSetLinkPrimitiveParamsFast(l,
                [PRIM_POS_LOCAL, llList2Vector(SEATS, pick),
                 PRIM_ROT_LOCAL, llEuler2Rot(<0.0, 0.0, 0.002> * DEG_TO_RAD)]);
            ++i;
        }
    }
}
