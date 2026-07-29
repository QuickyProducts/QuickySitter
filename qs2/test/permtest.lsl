/*
 * permtest - throwaway diagnostic, NOT product code
 *
 * ONE QUESTION: can a single script start animations on TWO seated
 * avatars within one event handler?
 *
 * Everything in qs2/DESIGN.md §3 rests on "no". That rejection assumed
 * llRequestPermissions costs an event round trip per avatar, so each
 * seat's animation starts a frame later than the previous one, which for
 * looping SYNC poses is a permanent phase offset rather than a stutter.
 *
 * The llGetPermissionsKey wiki page says something that may contradict
 * it: "The result of granting permissions affects the return of
 * llGetPermissions and llGetPermissionsKey immediately, despite the
 * run_time_permissions event being queued." For an avatar already
 * sitting on the object the grant needs no dialog, so the simulator may
 * be able to do it synchronously.
 *
 * If it is synchronous, [QS]anim disappears: the whole engine becomes
 * boot + core + seat + menu regardless of seat count, and that would
 * have been true in LSL all along.
 *
 * SETUP
 *   1. Two prims, linked. Both get a sit target from state_entry.
 *   2. Two avatars, one on each. An alt works; they must SIT, because
 *      auto-grant only applies to avatars seated on the object. A
 *      non-seated avatar would get a permission dialog and the test
 *      would measure nothing.
 *   3. Touch to run. Touch again to run the stop path.
 *
 * WHAT THE OUTPUT MEANS
 *   "granted immediately" twice, and both avatars gain an animation
 *      -> synchronous. DESIGN §3 is wrong and anim can go.
 *   first granted, second not (or key does not change)
 *      -> asynchronous. DESIGN §3 stands as written.
 *   both granted but only one avatar animates
 *      -> the grant is bookkeeping only; treat as asynchronous.
 *
 * ANIMATIONS. A matched looping pair, so the second question can be
 * answered by eye as well as by counter: if the two avatars sway IN
 * PHASE, the starts landed in the same frame. Out of phase means they
 * did not, and for a SYNC couple pose that offset is permanent rather
 * than a one-off stutter.
 *
 * Both animations must be IN THE PRIM'S INVENTORY. This is not a
 * built-in pair.
 */

string ANIM_A = "MW-sway-female";
string ANIM_B = "MW-sway-male";

integer started;

integer anim_count(key av)
{
    // Definitive evidence. Eyeballing is unreliable here because a sit
    // pose competes with whatever we start.
    return llGetListLength(llGetAnimationList(av));
}

report(string phase, key av, integer before, integer after, integer granted, key kAfter)
{
    llOwnerSay(phase + "  av=" + llGetSubString((string)av, 0, 7)
        + "  granted=" + (string)granted
        + "  keyMatches=" + (string)(kAfter == av)
        + "  anims " + (string)before + " -> " + (string)after);
}

default
{
    state_entry()
    {
        llLinkSitTarget(1, <0.0, 0.0, 0.6>, ZERO_ROTATION);
        if (llGetNumberOfPrims() > 1)
            llLinkSitTarget(2, <0.0, 0.0, 0.6>, ZERO_ROTATION);
        else
            llOwnerSay("permtest: link a second prim, one sit target per prim.");

        // Fail loudly here rather than reporting granted=1 with no
        // visible animation, which would read as "the grant is
        // bookkeeping only" and send the whole conclusion sideways.
        if (llGetInventoryType(ANIM_A) != INVENTORY_ANIMATION)
            llOwnerSay("permtest: \"" + ANIM_A + "\" is not in this prim.");
        if (llGetInventoryType(ANIM_B) != INVENTORY_ANIMATION)
            llOwnerSay("permtest: \"" + ANIM_B + "\" is not in this prim.");

        started = FALSE;
        llOwnerSay("permtest ready. Seat two avatars, then touch.");
    }

    changed(integer change)
    {
        if (change & CHANGED_LINK) llResetScript();
    }

    touch_start(integer n)
    {
        key a = llAvatarOnLinkSitTarget(1);
        key b = llAvatarOnLinkSitTarget(2);
        if (a == NULL_KEY || b == NULL_KEY)
        {
            llOwnerSay("permtest: need an avatar on BOTH prims. Have "
                + (string)(a != NULL_KEY) + " / " + (string)(b != NULL_KEY));
            return;
        }

        integer beforeA = anim_count(a);
        integer beforeB = anim_count(b);

        if (!started)
        {
            // The whole test is these six lines: two requests and two
            // starts, no return to the event loop in between.
            llRequestPermissions(a, PERMISSION_TRIGGER_ANIMATION);
            integer okA = (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION) != 0;
            key keyA = llGetPermissionsKey();
            if (okA) llStartAnimation(ANIM_A);

            llRequestPermissions(b, PERMISSION_TRIGGER_ANIMATION);
            integer okB = (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION) != 0;
            key keyB = llGetPermissionsKey();
            if (okB) llStartAnimation(ANIM_B);

            started = TRUE;
            // Give the simulator a moment to apply, then read back.
            llSleep(1.0);
            report("START a", a, beforeA, anim_count(a), okA, keyA);
            report("START b", b, beforeB, anim_count(b), okB, keyB);
            llOwnerSay("permtest: touch again for the stop path.");
            return;
        }

        // Stop path. A pose CHANGE needs this direction too, and it is
        // the one that hurts: requesting for b revoked our hold on a, so
        // stopping a means acquiring it again.
        llRequestPermissions(a, PERMISSION_TRIGGER_ANIMATION);
        integer sA = (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION) != 0;
        key skeyA = llGetPermissionsKey();
        if (sA) llStopAnimation(ANIM_A);

        llRequestPermissions(b, PERMISSION_TRIGGER_ANIMATION);
        integer sB = (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION) != 0;
        key skeyB = llGetPermissionsKey();
        if (sB) llStopAnimation(ANIM_B);

        started = FALSE;
        llSleep(1.0);
        report("STOP  a", a, beforeA, anim_count(a), sA, skeyA);
        report("STOP  b", b, beforeB, anim_count(b), sB, skeyB);
    }

    run_time_permissions(integer perm)
    {
        // If this fires AFTER the report lines above, the grant was
        // asynchronous and the flags read TRUE for some other reason.
        // Ordering here is a large part of the answer.
        llOwnerSay("permtest: run_time_permissions fired, perm=" + (string)perm
            + " for " + llGetSubString((string)llGetPermissionsKey(), 0, 7));
    }
}
