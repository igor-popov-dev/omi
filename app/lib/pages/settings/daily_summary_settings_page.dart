import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/http/api/users.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/pages/settings/widgets/glass_icon_chip.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';
import 'package:omi/widgets/omi_switch.dart';

class DailySummarySettingsPage extends StatefulWidget {
  const DailySummarySettingsPage({super.key});

  @override
  State<DailySummarySettingsPage> createState() => _DailySummarySettingsPageState();
}

class _DailySummarySettingsPageState extends State<DailySummarySettingsPage> {
  bool _isLoading = true;
  bool _enabled = true;
  int _selectedHour = 22; // Default to 10 PM

  @override
  void initState() {
    super.initState();
    _loadSettings();
    PlatformManager.instance.analytics.dailySummarySettingsOpened();
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await getDailySummarySettings();
      if (settings != null && mounted) {
        setState(() {
          _enabled = settings.enabled;
          _selectedHour = settings.hour;
        });
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatHourDisplay(int hour) {
    final hour12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final period = hour >= 12 ? 'PM' : 'AM';
    return '$hour12:00 $period';
  }

  Future<void> _updateEnabled(bool value) async {
    final previous = _enabled;
    setState(() => _enabled = value);
    final success = await setDailySummarySettings(enabled: value);
    if (!mounted) return;
    if (success) {
      PlatformManager.instance.analytics.dailySummaryToggled(enabled: value);
    } else if (_enabled == value) {
      setState(() => _enabled = previous);
      AppSnackbar.showSnackbarError(context.l10n.somethingWentWrong);
    }
  }

  Future<void> _updateHour(int hour) async {
    final previous = _selectedHour;
    setState(() => _selectedHour = hour);
    final success = await setDailySummarySettings(hour: hour);
    if (!mounted) return;
    if (success) {
      PlatformManager.instance.analytics.dailySummaryTimeChanged(hour: hour);
    } else if (_selectedHour == hour) {
      setState(() => _selectedHour = previous);
      AppSnackbar.showSnackbarError(context.l10n.somethingWentWrong);
    }
  }

  Future<void> _showHourPicker() async {
    final t = context.omi;

    if (!_enabled) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: t.bgSecondary,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        int tempHour = _selectedHour;
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: 350,
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(context.l10n.cancel, style: TextStyle(color: t.textSecondary, fontSize: 16)),
                      ),
                      Text(
                        context.l10n.selectTime,
                        style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                      TextButton(
                        onPressed: () {
                          _updateHour(tempHour);
                          Navigator.pop(context);
                        },
                        child: Text(
                          context.l10n.done,
                          style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: CupertinoTheme(
                      data: CupertinoThemeData(brightness: Theme.of(context).brightness),
                      child: CupertinoPicker(
                        scrollController: FixedExtentScrollController(initialItem: tempHour),
                        itemExtent: 44,
                        onSelectedItemChanged: (index) {
                          setModalState(() => tempHour = index);
                        },
                        children: List.generate(24, (index) {
                          final hour12 = index == 0 ? 12 : (index > 12 ? index - 12 : index);
                          final period = index >= 12 ? 'PM' : 'AM';
                          return Center(
                            child: Text(
                              '$hour12:00 $period',
                              style: TextStyle(color: t.textPrimary, fontSize: 20),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showGenerateSummaryPicker() async {
    final t = context.omi;

    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.dark(
              primary: t.accent,
              onPrimary: t.textPrimary,
              surface: t.bgSecondary,
              onSurface: t.textPrimary,
            ),
            dialogTheme: DialogThemeData(backgroundColor: t.bgSecondary),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && mounted) {
      final dateStr =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';

      // Show loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(child: CircularProgressIndicator(color: t.textPrimary)),
      );

      final summaryId = await generateDailySummary(date: dateStr);

      if (!mounted) return;
      Navigator.pop(context); // Dismiss loading

      if (summaryId != null) {
        PlatformManager.instance.analytics.dailySummaryTestGenerated(date: dateStr);

        // Refresh the hasDailySummaries flag so the Recap tab shows
        Provider.of<ConversationProvider>(context, listen: false).checkHasDailySummaries();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.summaryGeneratedForDate('${picked.month}/${picked.day}/${picked.year}')),
            backgroundColor: t.success,
          ),
        );
      } else {
        PlatformManager.instance.analytics.dailySummaryTestGenerationFailed(date: dateStr);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.failedToGenerateSummaryCheckConversations),
            backgroundColor: t.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Scaffold(
      backgroundColor: context.omi.bgPrimary,
      appBar: AppBar(
        title: Text(context.l10n.dailySummary),
        backgroundColor: context.omi.bgPrimary,
        elevation: 0,
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: t.textPrimary),
            color: t.bgSecondary,
            onSelected: (value) {
              if (value == 'generate') {
                _showGenerateSummaryPicker();
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'generate',
                child: Row(
                  children: [
                    OmiIconWidget(icon: OmiIcon.sparkles, color: t.textPrimary, size: 20),
                    const SizedBox(width: 12),
                    Text(context.l10n.generateSummary, style: TextStyle(color: t.textPrimary)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: t.textPrimary))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Description
                  Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Text(
                      context.l10n.dailySummaryDescription,
                      style: TextStyle(color: t.textSecondary, fontSize: 14, height: 1.5),
                    ),
                  ),
                  // Combined settings card
                  _buildSettingsCard(),
                ],
              ),
            ),
    );
  }

  Widget _buildSettingsCard() {
    final t = context.omi;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(20)),
      child: Column(
        children: [
          // Enable toggle row
          _buildSettingRow(
            icon: FontAwesomeIcons.bell,
            title: context.l10n.dailySummary,
            trailing: OmiSwitch(value: _enabled, onChanged: _updateEnabled, classicActiveThumbColor: t.accent),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(color: t.textSecondary, height: 1),
          ),

          // Time selector row
          AnimatedOpacity(
            opacity: _enabled ? 1.0 : 0.4,
            duration: const Duration(milliseconds: 200),
            child: GestureDetector(
              onTap: _showHourPicker,
              behavior: HitTestBehavior.opaque,
              child: _buildSettingRow(
                icon: FontAwesomeIcons.clock,
                title: context.l10n.deliveryTime,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatHourDisplay(_selectedHour),
                      style: TextStyle(color: t.textSecondary, fontSize: 16),
                    ),
                    const SizedBox(width: 6),
                    OmiIconWidget(icon: OmiIcon.chevronRight, color: t.textSecondary, size: 20),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingRow({required FaIconData icon, required String title, required Widget trailing}) {
    final t = context.omi;

    return Row(
      children: [
        SettingsIconChip.boxed(icon: (size) => FaIcon(icon, color: t.textSecondary, size: size)),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            title,
            style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
          ),
        ),
        trailing,
      ],
    );
  }
}
