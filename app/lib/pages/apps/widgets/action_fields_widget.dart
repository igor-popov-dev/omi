import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:omi/pages/apps/providers/add_app_provider.dart';
import 'package:omi/utils/app_localizations_helper.dart';
import 'package:omi/pages/settings/widgets/glass_icon_chip.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/widgets/omi_switch.dart';

class ActionFieldsWidget extends StatelessWidget {
  const ActionFieldsWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AddAppProvider>(
      builder: (context, provider, child) {
        final t = context.omi;

        // Only show if external integration is selected and actions are available
        if (!provider.isCapabilitySelectedById('external_integration') || provider.getActionTypes().isEmpty) {
          return const SizedBox.shrink();
        }

        return Column(
          children: [
            const SizedBox(height: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8.0, right: 8.0, bottom: 12.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Scopes', style: TextStyle(color: t.textSecondary, fontSize: 16)),
                      GestureDetector(
                        onTap: () {
                          launchUrl(Uri.parse('https://docs.omi.me/doc/developer/apps/Integrations'));
                        },
                        child: FaIcon(FontAwesomeIcons.solidCircleQuestion, color: t.textSecondary, size: 18),
                      ),
                    ],
                  ),
                ),
                // List of action items - aligned with "Scopes" text
                Padding(
                  padding: const EdgeInsets.only(left: 8.0),
                  child: Column(
                    children: [
                      ...provider.getActionTypes().asMap().entries.map((entry) {
                        final index = entry.key;
                        final actionType = entry.value;
                        final isSelected = provider.actions.any((action) => action['action'] == actionType.id);
                        final isLast = index == provider.getActionTypes().length - 1;

                        return Column(
                          children: [
                            Row(
                              children: [
                                SettingsIconChip.boxed(
                                    icon: (size) =>
                                        FaIcon(_getIconForAction(actionType.id), color: t.textSecondary, size: size)),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    actionType.getLocalizedTitle(context),
                                    style: TextStyle(color: t.textPrimary, fontSize: 16),
                                  ),
                                ),
                                OmiSwitch(
                                  value: isSelected,
                                  onChanged: (value) {
                                    if (value) {
                                      provider.addSpecificAction(actionType.id);
                                    } else {
                                      provider.removeActionByType(actionType.id);
                                    }
                                  },
                                  classicActiveThumbColor: t.accent,
                                ),
                              ],
                            ),
                            if (!isLast)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Divider(color: t.textSecondary, height: 1),
                              ),
                          ],
                        );
                      }),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  FaIconData _getIconForAction(String actionId) {
    switch (actionId) {
      case 'create_conversation':
        return FontAwesomeIcons.solidComment;
      case 'create_facts':
        return FontAwesomeIcons.solidLightbulb;
      case 'read_conversations':
        return FontAwesomeIcons.solidComments;
      case 'read_memories':
        return FontAwesomeIcons.brain;
      case 'read_tasks':
        return FontAwesomeIcons.listCheck;
      default:
        return FontAwesomeIcons.puzzlePiece;
    }
  }
}
