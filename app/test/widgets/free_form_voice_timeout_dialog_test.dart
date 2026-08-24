// The "Voice mode auto-off" picker (priority 22.08 step 6).
//
// Worth a widget test rather than trusting the shape by eye: the dialog is the
// only place the value can be changed, and the two ways out of it (Cancel vs
// Save) have to be told apart by the caller — a Cancel that returned the
// highlighted value would silently save a setting the user backed out of, and
// this setting decides whether a billed microphone stream keeps running.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/pages/settings/free_form_voice_timeout_dialog.dart';

void main() {
  Future<int?> openAndTap(WidgetTester tester, {required int current, required List<String> taps}) async {
    int? result;
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        ctx = context;
        return const Scaffold(body: SizedBox());
      }),
    ));

    final future = FreeFormVoiceTimeoutDialog.show(ctx, currentMinutes: current).then((value) => result = value);
    await tester.pumpAndSettle();

    for (final label in taps) {
      // The six options do not all fit the 800x600 test surface, and on a
      // short phone they will not fit there either — which is exactly why the
      // option list is inside a `SingleChildScrollView`. Scrolling to the row
      // before tapping tests that seam as well as the tap.
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }
    await future;
    return result;
  }

  testWidgets('Save returns the newly picked value', (tester) async {
    final picked = await openAndTap(tester, current: 3, taps: ['10 minutes', 'Save']);
    expect(picked, 10);
  });

  testWidgets('Cancel returns null even after a different option was highlighted', (tester) async {
    final picked = await openAndTap(tester, current: 3, taps: ['10 minutes', 'Cancel']);
    expect(picked, isNull);
  });

  testWidgets('Save without touching anything returns the current value unchanged', (tester) async {
    final picked = await openAndTap(tester, current: 5, taps: ['Save']);
    expect(picked, 5);
  });

  testWidgets('"Never" is offered and comes back as 0', (tester) async {
    final picked = await openAndTap(tester, current: 3, taps: ['Never', 'Save']);
    expect(picked, 0);
  });
}
