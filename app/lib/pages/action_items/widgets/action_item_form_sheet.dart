import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:calendar_date_picker2/calendar_date_picker2.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'package:omi/backend/http/api/action_items.dart' as action_items_api;
import 'package:omi/backend/schema/schema.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/calendar_date_picker_sheet.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class ActionItemFormSheet extends StatefulWidget {
  final ActionItemWithMetadata? actionItem; // null for create, non-null for edit
  final VoidCallback? onRefresh;
  final DateTime? defaultDueDate; // Default due date for new items

  const ActionItemFormSheet({super.key, this.actionItem, this.onRefresh, this.defaultDueDate});

  bool get isEditing => actionItem != null;

  @override
  State<ActionItemFormSheet> createState() => _ActionItemFormSheetState();
}

class _ActionItemFormSheetState extends State<ActionItemFormSheet> {
  late TextEditingController _textController;
  late bool _isCompleted;
  DateTime? _selectedDueDate;

  @override
  void initState() {
    super.initState();
    if (widget.isEditing) {
      _textController = TextEditingController(text: widget.actionItem!.description);
      _textController.selection = TextSelection.fromPosition(TextPosition(offset: _textController.text.length));
      _isCompleted = widget.actionItem!.completed;
      _selectedDueDate = widget.actionItem!.dueAt;
    } else {
      _textController = TextEditingController();
      _isCompleted = false;
      _selectedDueDate = widget.defaultDueDate;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _saveActionItem() async {
    final t = context.omi;
    if (_textController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.actionItemDescriptionEmpty), backgroundColor: t.error));
      return;
    }

    final provider = Provider.of<ActionItemsProvider>(context, listen: false);

    Navigator.pop(context);

    if (widget.isEditing) {
      // Editing existing item
      String newDescription = _textController.text.trim();
      bool descriptionChanged = newDescription != widget.actionItem!.description;
      // Compare due dates - handle null cases explicitly
      bool dueDateChanged = (_selectedDueDate == null && widget.actionItem!.dueAt != null) ||
          (_selectedDueDate != null && widget.actionItem!.dueAt == null) ||
          (_selectedDueDate != null &&
              widget.actionItem!.dueAt != null &&
              _selectedDueDate!.millisecondsSinceEpoch != widget.actionItem!.dueAt!.millisecondsSinceEpoch);
      bool completionChanged = _isCompleted != widget.actionItem!.completed;

      if (!descriptionChanged && !dueDateChanged && !completionChanged) {
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.actionItemUpdated),
            backgroundColor: t.success,
            duration: const Duration(seconds: 2),
          ),
        );
      }

      try {
        if (descriptionChanged) {
          await provider.updateActionItemDescription(widget.actionItem!, newDescription);
        }

        if (dueDateChanged) {
          await provider.updateActionItemDueDate(widget.actionItem!, _selectedDueDate);
        }

        if (completionChanged) {
          await provider.updateActionItemState(widget.actionItem!, _isCompleted);
        }

        // Track action item edit
        if (descriptionChanged || dueDateChanged) {
          PlatformManager.instance.analytics.actionItemEdited(
            actionItemId: widget.actionItem!.id,
            titleChanged: descriptionChanged,
            dateChanged: dueDateChanged,
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.failedToUpdateActionItem),
              backgroundColor: t.error,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.actionItemCreated),
            backgroundColor: t.success,
            duration: const Duration(seconds: 2),
          ),
        );
      }

      try {
        final createdItem = await provider.createActionItem(
          description: _textController.text.trim(),
          dueAt: _selectedDueDate,
          completed: _isCompleted,
        );

        if (createdItem != null) {
          // Track manually added action item
          PlatformManager.instance.analytics.actionItemManuallyAdded(
            actionItemId: createdItem.id,
            timestamp: DateTime.now(),
          );
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.failedToCreateActionItem),
              backgroundColor: t.error,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.l10n.failedToCreateActionItem),
              backgroundColor: t.error,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  void _deleteActionItem() async {
    final t = context.omi;
    if (!widget.isEditing) return;

    Navigator.pop(context);

    final provider = Provider.of<ActionItemsProvider>(context, listen: false);
    final success = await provider.deleteActionItem(widget.actionItem!);

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.actionItemDeleted),
            backgroundColor: t.success,
            duration: const Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.failedToDeleteActionItem), backgroundColor: t.error));
      }
    }
  }

  void _shareActionItem() async {
    final t = context.omi;
    if (!widget.isEditing) return;

    final result = await action_items_api.shareActionItems([widget.actionItem!.id]);

    if (!mounted) return;

    if (result != null && result['url'] != null) {
      final url = result['url'] as String;
      HapticFeedback.lightImpact();
      await Share.share(url);
      PlatformManager.instance.analytics.track(
        'Action Item Shared',
        properties: {'actionItemId': widget.actionItem!.id},
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.failedToCreateShareLink), backgroundColor: t.error));
    }
  }

  Future<void> _openDateTimePicker() async {
    final DateTime? result = await showCupertinoModalPopup<DateTime>(
      context: context,
      builder: (context) => DateTimePickerSheet(
        initialDateTime: _selectedDueDate,
        minimumDate: widget.isEditing ? widget.actionItem!.createdAt : DateTime.now(),
      ),
    );

    if (result != null) {
      setState(() {
        _selectedDueDate = result;
      });
    }
  }

  void _clearDueDate() {
    setState(() {
      _selectedDueDate = null;
    });
  }

  String _formatDueDateWithTime(DateTime date) {
    final locale = Localizations.localeOf(context).toString();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final dateOnly = DateTime(date.year, date.month, date.day);
    final timeStr = DateFormat.jm(locale).format(date);

    String dateStr;
    if (dateOnly == today) {
      dateStr = context.l10n.today;
    } else if (dateOnly == tomorrow) {
      dateStr = context.l10n.tomorrow;
    } else {
      // Show short form: "Sat, Jan 31" or "Sat, Jan 31, 2027" if different year
      if (date.year == now.year) {
        dateStr = DateFormat.E(locale).format(date) + ', ' + DateFormat.MMMd(locale).format(date);
      } else {
        dateStr = DateFormat.E(locale).format(date) + ', ' + DateFormat.yMMMd(locale).format(date);
      }
    }

    return '$dateStr - $timeStr';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: t.bgSecondary,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // Completed status toggle
                Row(
                  children: [
                    SizedBox(
                      height: 24,
                      width: 24,
                      child: Checkbox(
                        value: _isCompleted,
                        activeColor: t.accent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                        onChanged: (bool? value) async {
                          if (value == null) return;

                          HapticFeedback.lightImpact();

                          setState(() {
                            _isCompleted = value;
                          });

                          // Only update immediately if editing
                          if (widget.isEditing) {
                            final provider = Provider.of<ActionItemsProvider>(context, listen: false);
                            await provider.updateActionItemState(widget.actionItem!, value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isCompleted ? context.l10n.completed : context.l10n.markComplete,
                      style: TextStyle(color: t.textSecondary, fontSize: 14),
                    ),
                  ],
                ),
                // Share + Delete buttons (only for edit mode)
                if (widget.isEditing)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: FaIcon(FontAwesomeIcons.share, color: t.textSecondary, size: 16),
                        onPressed: _shareActionItem,
                      ),
                      IconButton(
                        icon: Icon(Icons.delete_outline, color: t.error),
                        onPressed: () {
                          // Show delete confirmation dialog
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: t.bgSecondary,
                              title: Text(
                                context.l10n.deleteActionItemConfirmTitle,
                                style: TextStyle(color: t.textPrimary),
                              ),
                              content: Text(
                                context.l10n.deleteActionItemConfirmMessage,
                                style: TextStyle(color: t.textSecondary),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context, false),
                                  child: Text(context.l10n.cancel, style: TextStyle(color: t.textSecondary)),
                                ),
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(context, true); // Close dialog
                                    _deleteActionItem();
                                  },
                                  child: Text(context.l10n.delete, style: TextStyle(color: t.error)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // Text field for editing/creating the action item
            TextField(
              controller: _textController,
              autofocus: true,
              maxLines: null,
              textInputAction: TextInputAction.done,
              style: TextStyle(color: t.textPrimary, fontSize: 16, height: 1.4),
              decoration: InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
                hintText: widget.isEditing ? null : context.l10n.actionItemDescriptionHint,
                hintStyle: TextStyle(color: t.textSecondary, fontSize: 16),
              ),
              onSubmitted: (value) {
                FocusScope.of(context).unfocus();
                if (value.trim().isNotEmpty) {
                  _saveActionItem();
                }
              },
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: _openDateTimePicker,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.schedule_outlined, size: 20, color: t.textSecondary),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _selectedDueDate != null ? _formatDueDateWithTime(_selectedDueDate!) : context.l10n.addDueDate,
                        style: TextStyle(
                          color: _selectedDueDate != null ? t.textPrimary : t.textSecondary,
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    if (_selectedDueDate != null)
                      GestureDetector(
                        onTap: () {
                          _clearDueDate();
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close, size: 18, color: t.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: t.rowFill,
                    borderRadius: BorderRadius.circular(t.rowRadius),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.keyboard_return, size: 13, color: t.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        widget.isEditing ? context.l10n.pressDoneToSave : context.l10n.pressDoneToCreate,
                        style: TextStyle(color: t.textSecondary, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                Text('${_textController.text.length}/200', style: TextStyle(color: t.textSecondary, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class DateTimePickerSheet extends StatefulWidget {
  final DateTime? initialDateTime;
  final DateTime? minimumDate;

  const DateTimePickerSheet({super.key, this.initialDateTime, this.minimumDate});

  @override
  State<DateTimePickerSheet> createState() => _DateTimePickerSheetState();
}

class _DateTimePickerSheetState extends State<DateTimePickerSheet> {
  late DateTime _selectedDateTime;
  late TimeOfDay _selectedTimeOfDay;

  Widget yearBuilder({
    required int year,
    TextStyle? textStyle,
    BoxDecoration? decoration,
    bool? isSelected,
    bool? isDisabled,
    bool? isCurrentYear,
  }) {
    final t = context.omi;
    return Container(
      decoration: BoxDecoration(
        color: isSelected == true
            ? t.accent
            : isCurrentYear == true
                ? t.accent.withValues(alpha: 0.3)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          year.toString(),
          style: TextStyle(
            fontSize: 14,
            fontWeight: isSelected == true ? FontWeight.bold : FontWeight.normal,
            color: isDisabled == true ? t.textTertiary : t.textPrimary,
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final minimumDate = widget.minimumDate ?? now;

    if (widget.initialDateTime != null) {
      _selectedDateTime = widget.initialDateTime!.isBefore(minimumDate) ? minimumDate : widget.initialDateTime!;
    } else {
      _selectedDateTime = now.isBefore(minimumDate) ? minimumDate : now;
    }
    _selectedTimeOfDay = TimeOfDay.fromDateTime(_selectedDateTime);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    final now = DateTime.now();

    return Material(
      color: Colors.transparent,
      child: Container(
        height: MediaQuery.of(context).size.height * 0.65,
        decoration: BoxDecoration(
          color: t.bgSecondary,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle bar
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 12, bottom: 20),
              decoration: BoxDecoration(color: t.textTertiary, borderRadius: BorderRadius.circular(2)),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      context.l10n.cancel,
                      style: TextStyle(color: t.textTertiary, fontSize: 17),
                    ),
                  ),
                  Text(
                    DateFormat.yMMMd(Localizations.localeOf(context).toString()).format(_selectedDateTime),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.pop(context, _selectedDateTime),
                    child: Text(
                      context.l10n.done,
                      style: TextStyle(
                        color: t.accent,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  CalendarDatePicker2(
                    config: getDefaultCalendarConfig(
                      t: t,
                      firstDate: now,
                      currentDate: now,
                      lastDate: (widget.initialDateTime ?? now).add(const Duration(days: 365 * 5)),
                      yearBuilder: yearBuilder,
                    ),
                    value: [_selectedDateTime],
                    onValueChanged: (dates) => setState(() {
                      _selectedDateTime = DateTime(
                        dates[0].year,
                        dates[0].month,
                        dates[0].day,
                        _selectedDateTime.hour,
                        _selectedDateTime.minute,
                      );
                    }),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    child: Row(
                      children: [
                        Icon(Icons.access_time, color: t.accent, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            context.l10n.time,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: t.textPrimary,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: () async {
                            final TimeOfDay? pickedTime = await showTimePicker(
                              context: context,
                              initialTime: _selectedTimeOfDay,
                              builder: (context, child) {
                                return Theme(
                                  data: Theme.of(context).copyWith(
                                    colorScheme: ColorScheme.dark(
                                      primary: t.accent,
                                      onPrimary: t.textPrimary,
                                      surface: t.bgSecondary,
                                      onSurface: t.textPrimary,
                                    ),
                                    timePickerTheme: TimePickerThemeData(
                                      backgroundColor: t.bgSecondary,
                                      hourMinuteColor: WidgetStateColor.resolveWith(
                                        (states) => states.contains(WidgetState.selected) ? t.accent : t.bgTertiary,
                                      ),
                                      hourMinuteTextColor: t.textPrimary,
                                      dialHandColor: t.accent,
                                      dialBackgroundColor: t.bgTertiary,
                                      dialTextColor: WidgetStateColor.resolveWith(
                                        (states) =>
                                            states.contains(WidgetState.selected) ? t.textPrimary : t.textSecondary,
                                      ),
                                      entryModeIconColor: t.textTertiary,
                                      dayPeriodColor: WidgetStateColor.resolveWith(
                                        (states) =>
                                            states.contains(WidgetState.selected) ? t.accent : Colors.transparent,
                                      ),
                                      dayPeriodTextColor: WidgetStateColor.resolveWith(
                                        (states) =>
                                            states.contains(WidgetState.selected) ? t.textPrimary : t.textTertiary,
                                      ),
                                      dayPeriodBorderSide: BorderSide(color: t.textTertiary),
                                    ),
                                  ),
                                  child: child!,
                                );
                              },
                            );

                            if (pickedTime != null) {
                              setState(() {
                                _selectedTimeOfDay = pickedTime;
                                _selectedDateTime = DateTime(
                                  _selectedDateTime.year,
                                  _selectedDateTime.month,
                                  _selectedDateTime.day,
                                  pickedTime.hour,
                                  pickedTime.minute,
                                );
                              });
                            }
                          },
                          child: Row(
                            children: [
                              Text(
                                DateFormat.jm().format(_selectedDateTime),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                  color: t.accent,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
