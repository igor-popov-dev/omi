import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_voximplant/flutter_voximplant.dart';
import 'package:omi/backend/schema/phone_call.dart';
import 'package:omi/models/audio_route.dart';
import 'package:omi/services/voximplant_call_service.dart';

void main() {
  group('VoximplantLogin.fromJson', () {
    test('reads the keyless half of the handshake', () {
      final login = VoximplantLogin.fromJson({
        'provider': 'voximplant',
        'hash': null,
        'user': 'phone@omijarvis.igor.voximplant.com',
        'node': 'Node4',
        'ttl': 300,
      });

      expect(login, isNotNull);
      expect(login!.hash, isNull);
      expect(login.node, 'Node4');
      expect(login.ttl, 300);
    });

    test('reads the half that carries the hash', () {
      final login = VoximplantLogin.fromJson({
        'provider': 'voximplant',
        'hash': 'deadbeef',
        'user': 'phone@omijarvis.igor.voximplant.com',
        'node': 'Node4',
        'ttl': 300,
      });

      expect(login?.hash, 'deadbeef');
    });

    test('a Twilio answer is not mistaken for a Voximplant one', () {
      // Both shapes carry `ttl`; only `provider` tells them apart, and getting this wrong
      // means logging in to the wrong cloud instead of failing.
      final login = VoximplantLogin.fromJson({'access_token': 'jwt', 'ttl': 3600, 'identity': 'uid'});
      expect(login, isNull);
    });

    test('a half-filled answer is refused rather than half-used', () {
      expect(VoximplantLogin.fromJson({'provider': 'voximplant', 'node': 'Node4', 'ttl': 300}), isNull);
      expect(
        VoximplantLogin.fromJson({'provider': 'voximplant', 'user': 'phone@a.b.voximplant.com', 'ttl': 300}),
        isNull,
      );
    });
  });

  group('VoximplantCallService.parseNode', () {
    test('accepts what the backend sends', () {
      expect(VoximplantCallService.parseNode('Node4'), VINode.Node4);
      expect(VoximplantCallService.parseNode('Node13'), VINode.Node13);
    });

    test('accepts the spelling the control panel shows', () {
      expect(VoximplantCallService.parseNode('VINode.Node4'), VINode.Node4);
      expect(VoximplantCallService.parseNode(' node4 '), VINode.Node4);
    });

    test('an unknown node is null, not a silent default', () {
      // Connecting to the wrong node fails at login with a misleading "invalid password".
      expect(VoximplantCallService.parseNode('Node99'), isNull);
      expect(VoximplantCallService.parseNode(''), isNull);
    });
  });

  group('VoximplantCallService.buildCustomData', () {
    test('carries the two ids the cloud scenario reads', () {
      final payload = VoximplantCallService.buildCustomData(
        uid: 'firebase-uid-28-characters-x',
        callId: '1755950000000',
      );

      expect(payload, isNotNull);
      final decoded = jsonDecode(payload!) as Map<String, dynamic>;
      expect(decoded['uid'], 'firebase-uid-28-characters-x');
      expect(decoded['call_id'], '1755950000000');
    });

    test('refuses a payload over Voximplant\'s 200-byte limit', () {
      // The cloud silently drops customData that does not fit, and a call without uid is a
      // call without a transcript — better to fail here, where the reason is still visible.
      final payload = VoximplantCallService.buildCustomData(uid: 'u' * 300, callId: '1');
      expect(payload, isNull);
    });
  });

  group('VoximplantCallService audio routes', () {
    test('every device maps to a route and back', () {
      for (final device in VIAudioDevice.values) {
        final route = VoximplantCallService.audioRouteOf(device);
        expect(route.name, isNotEmpty);
        expect(VoximplantCallService.parseAudioDevice(route.id), device);
      }
    });

    test('the speaker keeps its own type so the speaker button can light up', () {
      expect(VoximplantCallService.audioRouteOf(VIAudioDevice.Speaker).type, AudioRouteType.speaker);
      expect(VoximplantCallService.audioRouteOf(VIAudioDevice.Earpiece).type, AudioRouteType.iPhone);
    });

    test('an unknown route id is refused', () {
      expect(VoximplantCallService.parseAudioDevice('Telepathy'), isNull);
    });
  });

  group('VoximplantCallService microphone foreground service', () {
    /// Records what the platform channel would have been asked to do.
    ({VoximplantCallService service, List<bool> calls}) serviceWatching({bool refuse = false}) {
      final calls = <bool>[];
      final service = VoximplantCallService(holdMicService: (hold) async {
        calls.add(hold);
        return !(refuse && hold);
      });
      return (service: service, calls: calls);
    }

    test('the states that carry audio hold the service, the rest release it', () {
      // Ringing counts: the user can put the app in the background while it is still
      // ringing, and Android suspends the microphone of a backgrounded app regardless.
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.connecting), isTrue);
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.ringing), isTrue);
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.active), isTrue);
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.ended), isFalse);
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.failed), isFalse);
      expect(VoximplantCallService.micServiceHeldIn(PhoneCallState.idle), isFalse);
    });

    test('a whole call holds the service once and releases it once', () async {
      final w = serviceWatching();
      for (final state in [
        PhoneCallState.connecting,
        PhoneCallState.ringing,
        PhoneCallState.active,
        PhoneCallState.ended,
      ]) {
        w.service.emitState(state);
      }
      await pumpEventQueue();

      // Not [true, true, true, false]: starting an already running service is a no-op the
      // user pays for in wakeups, and the released state has to be reached exactly once.
      expect(w.calls, [true, false]);
    });

    test('a failed call releases the service just like a normal hangup', () async {
      final w = serviceWatching();
      w.service.emitState(PhoneCallState.connecting);
      w.service.emitState(PhoneCallState.failed);
      await pumpEventQueue();

      expect(w.calls, [true, false]);
    });

    test('a refused service is not "stopped" afterwards', () async {
      // Android can refuse to start a foreground service (no permission, background start).
      // Stopping what never started would be harmless noise here, but the same bookkeeping
      // error in the other direction leaves the microphone notification up for good.
      final w = serviceWatching(refuse: true);
      w.service.emitState(PhoneCallState.connecting);
      await pumpEventQueue();
      w.service.emitState(PhoneCallState.ended);
      await pumpEventQueue();

      expect(w.calls, [true]);
    });

    test('two states in the same turn do not start the service twice', () async {
      // Both emits land before the first await resolves — the flag has to be set before it.
      final w = serviceWatching();
      w.service.emitState(PhoneCallState.connecting);
      w.service.emitState(PhoneCallState.ringing);
      await pumpEventQueue();

      expect(w.calls, [true]);
    });

    test('the state still reaches the listener while the service is being held', () async {
      final w = serviceWatching();
      final seen = <PhoneCallState>[];
      w.service.onCallStateChanged = seen.add;
      w.service.emitState(PhoneCallState.active);
      await pumpEventQueue();

      expect(seen, [PhoneCallState.active]);
    });
  });
}
