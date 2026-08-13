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
 * THE TARGET STAYS ARMED. The first version of this probe cleared it
 * entirely, on the assumption that any prim is sittable. Measured
 * 2026-08-13: it is not. With no sit target nobody could sit at all.
 *
 * oneprim had already shown the configuration that does work, which is
 * a target that stays SET: B sat while the target existed and was
 * occupied, and still landed click-relative. So arrival 1 goes to the
 * target and carries no click information, and arrivals 2 and up carry
 * it. That is a weaker result than hoped, and possibly good enough:
 * "sit" on an EMPTY sofa means the default seat anyway, and choosing a
 * seat matters exactly when others are already taken.
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

// ---------------------------------------------------------------- camera
//
// SECOND QUESTION, folded in so the rig only has to be built once.
//
// Per-seat camera is the other thing one prim appears to cost:
// llSetLinkCamera and llSetCameraEyeOffset are prim-bound, so with a
// single prim every sitter would share one camera.
//
// llSetCameraParams is NOT prim-bound, it is avatar-bound, and it needs
// PERMISSION_CONTROL_CAMERA. For an avatar already sitting on the object
// that permission is granted WITHOUT a dialog - the same property we
// measured for PERMISSION_TRIGGER_ANIMATION (DESIGN.md §3), which is what
// lets one script drive every seat. If that holds here too, the same
// cycling works for cameras.
//
// So the binary question first: does the grant come back synchronously,
// per avatar, for each of two sitters in turn? If no, this route is dead
// and the parameter details do not matter. If yes, the details become an
// ordinary implementation problem.
//
// WHAT THIS DELIBERATELY DOES NOT ANSWER. CAMERA_POSITION and
// CAMERA_FOCUS are REGION coordinates, not object-relative, so a moving
// or rotating piece of furniture would need them re-driven as it moves -
// work the sim does for free with llSetLinkCamera today. Whether an
// object-relative mode exists that avoids this is the next question, not
// this one.
//
// Each seat gets a visibly different distance, so the two testers can
// simply say which of them is close and which is far.
list CAM_DISTANCE = [1.5, 3.0, 6.0];

camera_for(key av, integer seat)
{
    llRequestPermissions(av, PERMISSION_CONTROL_CAMERA);
    if (!(llGetPermissions() & PERMISSION_CONTROL_CAMERA))
    {
        llOwnerSay("   CAMERA: permission NOT granted synchronously for "
            + llKey2Name(av) + " - this route is dead.");
        return;
    }
    if (llGetPermissionsKey() != av)
    {
        llOwnerSay("   CAMERA: permission landed on the wrong avatar.");
        return;
    }
    llSetCameraParams([
        CAMERA_ACTIVE, 1,
        CAMERA_DISTANCE, llList2Float(CAM_DISTANCE, seat),
        CAMERA_BEHINDNESS_ANGLE, 0.0,
        CAMERA_PITCH, 10.0
    ]);
    llOwnerSay("   CAMERA: granted, distance "
        + (string)llList2Float(CAM_DISTANCE, seat)
        + " for " + llKey2Name(av));
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

default
{
    state_entry()
    {
        // Armed, and it STAYS armed. See the header: clearing it makes
        // the prim unsittable for everyone. Aimed at the middle seat,
        // which is where arrival 1 will land regardless of where they
        // clicked - that one has no click information to give.
        llSitTarget(llList2Vector(SEATS, 1), ZERO_ROTATION);
        KNOWN = [];
        llOwnerSay("sitpick ready, target armed at the middle seat."
            + " Avatar 1 sits anywhere (they get the middle);"
            + " avatar 2 right-clicks the LEFT or RIGHT end.");
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
            // Their camera is NOT cleared here: the permission is
            // single-valued and by now belongs to whoever was served
            // last, so there is nothing to clear it through. Standing up
            // should revoke it by itself, the same way it revokes
            // TRIGGER_ANIMATION - and whether it actually does is worth
            // noticing during the run. Escape resets the camera if not.
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
            camera_for(llGetLinkKey(l), pick);
            ++i;
        }
    }
}
