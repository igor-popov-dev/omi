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
}
