import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import 'package:omi/backend/schema/folder.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/providers/folder_provider.dart';
import 'package:omi/utils/theme/glass_effects.dart';
import 'package:omi/utils/theme/omi_emoji.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class MoveToFolderSheet extends StatelessWidget {
  final String conversationId;
  final String? currentFolderId;

  const MoveToFolderSheet({super.key, required this.conversationId, this.currentFolderId});

  /// Радиус панели — скруглены только верхние углы, нижние уходят за экран.
  static const BorderRadius _sheetRadius = BorderRadius.vertical(top: Radius.circular(20));

  /// Размытие списка/страницы под панелью — то же 38, что у шторки настроек
  /// и у панели «Шаблон сводки»: панель открывается поверх ленты разговоров с
  /// её заголовками, и они должны раствориться, а не просвечивать сквозь
  /// названия папок.
  static const double _sheetBlurSigma = 38;

  // Вуаль остаётся токеном `bgSecondary` (серый 0.55): он и так плотнее, чем
  // `bgPrimary` у соседних панелей, и поверх размытия уже даёт непроницаемое
  // стекло. Здесь добавляется только сам блюр — цвет панели не меняется.

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    final content = Consumer<FolderProvider>(
      builder: (context, provider, child) {
        if (provider.isLoading) {
          return SizedBox(
            height: 200,
            child: Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(t.accent),
              ),
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    context.l10n.moveToFolder,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close, color: t.textPrimary.withValues(alpha: 0.69), size: 24),
                  ),
                ],
              ),
            ),

            // Folder list
            if (provider.folders.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: Text(
                    context.l10n.noFoldersAvailable,
                    style: TextStyle(color: t.textPrimary.withValues(alpha: 0.69)),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 20),
                  itemCount: provider.folders.length,
                  itemBuilder: (context, index) {
                    final folder = provider.folders[index];
                    final isCurrentFolder = folder.id == currentFolderId;

                    return _FolderListItem(
                      folder: folder,
                      isCurrentFolder: isCurrentFolder,
                      onTap: isCurrentFolder ? null : () => _moveToFolder(context, provider, folder.id),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );

    final decoration = BoxDecoration(color: t.bgSecondary, borderRadius: _sheetRadius);

    if (!t.isGlass) {
      return DecoratedBox(decoration: decoration, child: content);
    }

    // Glass: сначала размывается всё, что уже нарисовано ниже, и только
    // поверх ложится вуаль.
    return glassBlur(
      borderRadius: _sheetRadius,
      sigma: _sheetBlurSigma,
      child: DecoratedBox(decoration: decoration, child: content),
    );
  }

  void _moveToFolder(BuildContext context, FolderProvider provider, String folderId) {
    HapticFeedback.selectionClick();
    // Close sheet immediately with the folder ID
    Navigator.of(context).pop(folderId);
    // Fire and forget - API call in background
    provider.moveConversation(conversationId, folderId);
  }
}

class _FolderListItem extends StatelessWidget {
  final Folder folder;
  final bool isCurrentFolder;
  final VoidCallback? onTap;

  const _FolderListItem({required this.folder, required this.isCurrentFolder, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: isCurrentFolder ? t.accent.withValues(alpha: 0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(t.rowRadius),
        border: isCurrentFolder ? Border.all(color: t.accent, width: 1.5) : Border.all(color: t.bgTertiary, width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(t.rowRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                // Folder icon
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: folder.colorValue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(child: OmiFolderIcon(folder.icon, size: 18, color: folder.colorValue)),
                ),
                const SizedBox(width: 14),

                // Folder info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        folder.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: isCurrentFolder ? FontWeight.w600 : FontWeight.w500,
                          color: isCurrentFolder ? t.accent : t.textPrimary,
                        ),
                      ),
                      if (folder.description != null && folder.description!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            folder.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: t.textPrimary.withValues(alpha: 0.69)),
                          ),
                        ),
                    ],
                  ),
                ),

                // Check mark for current folder
                if (isCurrentFolder) Icon(Icons.check_circle, color: t.accent, size: 22),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the move to folder bottom sheet.
/// Returns the new folder ID if moved, or 'no_folder' if removed from folders, null if cancelled.
Future<String?> showMoveToFolderSheet(
  BuildContext context, {
  required String conversationId,
  String? currentFolderId,
}) async {
  final result = await showModalBottomSheet<String?>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (context) => MoveToFolderSheet(conversationId: conversationId, currentFolderId: currentFolderId),
  );
  return result;
}
