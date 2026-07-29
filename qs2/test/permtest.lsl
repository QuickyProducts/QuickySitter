/*
 * permtest - throwaway diagnostic, NOT product code
 *
 * ONE QUESTION: can a single script drive the animations of every seated
 * avatar from one event handler?
 *
 * qs2/DESIGN.md §3 said no. Measured 2026-07-29 with two seats: yes. The
 * grant is synchronous for an avatar already sitting on the object, so
 * llRequestPermissions returns with the permission in effect and the
 * following llStartAnimation reaches that avatar. run_time_permissions
 * arrives afterwards and is a notification, not a gate.
 *
 * If that holds at four and eight seats too, [QS]anim disappears and the
 * engine is boot + core + seat + menu regardless of seat count.
 *
 * WHAT CAN STILL GO WRONG AT SCALE
 *
 * Not the permissions: the handler. A script that runs past its time
 * slice is suspended between bytecodes and resumes in a later frame,
 * which would put the SYNC offset back, just at a different seam. So
 * every phase reports how long its loop took. A simulator frame is about
 * 22 ms at 45 fps; comfortably under that means the whole set of seats
 * starts in one frame.
 *
 * SETUP
 *   1. Link as many prims as you want seats. state_entry gives every
 *      prim a sit target.
 *   2. Seat avatars on some or all of them. The test runs over whoever
 *      is actually sitting, so two avatars on four prims is a valid
 *      two-seat run.
 *   3. TURN THE AVATARS' AO OFF. With an AO running llGetAnimationList
 *      is worthless: two identical runs gave 7->8 and then 8->8 for the
 *      same call. This was the single biggest source of confusion in
 *      testing.
 *   4. Touch four times: COLD STRESS, start, pose change, stop.
 *
 * THE COLD READING IS THE POINT. The very first touch after a reset
 * issues STRESS_PAIRS acquire+start pairs, which is the handler length
 * an eight seater would have, against avatars nobody has held
 * permission for yet. Everything after it is warm and cheap. To repeat
 * the measurement, reset the script.
 *
 * ANIMATIONS: a matched looping pair, so phase can be judged by eye as
 * well as by counter. Both must be in the prim's inventory.
 */

string ANIM_A = "MW-sway-female";
string ANIM_B = "MW-sway-male";

// Deliberately far more than any real piece of furniture would need.
//
// MEASURED 2026-07-29: llGetTime resolves in whole frames. Every reading
// across three sessions was 22, 45 or 66 ms, that is 1, 2 or 3 times the
// ~22 ms frame, and eight pairs once read 45 ms while two pairs read 66
// in the run before. The clock cannot resolve the thing it was pointed
// at, and an earlier cold-versus-warm story read out of those numbers
// was quantisation noise rather than a finding.
//
// So measure something the clock CAN see: enough repetitions that the
// total is seconds rather than frames, then divide. At 200 pairs a cost
// of 3 ms per pair shows up as 600 ms and 0.1 ms as 20 ms, both of which
// are unambiguous.
integer STRESS_PAIRS = 200;

integer phase;
list    OCC;          // avatars currently seated, in link order
key     uuidA;
key     uuidB;

string anim_for(integer i)
{
    if (i % 2 == 0) return ANIM_A;
    return ANIM_B;
}

string other_anim(integer i)
{
    if (i % 2 == 0) return ANIM_B;
    return ANIM_A;
}

gather()
{
    OCC = [];
    integer l = 1;
    integer n = llGetNumberOfPrims();
    while (l <= n)
    {
        key av = llAvatarOnLinkSitTarget(l);
        if (av != NULL_KEY) OCC += av;
        ++l;
    }
}

// -1 = cannot tell (animation not full-perm), else 0/1
integer playing(key av, key uuid)
{
    if (uuid == NULL_KEY) return -1;
    if (llListFindList(llGetAnimationList(av), [uuid]) == -1) return 0;
    return 1;
}

report(string tag)
{
    integer i = 0;
    integer n = llGetListLength(OCC);
    while (i < n)
    {
        key av = llList2Key(OCC, i);
        string exact = "";
        integer pa = playing(av, uuidA);
        if (pa != -1) exact = "  A=" + (string)pa + " B=" + (string)playing(av, uuidB);
        llOwnerSay(tag + " seat " + (string)i
            + "  av=" + llGetSubString((string)av, 0, 7)
            + exact
            + "  anims=" + (string)llGetListLength(llGetAnimationList(av)));
        ++i;
    }
}

timing(string tag, float dt, integer calls)
{
    // Per-call cost is the only figure worth printing. The total is
    // frame-quantised, so a small total says nothing; the per-call
    // number only becomes meaningful once the total is well above a
    // frame, which is what STRESS_PAIRS is for.
    llOwnerSay(tag + ": " + (string)calls + " acquire+start in "
        + (string)llRound(dt * 1000.0) + " ms"
        + "  =  " + (string)(llRound(dt * 10000.0 / (float)calls) / 10.0)
        + " ms each"
        + "  ->  8 seats would take "
        + (string)llRound(dt * 8000.0 / (float)calls) + " ms"
        + "  (frame ~22 ms)");
}

default
{
    state_entry()
    {
        integer l = 1;
        integer n = llGetNumberOfPrims();
        while (l <= n)
        {
            llLinkSitTarget(l, <0.0, 0.0, 0.6>, ZERO_ROTATION);
            ++l;
        }

        if (llGetInventoryType(ANIM_A) != INVENTORY_ANIMATION)
            llOwnerSay("permtest: \"" + ANIM_A + "\" is not in this prim.");
        if (llGetInventoryType(ANIM_B) != INVENTORY_ANIMATION)
            llOwnerSay("permtest: \"" + ANIM_B + "\" is not in this prim.");

        uuidA = llGetInventoryKey(ANIM_A);
        uuidB = llGetInventoryKey(ANIM_B);
        if (uuidA == NULL_KEY)
            llOwnerSay("permtest: animations are not full-perm, so exact A=/B="
                + " readings are unavailable. TURN THE AO OFF or the counts"
                + " mean nothing.");

        phase = 0;
        llOwnerSay("permtest ready on " + (string)n + " prim(s)."
            + " Seat avatars, AO off, then touch."
            + " 1=COLD STRESS 2=start 3=pose change 4=stop");
    }

    changed(integer change)
    {
        if (change & CHANGED_LINK) llResetScript();
    }

    touch_start(integer num)
    {
        gather();
        integer n = llGetListLength(OCC);
        if (n < 2)
        {
            llOwnerSay("permtest: need at least two seated avatars, have "
                + (string)n + ".");
            return;
        }

        integer i;
        float t0;

        if (phase == 0)
        {
            // PHASE 1, COLD STRESS. Runs FIRST on purpose.
            //
            // Measured 2026-07-29: eight pairs took 22 ms while two took
            // 66 ms in the same session. Repetition makes the calls
            // cheaper, so the first acquisition of an avatar appears to
            // cost real work and later ones come from somewhere warm.
            // That is a hypothesis from three data points, not a finding.
            //
            // It matters because a real piece of furniture is COLD: four
            // people sit down, then somebody picks a couple pose. The
            // warm 2.75 ms per pair would mean an eight seater starts
            // inside one frame; the cold 33 ms would mean a spread of
            // about 260 ms, which is roughly a tenth of a sway loop and
            // would be visible.
            //
            // So this number, taken immediately after a reset, is the
            // one the architecture stands or falls on.
            t0 = llGetTime();
            i = 0;
            while (i < STRESS_PAIRS)
            {
                llRequestPermissions(llList2Key(OCC, i % n), PERMISSION_TRIGGER_ANIMATION);
                llStartAnimation(anim_for(i % n));
                ++i;
            }
            timing("COLD STRESS", llGetTime() - t0, STRESS_PAIRS);

            llSleep(1.0);
            report("COLD ");

            i = 0;
            while (i < n)
            {
                llRequestPermissions(llList2Key(OCC, i), PERMISSION_TRIGGER_ANIMATION);
                llStopAnimation(anim_for(i));
                ++i;
            }
            phase = 1;
            llOwnerSay("permtest: that was the COLD number. Everything from"
                + " here is warm. RESET the script for another cold reading."
                + " Touch for the normal start.");
            return;
        }

        if (phase == 1)
        {
            // Acquire and start every seat, no return to the event loop
            // in between. Warm by now, so compare against the 66 ms this
            // took cold.
            t0 = llGetTime();
            i = 0;
            while (i < n)
            {
                llRequestPermissions(llList2Key(OCC, i), PERMISSION_TRIGGER_ANIMATION);
                llStartAnimation(anim_for(i));
                ++i;
            }
            timing("START (warm)", llGetTime() - t0, n);
            phase = 2;
            llSleep(1.0);
            report("START");
            llOwnerSay("permtest: do they sway IN PHASE? Touch for the pose change.");
            return;
        }

        if (phase == 2)
        {
            // PHASE 3, the pattern the engine would use. sitA overlaps
            // per avatar (start new, sleep, stop old) so nobody drops
            // into their default pose; that sleep would tear the frame
            // apart mid-cycle, so it becomes two passes with ONE shared
            // sleep. Starts stay in one frame, and the stops end up
            // synchronous with each other as well, which v1 never
            // manages across N independent scripts.
            t0 = llGetTime();
            i = 0;
            while (i < n)
            {
                llRequestPermissions(llList2Key(OCC, i), PERMISSION_TRIGGER_ANIMATION);
                llStartAnimation(other_anim(i));
                ++i;
            }
            float dtStart = llGetTime() - t0;

            llSleep(0.2);                       // the overlap, once for everybody

            i = 0;
            while (i < n)
            {
                llRequestPermissions(llList2Key(OCC, i), PERMISSION_TRIGGER_ANIMATION);
                llStopAnimation(anim_for(i));
                ++i;
            }

            timing("SWAP pass 1", dtStart, n);
            phase = 3;
            llSleep(1.0);
            report("SWAP");
            llOwnerSay("permtest: counts must be UNCHANGED (one off, one on)."
                + " Touch to stop.");
            return;
        }

        {
            // PHASE 4, plain stop.
            i = 0;
            while (i < n)
            {
                llRequestPermissions(llList2Key(OCC, i), PERMISSION_TRIGGER_ANIMATION);
                llStopAnimation(other_anim(i));
                ++i;
            }
            phase = 1;
            llSleep(1.0);
            report("STOP ");
            llOwnerSay("permtest: all A=0 B=0 means nothing was left behind."
                + " RESET the script for another cold reading; touching again"
                + " only repeats the warm cycle.");
        }
    }

    run_time_permissions(integer perm)
    {
        // Fires once per request, always after the work is done, and
        // always reporting the LAST key. It cannot distinguish the
        // requests and the engine must ignore it outright. Logged here
        // only to show that ordering.
        llOwnerSay("permtest: run_time_permissions perm=" + (string)perm
            + " for " + llGetSubString((string)llGetPermissionsKey(), 0, 7));
    }
}
