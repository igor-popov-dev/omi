import 'package:flutter_test/flutter_test.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/models/stt_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  test('no saved config and no baked-in default STT URL falls back to the omi default', () {
    // This build's Env.defaultSttUrl is empty (no OMI_DEFAULT_STT_URL dart-define passed to
    // `flutter test`), so this only exercises the empty-define branch. The self-host default
    // (self-host builds pass a real URL) is exercised end-to-end via the rebuilt APK instead,
    // since Env.defaultSttUrl is a compile-time String.fromEnvironment constant.
    expect(Env.defaultSttUrl, isEmpty);

    final config = SharedPreferencesUtil().customSttConfig;

    expect(config.provider, SttProvider.omi);
    expect(config.isEnabled, isFalse);
  });
}
