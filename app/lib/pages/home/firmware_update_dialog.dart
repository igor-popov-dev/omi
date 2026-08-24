import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class FirmwareUpdateStep {
  final String title;
  final String description;
  final FaIconData icon;
  final bool isLastStep;

  FirmwareUpdateStep({required this.title, required this.description, required this.icon, this.isLastStep = false});
}

/// Shows the firmware update bottom sheet
void showFirmwareUpdateSheet({
  required BuildContext context,
  required List<String> steps,
  required Function() onUpdateStart,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (context) => FirmwareUpdateSheet(steps: steps, onUpdateStart: onUpdateStart),
  );
}

class FirmwareUpdateSheet extends StatefulWidget {
  final Function() onUpdateStart;
  final List<String> steps;

  const FirmwareUpdateSheet({super.key, required this.onUpdateStart, required this.steps});

  @override
  State<FirmwareUpdateSheet> createState() => _FirmwareUpdateSheetState();
}

class _FirmwareUpdateSheetState extends State<FirmwareUpdateSheet> {
  late final List<String> stepKeys;
  bool hasUsbStep = false;

  @override
  void initState() {
    super.initState();
    stepKeys = widget.steps;
    hasUsbStep = widget.steps.contains('no_usb');
  }

  Map<String, FirmwareUpdateStep> _getStepMap(BuildContext context) {
    return {
      'no_usb': FirmwareUpdateStep(
        title: context.l10n.firmwareDisconnectUsb,
        description: context.l10n.firmwareUsbWarning,
        icon: FontAwesomeIcons.plug,
      ),
      'battery': FirmwareUpdateStep(
        title: context.l10n.firmwareBatteryAbove15,
        description: context.l10n.firmwareEnsureBattery,
        icon: FontAwesomeIcons.batteryHalf,
      ),
      'internet': FirmwareUpdateStep(
        title: context.l10n.firmwareStableConnection,
        description: context.l10n.firmwareConnectWifi,
        icon: FontAwesomeIcons.wifi,
      ),
    };
  }

  void _onConfirmed() {
    final t = context.omi;
    Navigator.of(context).pop();
    try {
      widget.onUpdateStart();
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.failedToStartUpdate(e.toString())), backgroundColor: t.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Container(
      decoration: BoxDecoration(
        color: t.bgSecondary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 36,
              height: 4,
              decoration: BoxDecoration(color: t.textTertiary, borderRadius: BorderRadius.circular(2)),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FaIcon(FontAwesomeIcons.circleExclamation, color: t.warning, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    context.l10n.beforeUpdateMakeSure,
                    style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Steps list
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(children: stepKeys.map((key) => _buildStepItem(_getStepMap(context)[key]!)).toList()),
            ),

            // Footer with swipe to confirm
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: SwipeToConfirm(onConfirmed: _onConfirmed),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStepItem(FirmwareUpdateStep step) {
    final t = context.omi;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(t.rowRadius)),
              child: Center(child: FaIcon(step.icon, size: 18, color: t.textPrimary)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    step.title,
                    style: TextStyle(fontSize: 15, color: t.textPrimary, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(step.description, style: TextStyle(fontSize: 13, color: t.textSecondary, height: 1.3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SwipeToConfirm extends StatefulWidget {
  final VoidCallback onConfirmed;

  const SwipeToConfirm({super.key, required this.onConfirmed});

  @override
  State<SwipeToConfirm> createState() => _SwipeToConfirmState();
}

class _SwipeToConfirmState extends State<SwipeToConfirm> with SingleTickerProviderStateMixin {
  double _dragPosition = 0;
  bool _isDragging = false;
  bool _isConfirmed = false;
  late AnimationController _animationController;
  late Animation<double> _animation;

  static const double _buttonSize = 52;
  static const double _trackHeight = 60;
  static const double _horizontalPadding = 4;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _animation = Tween<double>(
      begin: 0,
      end: 0,
    ).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeOut));
    _animationController.addListener(() {
      setState(() {
        _dragPosition = _animation.value;
      });
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxDragDistance = constraints.maxWidth - _buttonSize - (_horizontalPadding * 2);
        final progress = maxDragDistance > 0 ? (_dragPosition / maxDragDistance).clamp(0.0, 1.0) : 0.0;

        return Container(
          height: _trackHeight,
          decoration: BoxDecoration(
            color: _isConfirmed ? t.success : t.bgTertiary,
            borderRadius: BorderRadius.circular(_trackHeight / 2),
          ),
          child: Stack(
            children: [
              // Green fill progress
              if (!_isConfirmed)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: _dragPosition + _buttonSize + _horizontalPadding,
                    decoration: BoxDecoration(
                      color: Color.lerp(t.bgTertiary, t.success, progress),
                      borderRadius: BorderRadius.circular(_trackHeight / 2),
                    ),
                  ),
                ),
              // Center text
              Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: _isConfirmed
                      ? Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          key: const ValueKey('confirmed'),
                          children: [
                            Text(
                              context.l10n.confirmed,
                              style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: t.textPrimary.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(t.rowRadius),
                              ),
                              child: Icon(Icons.check, color: t.textPrimary, size: 16),
                            ),
                          ],
                        )
                      : _isDragging && progress > 0.3
                          ? Text(
                              context.l10n.release,
                              key: const ValueKey('release'),
                              style: TextStyle(color: t.textSecondary, fontSize: 16, fontWeight: FontWeight.w500),
                            )
                          : Text(
                              context.l10n.slideToUpdate,
                              key: const ValueKey('slide'),
                              style: TextStyle(color: t.textSecondary, fontSize: 16, fontWeight: FontWeight.w500),
                            ),
                ),
              ),
              // Draggable button
              if (!_isConfirmed)
                Positioned(
                  left: _horizontalPadding + _dragPosition,
                  top: (_trackHeight - _buttonSize) / 2,
                  child: GestureDetector(
                    onHorizontalDragStart: (_) {
                      setState(() {
                        _isDragging = true;
                      });
                    },
                    onHorizontalDragUpdate: (details) {
                      if (_isConfirmed) return;
                      final newPosition = (_dragPosition + details.delta.dx).clamp(0.0, maxDragDistance);
                      setState(() {
                        _dragPosition = newPosition;
                      });
                    },
                    onHorizontalDragEnd: (details) {
                      if (_isConfirmed) return;

                      final threshold = maxDragDistance * 0.85;

                      if (_dragPosition >= threshold) {
                        setState(() {
                          _isConfirmed = true;
                          _dragPosition = maxDragDistance;
                        });
                        Future.delayed(const Duration(milliseconds: 200), () {
                          widget.onConfirmed();
                        });
                      } else {
                        _animation = Tween<double>(
                          begin: _dragPosition,
                          end: 0,
                        ).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeOut));
                        _animationController.forward(from: 0);
                      }

                      setState(() {
                        _isDragging = false;
                      });
                    },
                    child: Container(
                      width: _buttonSize,
                      height: _buttonSize,
                      decoration: BoxDecoration(
                        color: t.textPrimary,
                        borderRadius: BorderRadius.circular(_buttonSize / 2),
                        boxShadow: [
                          BoxShadow(
                            // Glass uses the single ambient shadow; Classic keeps its black drop.
                            color: t.isGlass ? const Color(0x1A000000) : t.bgPrimary.withValues(alpha: 0.2),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Center(child: FaIcon(FontAwesomeIcons.chevronRight, color: t.bgTertiary, size: 18)),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
