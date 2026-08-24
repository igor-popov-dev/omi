import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:omi/widgets/shimmer_with_timeout.dart';

import 'package:omi/backend/schema/app.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';

// Custom notification class to communicate with parent widgets
class SelectAppNotification extends Notification {
  final App app;

  SelectAppNotification(this.app);
}

class PopularAppsSection extends StatelessWidget {
  final List<App> apps;

  const PopularAppsSection({super.key, required this.apps});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    if (apps.isEmpty) {
      return const SizedBox.shrink();
    }

    // Show top 9 popular apps
    final displayedApps = apps.take(9).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header - Apple style
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Row(
            children: [
              Text(
                context.l10n.popularApps,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: t.textPrimary),
              ),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: t.textSecondary, borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      '${apps.length}',
                      style: TextStyle(fontSize: 11, color: t.textSecondary, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OmiIconWidget(icon: OmiIcon.chevronRight, color: t.textSecondary, size: 16),
                ],
              ),
            ],
          ),
        ),

        // Apps list - Apple style
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: displayedApps.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final t = context.omi;

            final app = displayedApps[index];
            return GestureDetector(
              onTap: () {
                final appProvider = context.read<AppProvider>();

                appProvider.filterApps();

                PlatformManager.instance.analytics.pageOpened('App Detail');

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(context.l10n.openingApp(app.name)),
                    duration: const Duration(milliseconds: 500),
                    behavior: SnackBarBehavior.floating,
                  ),
                );

                // clear any existing search
                appProvider.searchApps('');

                final notification = SelectAppNotification(app);
                notification.dispatch(context);
              },
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: t.textTertiary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    // App icon - Apple style square with rounded corners
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: t.bgTertiary,
                          borderRadius: BorderRadius.circular(12),
                        ),
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

                    // App details - Apple style
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            app.name,
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
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: t.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '(${app.ratingCount})',
                                  style: TextStyle(fontSize: 12, color: t.textSecondary),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(width: 12),

                    // Action button - Apple style
                    Container(
                      width: 72,
                      height: 32,
                      decoration: BoxDecoration(
                        color: app.enabled ? t.textSecondary : (t.isGlass ? t.accent : Colors.white),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Center(
                        child: Text(
                          app.enabled ? context.l10n.open : 'Enable',
                          // Black on the white "Enable" fill, white on the grey "Open" one.
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: app.enabled ? t.textPrimary : (t.isGlass ? t.onAccent : Colors.black),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),

        const SizedBox(height: 8),
      ],
    );
  }
}
