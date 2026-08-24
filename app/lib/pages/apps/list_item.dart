import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:omi/widgets/shimmer_with_timeout.dart';

import 'package:omi/backend/schema/app.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:omi/widgets/dialog.dart';
import 'package:omi/widgets/extensions/string.dart';
import 'app_detail/app_detail.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class AppListItem extends StatelessWidget {
  final App app;
  final int index;
  final bool showPrivateIcon;

  const AppListItem({super.key, required this.app, required this.index, this.showPrivateIcon = true});

  @override
  Widget build(BuildContext context) {
    // Use Selector to only rebuild when this specific app's state or loading state changes
    return Selector<AppProvider, ({bool enabled, bool isLoading})>(
      selector: (context, provider) {
        // Check if this specific app is loading
        bool isLoading = false;
        if (provider.appLoading.isNotEmpty && index >= 0 && index < provider.appLoading.length) {
          isLoading = provider.appLoading[index];
        }

        return (enabled: app.enabled, isLoading: isLoading);
      },
      builder: (context, state, child) {
        final t = context.omi;

        return GestureDetector(
          onTap: () async {
            PlatformManager.instance.analytics.pageOpened('App Detail');
            await routeToPage(context, AppDetailPage(app: app));
          },
          child: Container(
            padding: const EdgeInsets.all(16),
            margin: EdgeInsets.only(bottom: 8, top: index == 0 ? 16 : 0),
            decoration: BoxDecoration(
              color: t.textTertiary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                // App icon
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(12)),
                    child: CachedNetworkImage(
                      imageUrl: app.getImageUrl(),
                      httpHeaders: const {
                        "User-Agent":
                            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
                      },
                      fit: BoxFit.cover,
                      placeholder: (context, url) => ShimmerWithTimeout(
                        baseColor: t.bgSecondary,
                        highlightColor: t.bgTertiary,
                        child: Container(
                          width: double.infinity,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color: t.bgSecondary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      errorWidget: (context, url, error) => Icon(Icons.apps, size: 30, color: t.textSecondary),
                    ),
                  ),
                ),

                const SizedBox(width: 16),

                // App details
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.name.decodeString + (app.private && showPrivateIcon ? " 🔒".decodeString : ''),
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: t.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        app.description.length > 50 ? '${app.description.substring(0, 50)}...' : app.description,
                        style: TextStyle(fontSize: 13, color: t.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (app.ratingAvg != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.star_rounded, color: t.textPrimary, size: 14),
                            const SizedBox(width: 4),
                            Text(
                              app.getRatingAvg()!,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: t.textSecondary),
                            ),
                            const SizedBox(width: 4),
                            Text('(${app.ratingCount})', style: TextStyle(fontSize: 12, color: t.textSecondary)),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(width: 12),

                // Action button
                state.isLoading
                    ? Container(
                        width: 72,
                        height: 32,
                        decoration: BoxDecoration(color: t.textSecondary, borderRadius: BorderRadius.circular(16)),
                        child: Center(
                          child: SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(
                              valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
                              strokeWidth: 2,
                            ),
                          ),
                        ),
                      )
                    : GestureDetector(
                        onTap: () {
                          if (state.enabled) {
                            // App is enabled, open app detail
                            PlatformManager.instance.analytics.pageOpened('App Detail');
                            routeToPage(context, AppDetailPage(app: app));
                            return;
                          }

                          final appProvider = context.read<AppProvider>();

                          // App is not enabled, toggle it on
                          if (app.worksExternally()) {
                            showDialog(
                              context: context,
                              builder: (c) => getDialog(
                                c,
                                () => Navigator.pop(c),
                                () async {
                                  Navigator.pop(c);
                                  appProvider.toggleApp(app.id.toString(), true, index);
                                },
                                'Authorize External App',
                                'Do you allow this app to access your memories, transcripts, and recordings? Your data will be sent to the app\'s server for processing.',
                                okButtonText: 'Confirm',
                              ),
                            );
                          } else {
                            appProvider.toggleApp(app.id.toString(), true, index);
                          }
                        },
                        child: Container(
                          width: 72,
                          height: 32,
                          decoration: BoxDecoration(
                            color: state.enabled ? t.textSecondary : (t.isGlass ? t.accent : Colors.white),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Center(
                            child: Text(
                              state.enabled ? 'Open' : 'Enable',
                              // Black on the white "Enable" fill, white on the grey "Open" one.
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: state.enabled ? t.textPrimary : (t.isGlass ? t.onAccent : Colors.black),
                              ),
                            ),
                          ),
                        ),
                      ),
              ],
            ),
          ),
        );
      },
    );
  }
}
