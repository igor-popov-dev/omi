import 'package:flutter_test/flutter_test.dart';
import 'package:omi/env/env.dart';
import 'package:omi/models/stt_provider.dart';

void main() {
  test('custom provider with no explicit url falls back to the baked-in default STT URL', () {
    // This build's Env.defaultSttUrl is empty (no OMI_DEFAULT_STT_URL dart-define
    // passed to `flutter test`), so this only exercises the empty-define branch —
    // same limitation as custom_stt_config_default_fallback_test.dart, since
    // Env.defaultSttUrl is a compile-time String.fromEnvironment constant that
    // can't be overridden at test time. The non-empty branch (a self-host build
    // pointing this at our STT router instead of the unreachable
    // 127.0.0.1:8080 placeholder) is exercised end-to-end via the rebuilt APK.
    expect(Env.defaultSttUrl, isEmpty);

    final config = SttProviderConfig.get(SttProvider.custom).buildRequestConfig(language: 'en');

    expect(config['url'], 'http://127.0.0.1:8080/inference');
  });
}
