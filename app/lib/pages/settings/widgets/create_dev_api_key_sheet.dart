import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import 'package:omi/pages/settings/widgets/dev_api_key_created_dialog.dart';
import 'package:omi/providers/dev_api_key_provider.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';

class CreateDevApiKeySheet extends StatefulWidget {
  const CreateDevApiKeySheet({super.key});

  static Future<void> show(BuildContext context, DevApiKeyProvider provider) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ChangeNotifierProvider.value(value: provider, child: const CreateDevApiKeySheet()),
    );
  }

  @override
  State<CreateDevApiKeySheet> createState() => _CreateDevApiKeySheetState();
}

class _CreateDevApiKeySheetState extends State<CreateDevApiKeySheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  bool _isCreating = false;

  final Map<String, bool> _scopes = {
    'conversations:read': false,
    'conversations:write': false,
    'memories:read': false,
    'memories:write': false,
    'action_items:read': false,
    'action_items:write': false,
    'goals:read': false,
    'goals:write': false,
  };

  List<String> get _selectedScopes {
    return _scopes.entries.where((e) => e.value).map((e) => e.key).toList();
  }

  void _toggleScope(String scope) {
    setState(() {
      _scopes[scope] = !_scopes[scope]!;
    });
  }

  void _selectReadOnly() {
    setState(() {
      _scopes.updateAll((key, value) => false);
      _scopes['conversations:read'] = true;
      _scopes['memories:read'] = true;
      _scopes['action_items:read'] = true;
      _scopes['goals:read'] = true;
    });
  }

  void _selectFullAccess() {
    setState(() {
      _scopes.updateAll((key, value) => true);
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _createKey() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isCreating = true);
      final provider = Provider.of<DevApiKeyProvider>(context, listen: false);
      final selectedScopes = _selectedScopes.isEmpty ? null : _selectedScopes;
      final newKey = await provider.createKey(_nameController.text.trim(), scopes: selectedScopes);

      if (mounted) {
        Navigator.of(context).pop();
        if (newKey != null) {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            isDismissible: false,
            enableDrag: false,
            builder: (context) => DevApiKeyCreatedSheet(apiKey: newKey),
          );
        } else {
          final error = Provider.of<DevApiKeyProvider>(context, listen: false).error;
          if (error != null) {
            AppSnackbar.showSnackbarError(context.l10n.failedToCreateKeyWithError(error));
          } else {
            AppSnackbar.showSnackbarError(context.l10n.failedToCreateKeyTryAgain);
          }
        }
      }
    }
  }

  bool get _isReadOnly {
    return _scopes['conversations:read'] == true &&
        _scopes['memories:read'] == true &&
        _scopes['action_items:read'] == true &&
        _scopes['goals:read'] == true &&
        _scopes['conversations:write'] == false &&
        _scopes['memories:write'] == false &&
        _scopes['action_items:write'] == false &&
        _scopes['goals:write'] == false;
  }

  bool get _isFullAccess {
    return _scopes.values.every((v) => v);
  }

  Widget _buildPresetChip(String label, bool isSelected, VoidCallback onTap) {
    final t = context.omi;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: isSelected ? t.accent : t.bgTertiary,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? t.textPrimary : t.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionTile(String resource, String readScope, String writeScope, IconData icon) {
    final t = context.omi;

    final hasRead = _scopes[readScope] ?? false;
    final hasWrite = _scopes[writeScope] ?? false;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(t.cardRadius), color: t.bgSecondary),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, color: t.accent, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                resource,
                style: TextStyle(color: t.textPrimary, fontSize: 15, fontWeight: FontWeight.w500),
              ),
            ),
            _buildTogglePill(
              leftLabel: 'R',
              rightLabel: 'W',
              leftSelected: hasRead,
              rightSelected: hasWrite,
              onLeftTap: () => _toggleScope(readScope),
              onRightTap: () => _toggleScope(writeScope),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTogglePill({
    required String leftLabel,
    required String rightLabel,
    required bool leftSelected,
    required bool rightSelected,
    required VoidCallback onLeftTap,
    required VoidCallback onRightTap,
  }) {
    final t = context.omi;

    // Determine border radius based on selection state
    final leftRadius = BorderRadius.only(
      topLeft: const Radius.circular(8),
      bottomLeft: const Radius.circular(8),
      topRight: Radius.circular(leftSelected && rightSelected ? 0 : 8),
      bottomRight: Radius.circular(leftSelected && rightSelected ? 0 : 8),
    );
    final rightRadius = BorderRadius.only(
      topRight: const Radius.circular(8),
      bottomRight: const Radius.circular(8),
      topLeft: Radius.circular(leftSelected && rightSelected ? 0 : 8),
      bottomLeft: Radius.circular(leftSelected && rightSelected ? 0 : 8),
    );

    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: t.bgTertiary),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: onLeftTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: leftRadius,
                color: leftSelected ? const Color(0xFF3B82F6) : Colors.transparent,
              ),
              child: Text(
                leftLabel,
                style: TextStyle(
                  color: leftSelected ? t.textPrimary : t.textTertiary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: onRightTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: rightRadius,
                color: rightSelected ? t.accent : Colors.transparent,
              ),
              child: Text(
                rightLabel,
                style: TextStyle(
                  color: rightSelected ? t.textPrimary : t.textTertiary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: BoxDecoration(
        color: t.bgPrimary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle bar
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 8),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: t.divider, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: t.isGlass ? t.accent : null,
                          gradient:
                              t.isGlass ? null : const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF7C3AED)]),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: OmiIconWidget(icon: OmiIcon.key, color: t.textPrimary, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n.createApiKey,
                              style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              context.l10n.accessDataProgrammatically,
                              style: TextStyle(color: t.textSecondary, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: t.bgTertiary,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: OmiIconWidget(icon: OmiIcon.close, color: t.textSecondary, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                // Name input
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.keyNameLabel,
                        style: TextStyle(
                          color: t.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _nameController,
                        autofocus: false,
                        style: TextStyle(color: t.textPrimary, fontSize: 16),
                        decoration: InputDecoration(
                          hintText: context.l10n.keyNamePlaceholder,
                          hintStyle: TextStyle(color: t.textTertiary, fontSize: 16),
                          filled: true,
                          fillColor: t.bgSecondary,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(color: t.bgTertiary),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(color: t.bgTertiary),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(color: t.accent, width: 1.5),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return context.l10n.pleaseEnterAName;
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                // Permissions section
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        context.l10n.permissionsLabel,
                        style: TextStyle(
                          color: t.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Row(
                        children: [
                          _buildPresetChip(context.l10n.readOnlyScope, _isReadOnly, _selectReadOnly),
                          const SizedBox(width: 8),
                          _buildPresetChip(context.l10n.fullAccessScope, _isFullAccess, _selectFullAccess),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // Permission tiles
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      _buildPermissionTile(
                        context.l10n.conversations,
                        'conversations:read',
                        'conversations:write',
                        Icons.chat_bubble_outline,
                      ),
                      _buildPermissionTile(
                        context.l10n.memories,
                        'memories:read',
                        'memories:write',
                        Icons.psychology_outlined,
                      ),
                      _buildPermissionTile(
                        context.l10n.actionItems,
                        'action_items:read',
                        'action_items:write',
                        Icons.task_alt_outlined,
                      ),
                      _buildPermissionTile(context.l10n.goals, 'goals:read', 'goals:write', Icons.flag_outlined),
                    ],
                  ),
                ),
                // Info note
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      OmiIconWidget(icon: OmiIcon.info, color: t.warning, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          context.l10n.permissionsInfoNote,
                          style: TextStyle(color: t.textTertiary, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                // Create button
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isCreating ? null : _createKey,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: t.accent,
                        disabledBackgroundColor: t.accent.withValues(alpha: 0.5),
                        foregroundColor: t.textPrimary,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        elevation: 0,
                      ),
                      child: _isCreating
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
                              ),
                            )
                          : Text(
                              context.l10n.createKey,
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                    ),
                  ),
                ),
                SizedBox(height: MediaQuery.of(context).padding.bottom),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
