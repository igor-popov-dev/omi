import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import 'package:omi/providers/home_provider.dart';
import 'package:omi/utils/theme/omi_icons.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class BottomNavBar extends StatefulWidget {
  const BottomNavBar({super.key, required this.onTabTap, this.onTabWarmup});

  final void Function(int index, bool isRepeat) onTabTap;
  final ValueChanged<int>? onTabWarmup;

  @override
  State<BottomNavBar> createState() => _BottomNavBarState();
}

class _BottomNavBarState extends State<BottomNavBar> {
  // Keep the provider-dependent subtree stable when HomePage's broad Consumer
  // rebuilds for unrelated focus or loading changes.
  late final Widget _navigation;

  @override
  void initState() {
    super.initState();
    _navigation = Selector<HomeProvider, int>(
      selector: (_, home) => home.selectedIndex,
      builder: (context, selectedIndex, _) {
        return Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            width: double.infinity,
            height: 100,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.30, 1.0],
                colors: [Colors.transparent, Color.fromARGB(255, 15, 15, 15), Color.fromARGB(255, 15, 15, 15)],
              ),
            ),
            child: Row(
              children: [
                _buildTab(context, selectedIndex, 0, OmiIcon.home, 'Home'),
                _buildTab(context, selectedIndex, 1, OmiIcon.chat, 'Conversations'),
                _buildTab(context, selectedIndex, 2, OmiIcon.tasks, 'Tasks'),
                _buildTab(context, selectedIndex, 3, OmiIcon.apps, 'Apps'),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => _navigation;

  Widget _buildTab(BuildContext context, int selectedIndex, int index, OmiIcon icon, String label) {
    final t = context.omi;
    final isSelected = selectedIndex == index;
    // Classic keeps the exact white/grey pair it has always drawn; Glass needs
    // ink tones instead, white would be invisible on the light bar.
    final color = t.isGlass ? (isSelected ? t.textPrimary : t.textTertiary) : (isSelected ? Colors.white : Colors.grey);
    return Expanded(
      child: InkWell(
        onTapDown: (_) => widget.onTabWarmup?.call(index),
        onTap: () {
          // Switch the visible page before crossing the platform channel for
          // haptics or analytics. Both can be delayed when the device is busy,
          // but neither should delay visual acknowledgement of the tap.
          widget.onTabTap(index, context.read<HomeProvider>().selectedIndex == index);
          primaryFocus?.unfocus();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            HapticFeedback.selectionClick();
            PlatformManager.instance.analytics.bottomNavigationTabClicked(label);
          });
        },
        child: SizedBox(
          height: 90,
          child: Center(child: OmiIconWidget(icon: icon, color: color, size: 26)),
        ),
      ),
    );
  }
}
