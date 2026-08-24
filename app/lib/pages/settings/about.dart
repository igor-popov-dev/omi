import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import 'package:omi/pages/settings/webview.dart';
import 'package:omi/utils/analytics/intercom.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class AboutOmiPage extends StatefulWidget {
  const AboutOmiPage({super.key});

  @override
  State<AboutOmiPage> createState() => _AboutOmiPageState();
}

class _AboutOmiPageState extends State<AboutOmiPage> {
  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Scaffold(
      backgroundColor: context.omi.bgPrimary,
      appBar: AppBar(title: Text(context.l10n.aboutOmi), backgroundColor: context.omi.bgPrimary),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(4, 0, 24, 0),
              title: Text(context.l10n.privacyPolicy, style: TextStyle(color: t.textPrimary)),
              trailing: const Icon(Icons.privacy_tip_outlined, size: 20),
              onTap: () {
                PlatformManager.instance.analytics.pageOpened('About Privacy Policy');
                routeToPage(
                  context,
                  PageWebView(url: 'https://www.omi.me/pages/privacy', title: context.l10n.privacyPolicyTitle),
                );
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(4, 0, 24, 0),
              title: Text(context.l10n.visitWebsite, style: TextStyle(color: t.textPrimary)),
              subtitle: const Text('https://omi.me'),
              trailing: const Icon(Icons.language_outlined, size: 20),
              onTap: () {
                PlatformManager.instance.analytics.pageOpened('About Visit Website');
                // routeToPage(context, const PageWebView(url: 'https://www.omi.me/', title: 'omi'));
                launchUrl(Uri.parse('https://www.omi.me/'));
              },
            ),
            ListTile(
              title: Text(context.l10n.helpOrInquiries, style: TextStyle(color: t.textPrimary)),
              subtitle: const Text('team@basedhardware.com'),
              contentPadding: const EdgeInsets.fromLTRB(4, 0, 24, 0),
              trailing: Icon(Icons.help_outline_outlined, color: t.textPrimary, size: 20),
              onTap: () async {
                await IntercomManager.instance.intercom.displayMessenger();
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(4, 0, 24, 0),
              title: Text(context.l10n.joinCommunity, style: TextStyle(color: t.textPrimary)),
              subtitle: Text(context.l10n.membersAndCounting),
              trailing: Icon(Icons.discord, color: t.accent, size: 20),
              onTap: () {
                PlatformManager.instance.analytics.pageOpened('About Join Discord');
                launchUrl(Uri.parse('http://discord.omi.me'));
              },
            ),
          ],
        ),
      ),
    );
  }
}
