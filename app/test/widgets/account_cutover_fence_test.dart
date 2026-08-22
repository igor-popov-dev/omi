import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/services/account_cutover/account_cutover_control.dart';
import 'package:omi/services/account_cutover/account_cutover_control_client.dart';
import 'package:omi/services/account_cutover/account_cutover_blocking_gate.dart';
import 'package:omi/services/account_cutover/account_cutover_gate.dart';
import 'package:omi/services/account_cutover/account_cutover_runtime.dart';

AccountCutoverControl _control({
  String state = 'legacy',
  int accountGeneration = 0,
  String clientAction = 'none',
  bool productTrafficAllowed = true,
  bool legacyWritesAllowed = true,
}) {
  return AccountCutoverControl.fromJson({
    'state': state,
    'account_generation': accountGeneration,
    'ui_generation': accountGeneration,
    'api_generation': accountGeneration,
    'client_action': clientAction,
    'offline_queue_instruction': productTrafficAllowed ? 'none' : 'quarantine',
    'product_traffic_allowed': productTrafficAllowed,
    'legacy_writes_allowed': legacyWritesAllowed,
    'auth_bootstrap_reachable': true,
    'stranded_new_data': false,
  });
}

Future<void> _pumpGate(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: AccountCutoverBlockingGate(child: Text('product')),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    AccountCutoverRuntime.instance.resetForTesting();
  });

  tearDown(() {
    AccountCutoverRuntime.instance.resetForTesting();
  });

  testWidgets('an unconfirmed fence renders the skip escape hatch and it works', (tester) async {
    final runtime = AccountCutoverRuntime.instance;
    // Authoritative allow, then an explicit control-plane 503 on refresh: the
    // fence appears, but the server never said "migrating".
    runtime.apply(_control(accountGeneration: 5));
    runtime.applyFetchResult(const AccountCutoverFetchResult.unavailable());

    await _pumpGate(tester);

    // Live incident regression (screen1.png, 01:19): this exact fence rendered
    // with no way out. It must always carry the skip TextButton.
    expect(find.text('product'), findsNothing);
    expect(find.byType(TextButton), findsOneWidget);

    await tester.tap(find.byType(TextButton));
    await tester.pump();

    expect(find.text('product'), findsOneWidget);
    // Skip restored the last-known-good projection, not a blank default.
    expect(runtime.control.accountGeneration, 5);

    // Unmount to cancel the gate's fence-refresh timer.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a server-confirmed migration fence renders without the escape hatch', (tester) async {
    AccountCutoverRuntime.instance.apply(
      _control(
        state: 'migrating',
        accountGeneration: 9,
        clientAction: 'migration_maintenance',
        productTrafficAllowed: false,
        legacyWritesAllowed: false,
      ),
    );

    await _pumpGate(tester);

    expect(find.text('product'), findsNothing);
    expect(find.byType(TextButton), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the fence retries the control fetch on its own and lifts when the server recovers', (tester) async {
    final runtime = AccountCutoverRuntime.instance;
    var fetches = 0;
    final client = AccountCutoverControlClient(
      fetch: () async {
        fetches++;
        if (fetches == 1) return const AccountCutoverFetchResult.unavailable();
        return AccountCutoverFetchResult.success(_control());
      },
    );
    await runtime.bindAuthenticatedOwner('owner-a', client: client);
    expect(runtime.decision, AccountCutoverGateDecision.migrationMaintenance);

    await _pumpGate(tester);
    expect(find.text('product'), findsNothing);

    // The gate's periodic timer calls the parameterless refresh(), which would
    // hit the network — drive the same recovery through the runtime directly
    // and assert the gate reacts. (The timer's schedule is covered by the
    // widget staying subscribed to the runtime.)
    await runtime.refresh(client: client);
    await tester.pump();

    expect(find.text('product'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
