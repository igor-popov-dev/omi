import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/phone_call.dart';
import 'package:omi/providers/phone_call_provider.dart';

/// The teardown of a call schedules a DELAYED write of the screen's state (two seconds,
/// so the user gets to read "Call Ended"). One call reports its end more than once — we
/// hang up locally and the SDK confirms a signalling round-trip later — so two of those
/// writes get scheduled, a round-trip apart. The first one is the one that belongs to the
/// call; the second one is a write with no owner, and it lands on whatever is on screen
/// two seconds later. If that is the NEXT call, it takes the state back to `idle`, which
/// un-pauses the phone's own always-on recording on top of a live call (the one-call-two-
/// conversations defect of tick 22) and clears `_cloudAudio`, so the hang-up button then
/// talks to the SDK that is not carrying the call.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  test('the SDK confirming a hang-up we already handled does not tear the call down twice', () async {
    final provider = PhoneCallProvider();
    addTearDown(provider.dispose);

    provider.reportCallState(PhoneCallState.connecting);
    provider.reportCallState(PhoneCallState.active);

    await provider.endCall(); // the user taps hang up: teardown #1
    expect(provider.callState, PhoneCallState.ended);

    // The SDK confirms the disconnect a moment later. `_setCallState` swallows the state
    // (it is already `ended`), but the teardown behind it used to run a second time.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    provider.reportCallState(PhoneCallState.ended);

    // The reset scheduled by teardown #1 lands here and gives the screen back.
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    expect(provider.callState, PhoneCallState.idle, reason: 'the call screen must clear two seconds after the end');

    // The user redials inside the window between the two teardowns.
    provider.reportCallState(PhoneCallState.connecting);
    expect(provider.ambientCapture.held, isTrue, reason: 'a dialling call must hush the always-on recording');

    // Where the second, ownerless reset would have landed.
    await Future<void>.delayed(const Duration(milliseconds: 700));

    expect(provider.callState, PhoneCallState.connecting,
        reason: 'a reset left over from the previous call must not idle the new one');
    expect(provider.ambientCapture.held, isTrue,
        reason: 'the always-on recording must not come back on top of the new call');
  });

  test('a call that ends on its own is still torn down — the guard is on the call, not the caller', () async {
    final provider = PhoneCallProvider();
    addTearDown(provider.dispose);

    provider.reportCallState(PhoneCallState.connecting);
    provider.reportCallState(PhoneCallState.active);
    expect(provider.ambientCapture.held, isTrue);

    // Nobody hangs up locally here: the other side does, and the SDK is the only reporter.
    provider.reportCallState(PhoneCallState.ended);
    expect(provider.callState, PhoneCallState.ended);
    expect(provider.ambientCapture.held, isFalse, reason: 'the always-on recording comes back when the call ends');

    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(provider.callState, PhoneCallState.idle, reason: 'the one teardown there was must still clear the screen');
  });

  test('a reset in flight when the user signs out does not land on the call placed after', () async {
    final provider = PhoneCallProvider();
    addTearDown(provider.dispose);

    provider.reportCallState(PhoneCallState.connecting);
    provider.reportCallState(PhoneCallState.active);
    provider.reportCallState(PhoneCallState.ended); // reset scheduled two seconds out

    // Signing out gives the screen back at once, without waiting for that reset.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    provider.clearUserData();
    expect(provider.callState, PhoneCallState.idle);

    // Signed in again, dialling well inside the two seconds. `clearUserData` leaves the
    // provider deaf to call events on purpose; a new session wakes it the same way a dial
    // does, by loading the verified numbers.
    await provider.loadVerifiedNumbers();
    provider.reportCallState(PhoneCallState.connecting);
    expect(provider.ambientCapture.held, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(provider.callState, PhoneCallState.connecting,
        reason: 'a reset from before the sign-out must not idle the call placed after it');
    expect(provider.ambientCapture.held, isTrue);
  });
}
