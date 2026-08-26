import 'package:flutter_test/flutter_test.dart';

import 'package:omi/utils/batch_recording.dart';
import 'package:omi/utils/offline_sync_policy.dart';

/// Who may drain offline recordings without asking. Upstream: nobody on a
/// custom STT provider, because those files would be transcribed on Omi and
/// billed. Self-host: the same user, because the pre-recorded path goes to
/// their own STT — the trade-off the consent gate protects against is absent.
void main() {
  group('offlineSyncNeedsConsent', () {
    test('Omi transcription — no consent needed either way', () {
      expect(offlineSyncNeedsConsent(false, selfHostOwnsOfflineStt: false), isFalse);
      expect(offlineSyncNeedsConsent(false, selfHostOwnsOfflineStt: true), isFalse);
    });

    test('custom STT on a stock build — consent needed (upstream behaviour)', () {
      expect(offlineSyncNeedsConsent(true, selfHostOwnsOfflineStt: false), isTrue);
    });

    test('custom STT on a self-host build — no consent, files stay on own stack', () {
      expect(offlineSyncNeedsConsent(true, selfHostOwnsOfflineStt: true), isFalse);
    });

    test('defaults to upstream behaviour when the dart-define is absent', () {
      expect(offlineSyncNeedsConsent(true), isTrue);
    });
  });

  group('canAutoUploadPhoneRecordings — self-host', () {
    test('custom-STT user auto-uploads when their own backend owns offline STT', () {
      expect(
        canAutoUploadPhoneRecordings(
          useCustomStt: true,
          autoSyncOfflineRecordings: true,
          isUploading: false,
          selfHostOwnsOfflineStt: true,
        ),
        isTrue,
      );
    });

    test('the other gates still hold on a self-host build', () {
      expect(
        canAutoUploadPhoneRecordings(
          useCustomStt: true,
          autoSyncOfflineRecordings: false,
          isUploading: false,
          selfHostOwnsOfflineStt: true,
        ),
        isFalse,
      );
      expect(
        canAutoUploadPhoneRecordings(
          useCustomStt: true,
          autoSyncOfflineRecordings: true,
          isUploading: true,
          selfHostOwnsOfflineStt: true,
        ),
        isFalse,
      );
    });
  });
}
