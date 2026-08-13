/*
 * primsize - at what prim size does the second sitter stop being admitted?
 *
 * This is the make-or-break question for single-prim seating. Measured
 * 2026-08-13, one script, two avatars, one variable:
 *
 *   standard cube      -> second avatar sits
 *   prim stretched 2 m -> second avatar cannot sit
 *
 * Same code both times, so the prim governs. Real furniture is large,
 * so if the limit sits below sofa scale the whole idea is dead and one
 * prim per seat stays.
 *
 * Five wrong explanations preceded this, every one of them reasoned
 * from how SL "should" behave. So this measures instead: the script
 * resizes its own prim, and you try to seat two avatars at each size.
 *
 * HOW TO RUN
 *   Single prim, this script alone. Do NOT resize it by hand, the
 *   script owns the size.
 *   1. read the size it announces
 *   2. sit avatar 1, then avatar 2
 *   3. say whether avatar 2 got in
 *   4. stand BOTH up, touch to advance to the next size, repeat
 *
 * The sit-target sequence is exactly oneprim's, which is the known-good
 * one: open at <0, 0, 0.55>, re-arm to <0.7, 0, 0.55> after arrival 1.
 * Nothing else is varied.
 *
 * WORTH WATCHING BEYOND THE THRESHOLD: where arrival 2 lands at each
 * size. Three runs so far put them at x = 0.34, 0.1235 and 0.34 while
 * the seats are 0.7 apart, so SL looks to compress click-relative
 * placement hard toward the prim centre. If the spread does not grow
 * with the prim, choosing a seat by click point will not scale to a
 * long sofa either, whatever the admission limit turns out to be.
 */

list SIZES = [
    <0.5, 0.5, 0.5>,
    <1.0, 0.5, 0.5>,
    <1.5, 0.5, 0.5>,
    <2.0, 0.5, 0.5>
];

vector OPEN  = <0.0, 0.0, 0.55>;   // oneprim's slot 0
vector REARM = <0.7, 0.0, 0.55>;   // oneprim's slot 1

integer idx;
list    KNOWN;

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

setup()
{
    vector s = llList2Vector(SIZES, idx);
    llSetScale(s);
    llSitTarget(OPEN, ZERO_ROTATION);
    KNOWN = [];
    Say("=== prim size " + (string)s + " ("
        + (string)(idx + 1) + "/" + (string)llGetListLength(SIZES)
        + ") === target " + (string)OPEN
        + ". Sit avatar 1, then avatar 2.");
}

default
{
    state_entry()
    {
        idx = 0;
        setup();
    }

    touch_start(integer n)
    {
        if (llGetListLength(agent_links()) > 0)
        {
            Say("stand everybody up first, then touch again.");
            return;
        }
        idx = (idx + 1) % llGetListLength(SIZES);
        setup();
    }

    changed(integer c)
    {
        if (!(c & CHANGED_LINK)) return;

        list a = agent_links();
        list fresh;
        integer i = 0;
        while (i < llGetListLength(a))
        {
            integer l = llList2Integer(a, i);
            if (llListFindList(KNOWN, [(string)llGetLinkKey(l)]) == -1)
                fresh += l;
            ++i;
        }
        if (llGetListLength(fresh) == 0)
        {
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
            integer count = llGetListLength(KNOWN);
            Say("  arrival " + (string)count + " at " + (string)p
                + "   (" + llKey2Name(llGetLinkKey(l)) + ")");
            if (count == 1)
            {
                llSitTarget(REARM, ZERO_ROTATION);
                Say("  re-armed at " + (string)REARM);
            }
            if (count == 2)
            {
                Say("  >>> SIZE " + (string)llList2Vector(SIZES, idx)
                    + " ADMITS A SECOND SITTER.");
            }
            ++i;
        }
    }
}
