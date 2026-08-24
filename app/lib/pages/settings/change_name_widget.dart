import 'package:flutter/material.dart';

import 'package:firebase_auth/firebase_auth.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/utils/alerts/app_snackbar.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class ChangeNameWidget extends StatefulWidget {
  const ChangeNameWidget({super.key});

  @override
  State<ChangeNameWidget> createState() => _ChangeNameWidgetState();
}

class _ChangeNameWidgetState extends State<ChangeNameWidget> {
  late TextEditingController nameController;
  User? user;
  bool isSaving = false;

  @override
  void initState() {
    user = AuthService.instance.getFirebaseUser();
    nameController = TextEditingController(
      text: SharedPreferencesUtil().givenName.isNotEmpty ? SharedPreferencesUtil().givenName : user?.displayName ?? '',
    );
    super.initState();
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Dialog(
      backgroundColor: t.bgSecondary,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.editName,
              style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(context.l10n.howShouldOmiCallYou, style: TextStyle(color: t.textSecondary, fontSize: 14)),
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(10)),
              child: TextField(
                controller: nameController,
                autofocus: true,
                style: TextStyle(color: t.textPrimary, fontSize: 16),
                decoration: InputDecoration(
                  hintText: context.l10n.enterYourName,
                  hintStyle: TextStyle(color: t.textSecondary, fontSize: 16),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: t.hairline, width: 1),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        color: t.bgTertiary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          context.l10n.cancel,
                          style: TextStyle(color: t.textPrimary, fontSize: 16, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: isSaving
                        ? null
                        : () {
                            if (nameController.text.isEmpty || nameController.text.trim().isEmpty) {
                              AppSnackbar.showSnackbarError(context.l10n.nameCannotBeEmpty);
                              return;
                            }
                            setState(() => isSaving = true);
                            SharedPreferencesUtil().givenName = nameController.text.trim();
                            AuthService.instance.updateGivenName(nameController.text.trim());
                            AppSnackbar.showSnackbar(context.l10n.nameUpdatedSuccessfully);
                            Navigator.of(context).pop();
                          },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                          color: (t.isGlass ? t.accent : Colors.white), borderRadius: BorderRadius.circular(10)),
                      child: Center(
                        child: isSaving
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: (t.isGlass ? t.onAccent : Colors.black)),
                              )
                            : Text(
                                context.l10n.save,
                                style: TextStyle(
                                    color: (t.isGlass ? t.onAccent : Colors.black),
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600),
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
