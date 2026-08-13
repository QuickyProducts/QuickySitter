/*
 * sitpick - which added behaviour stops the second avatar sitting?
 *
 * oneprim.lsl demonstrably let a second avatar onto the same prim.
 * Three attempts to reproduce that here failed, each on a different
 * guess about why, so this stops guessing and bisects instead.
 *
 * sitpick does three things oneprim did not:
 *   1. it MOVES the arrival to a seat
 *   2. it takes PERMISSION_CONTROL_CAMERA and sets a camera
 *   3. it re-arms the sit target to a computed value
 *
 * MODE, cycled by touching the prim, adds them back one at a time.
 * Mode 0 is oneprim's behaviour plus a report and nothing else, so it
 * MUST work - if it does not, the difference is somewhere neither
 * script has been looked at yet.
 *
 *   mode 0   report only, re-arm by cycling the slot (as oneprim did)
 *   mode 1   + move the arrival to the picked seat
 *   mode 2   + set the per-seat camera
 *
 * Run: sit avatar 1, then avatar 2. If avatar 2 gets in, stand both up,
 * touch to advance the mode, repeat. The mode where avatar 2 stops
 * getting in is the answer.
 *
 * THE ORIGINAL QUESTION, still open behind all this: does the landing
 * position of arrival 2 track where they clicked? oneprim's arrival 2
 * landed on <0.34, -0.24078, 0.88>, an unrounded value, so SL's own
 * click-relative placement rather than a sit target. If that holds,
 * seat choice by click survives on a single prim, and continuously
 * rather than per prim. Mode 0 answers it without any of the rest.
 */

// EXACTLY oneprim's slot(0/1/2), in that order, because mode 0 claims to
// reproduce oneprim and the first attempt did not: it opened on
// <-0.7, 0, 0.55> and re-armed to <0, 0, 0.55>, where oneprim opens on
// <0, 0, 0.55> and re-arms to <0.7, 0, 0.55>. Whether that matters is
// unknown, which is the point - it should not differ at all while the
// difference is being hunted.
//
// Read as seats they are still a sofa: middle, right, left.
list SEATS = [ <0.0, 0.0, 0.55>, <0.7, 0.0, 0.55>, <-0.7, 0.0, 0.55> ];

// Z is deliberately WEIGHTED DOWN in the distance test. Landing heights
// come out near the prim surface and say little about intent, while a
// bunk bed would have two seats differing ONLY in Z.
float Z_WEIGHT = 0.3;

// Per-seat camera distances, mode 2 only. Visibly different so two
// testers can just say which of them is close and which is far.
list CAM_DISTANCE = [1.5, 3.0, 6.0];

integer MODE;
list    KNOWN;          // avatar keys already accounted for
integer armcount;

Say(string s) { llOwnerSay(s); }

// Exactly what oneprim's arm() did: point the target at the next slot,
// which is a different vector each time.
rearm()
{
    ++armcount;
    vector t = llList2Vector(SEATS, armcount % llGetListLength(SEATS));
    llSitTarget(t, ZERO_ROTATION);
    Say("   re-armed at " + (string)t + " (call " + (string)armcount + ")");
}

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

announce()
{
    string what = "report only";
    if (MODE == 1) what = "report + MOVE";
    if (MODE == 2) what = "report + MOVE + CAMERA";
    Say("=== sitpick mode " + (string)MODE + ": " + what
        + " === sit avatar 1, then avatar 2.");
}

default
{
    state_entry()
    {
        MODE = 0;
        armcount = 0;
        KNOWN = [];
        llSitTarget(llList2Vector(SEATS, 0), ZERO_ROTATION);
        announce();
    }

    touch_start(integer n)
    {
        MODE = (MODE + 1) % 3;
        armcount = 0;
        KNOWN = [];
        llSitTarget(llList2Vector(SEATS, 0), ZERO_ROTATION);
        announce();
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
            // Somebody left. Resync so a re-sit reads as fresh again.
            KNOWN = [];
            i = 0;
            while (i < llGetListLength(a))
            {
                KNOWN += (string)llGetLinkKey(llList2Integer(a, i));
                ++i;
            }
            Say("   (somebody stood up, " + (string)llGetListLength(a)
                + " left seated)");
            return;
        }

        i = 0;
        while (i < llGetListLength(fresh))
        {
            integer l = llList2Integer(fresh, i);
            key av = llGetLinkKey(l);
            KNOWN += (string)av;

            vector p = llList2Vector(
                llGetLinkPrimitiveParams(l, [PRIM_POS_LOCAL]), 0);
            integer pick = nearest_seat(p);
            Say("### " + llKey2Name(av) + " link " + (string)l
                + " landed at " + (string)p
                + "  -> seat " + (string)pick);

            if (MODE >= 1)
            {
                llSetLinkPrimitiveParamsFast(l,
                    [PRIM_POS_LOCAL, llList2Vector(SEATS, pick),
                     PRIM_ROT_LOCAL,
                     llEuler2Rot(<0.0, 0.0, 0.002> * DEG_TO_RAD)]);
                Say("   moved to " + (string)llList2Vector(SEATS, pick));
            }

            if (MODE >= 2)
            {
                llRequestPermissions(av, PERMISSION_CONTROL_CAMERA);
                if (llGetPermissions() & PERMISSION_CONTROL_CAMERA)
                {
                    llSetCameraParams([
                        CAMERA_ACTIVE, 1,
                        CAMERA_DISTANCE, llList2Float(CAM_DISTANCE, pick),
                        CAMERA_BEHINDNESS_ANGLE, 0.0,
                        CAMERA_PITCH, 10.0
                    ]);
                    Say("   camera set, distance "
                        + (string)llList2Float(CAM_DISTANCE, pick));
                }
                else Say("   camera permission NOT granted.");
            }

            rearm();
            ++i;
        }
    }
}
