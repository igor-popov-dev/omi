import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/voice_call/voice_call_notification_permission.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  setUp(resetVoiceCallNotificationPermissionPrompt);

  test('granted: nothing is requested', () async {
    var requests = 0;
    await ensureVoiceCallNotificationPermission(
      isAndroid: true,
      status: () async => PermissionStatus.granted,
      request: () async {
        requests++;
        return PermissionStatus.granted;
      },
      appVisible: () => true,
    );
    expect(requests, 0);
  });

  test('denied while the app is visible: requested once per run', () async {
    var requests = 0;
    Future<void> run() => ensureVoiceCallNotificationPermission(
          isAndroid: true,
          status: () async => PermissionStatus.denied,
          request: () async {
            requests++;
            return PermissionStatus.denied;
          },
          appVisible: () => true,
        );
    await run();
    await run();
    expect(requests, 1);
  });

  test('denied while the app is in the background (pendant start): no dialog', () async {
    var requests = 0;
    await ensureVoiceCallNotificationPermission(
      isAndroid: true,
      status: () async => PermissionStatus.denied,
      request: () async {
        requests++;
        return PermissionStatus.granted;
      },
      appVisible: () => false,
    );
    expect(requests, 0);
  });

  test('permanently denied: not re-asked', () async {
    var requests = 0;
    await ensureVoiceCallNotificationPermission(
      isAndroid: true,
      status: () async => PermissionStatus.permanentlyDenied,
      request: () async {
        requests++;
        return PermissionStatus.granted;
      },
      appVisible: () => true,
    );
    expect(requests, 0);
  });

  test('a throwing status check is swallowed (fail-open)', () async {
    await ensureVoiceCallNotificationPermission(
      isAndroid: true,
      status: () async => throw StateError('no channel'),
      appVisible: () => true,
    );
  });

  test('non-Android: no-op', () async {
    var checks = 0;
    await ensureVoiceCallNotificationPermission(
      isAndroid: false,
      status: () async {
        checks++;
        return PermissionStatus.denied;
      },
    );
    expect(checks, 0);
  });
}
