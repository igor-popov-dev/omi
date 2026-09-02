import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:collection/collection.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/schema/app.dart';
import 'package:omi/gen/assets.gen.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/message_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class ChatAppsDropdownWidget extends StatelessWidget {
  final PageController? controller;

  ChatAppsDropdownWidget({super.key, this.controller});

  final FocusNode focusNode = FocusNode();

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Selector<HomeProvider, bool>(
      selector: (context, state) => state.selectedIndex == 1,
      builder: (context, isChatPage, child) {
        if (!isChatPage) {
          return const SizedBox(width: 16);
        }
        return child!;
      },
      child: Consumer2<AppProvider, MessageProvider>(
        builder: (context, appProvider, messageProvider, child) {
          var selectedApp = messageProvider.chatApps.firstWhereOrNull((app) => app.id == appProvider.selectedChatAppId);
          return Padding(
            padding: const EdgeInsets.only(left: 0),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: PopupMenuButton<String>(
                iconSize: 164,
                icon: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    selectedApp != null ? _getAppAvatar(context, selectedApp) : _getOmiAvatar(),
                    const SizedBox(width: 8),
                    Container(
                      constraints: const BoxConstraints(maxWidth: 100),
                      child: Text(
                        selectedApp != null ? selectedApp.getName() : context.l10n.omiAppName,
                        style: TextStyle(color: t.textPrimary, fontSize: 16),
                        overflow: TextOverflow.fade,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 24,
                      child: Icon(Icons.keyboard_arrow_down, color: t.textPrimary.withValues(alpha: 0.6), size: 16),
                    ),
                  ],
                ),
                constraints: const BoxConstraints(minWidth: 250.0, maxWidth: 250.0, maxHeight: 350.0),
                offset: Offset(
                  (MediaQuery.sizeOf(context).width - 250) / 2 / MediaQuery.devicePixelRatioOf(context),
                  114,
                ),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(t.cardRadius))),
                onSelected: (String? val) async {
                  if (val == null || val == appProvider.selectedChatAppId) {
                    return;
                  }

                  // clear chat
                  if (val == 'clear_chat') {
                    showDialog(
                      context: context,
                      builder: (ctx) {
                        return getDialog(
                          context,
                          () {
                            Navigator.of(context).pop();
                          },
                          () {
                            context.read<MessageProvider>().clearChat();
                            Navigator.of(context).pop();
                          },
                          context.l10n.clearChatTitle,
                          context.l10n.confirmClearChat,
                        );
                      },
                    );
                    return;
                  }

                  // enable apps
                  if (val == 'enable') {
                    PlatformManager.instance.analytics.pageOpened('Chat Apps');
                    context.read<HomeProvider>().setIndex(4);
                    controller?.animateToPage(4, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
                    return;
                  }

                  // select app by id
                  appProvider.setSelectedChatAppId(val);
                  await context.read<MessageProvider>().refreshMessages(dropdownSelected: true);
                  var app = messageProvider.chatApps.firstWhereOrNull((a) => a.id == val);
                  if (context.mounted && context.read<MessageProvider>().messages.isEmpty) {
                    context.read<MessageProvider>().sendInitialAppMessage(app);
                  }
                },
                itemBuilder: (BuildContext context) {
                  return _getChatDropdownItems(context, messageProvider, appProvider);
                },
                color: t.bgSecondary,
              ),
            ),
          );
        },
      ),
    );
  }

  _getAppAvatar(BuildContext context, App app) {
    final t = context.omi;
    return CachedNetworkImage(
      imageUrl: app.getImageUrl(),
      imageBuilder: (context, imageProvider) {
        return CircleAvatar(backgroundColor: t.textPrimary, radius: 12, backgroundImage: imageProvider);
      },
      errorWidget: (context, url, error) {
        return CircleAvatar(backgroundColor: t.textPrimary, radius: 12, child: const Icon(Icons.error_outline_rounded));
      },
      progressIndicatorBuilder: (context, url, progress) => CircleAvatar(
        backgroundColor: t.textPrimary,
        radius: 12,
        child: CircularProgressIndicator(
          value: progress.progress,
          valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
        ),
      ),
    );
  }

  _getOmiAvatar() {
    return Container(
      decoration: BoxDecoration(
        image: DecorationImage(image: AssetImage(Assets.images.background.path), fit: BoxFit.cover),
        borderRadius: const BorderRadius.all(Radius.circular(16.0)),
      ),
      height: 24,
      width: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [Image.asset(Assets.images.herologo.path, height: 16, width: 16)],
      ),
    );
  }

  List<PopupMenuItem<String>> _getChatDropdownItems(
    BuildContext context,
    MessageProvider messageProvider,
    AppProvider appProvider,
  ) {
    final t = context.omi;
    var selectedApp = messageProvider.chatApps.firstWhereOrNull((app) => app.id == appProvider.selectedChatAppId);
    return [
      PopupMenuItem<String>(
        height: 40,
        value: 'clear_chat',
        child: Padding(
          padding: const EdgeInsets.only(left: 32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(context.l10n.clearChatAction, style: TextStyle(color: t.error, fontSize: 16)),
              SizedBox(width: 24, child: Icon(Icons.delete, color: t.error, size: 16)),
            ],
          ),
        ),
      ),
      const PopupMenuItem<String>(height: 1, child: Divider(height: 1)),
      PopupMenuItem<String>(
        value: 'enable',
        height: 40,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.start,
          mainAxisSize: MainAxisSize.max,
          children: [
            SizedBox(width: 24, child: Icon(Icons.arrow_forward_ios, color: t.textPrimary, size: 16)),
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                child: Row(
                  mainAxisSize: MainAxisSize.max,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(context.l10n.enableApps, style: TextStyle(color: t.textPrimary, fontSize: 16)),
                    SizedBox(width: 24, child: Icon(Icons.apps, color: t.textPrimary.withValues(alpha: 0.6), size: 16)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      const PopupMenuItem<String>(height: 1, child: Divider(height: 1)),
      PopupMenuItem<String>(
        height: 40,
        value: 'no_selected',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _getOmiAvatar(),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      context.l10n.omiAppName,
                      style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w500, fontSize: 16),
                    ),
                    selectedApp == null
                        ? SizedBox(
                            width: 24,
                            child: Icon(Icons.check, color: t.textPrimary.withValues(alpha: 0.6), size: 16),
                          )
                        : const SizedBox.shrink(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      ...messageProvider.chatApps.map<PopupMenuItem<String>>((App app) {
        return PopupMenuItem<String>(
          height: 40,
          value: app.id,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              _getAppAvatar(context, app),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        overflow: TextOverflow.fade,
                        app.getName(),
                        style: TextStyle(color: t.textPrimary, fontWeight: FontWeight.w500, fontSize: 16),
                      ),
                    ),
                    selectedApp?.id == app.id
                        ? SizedBox(
                            width: 24,
                            child: Icon(Icons.check, color: t.textPrimary.withValues(alpha: 0.6), size: 16),
                          )
                        : const SizedBox.shrink(),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    ];
  }
}
