import 'package:omi/utils/platform/platform_manager.dart';
import 'package:flutter/material.dart';

import 'package:omi/backend/schema/device_guide.dart';
import 'package:omi/utils/analytics/intercom.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class DevicePairingSheet extends StatelessWidget {
  final DeviceGuideProduct product;
  final VoidCallback onDismissAll;

  const DevicePairingSheet({super.key, required this.product, required this.onDismissAll});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Container(
      decoration: BoxDecoration(
        color: t.bgSecondary,
        borderRadius: const BorderRadius.only(topLeft: Radius.circular(24), topRight: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(color: t.textTertiary, borderRadius: BorderRadius.circular(2)),
          ),

          Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                // Device image
                if (product.localImagePath != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Image.asset(product.localImagePath!, height: 180, width: 180, fit: BoxFit.contain),
                  )
                else
                  SizedBox(
                    height: 180,
                    width: 180,
                    child: Icon(Icons.bluetooth_searching, size: 64, color: t.accent),
                  ),
                const SizedBox(height: 24),

                // Title
                Text(
                  product.pairingTitle.isNotEmpty ? product.pairingTitle : product.name,
                  style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),

                // Description
                if (product.pairingDescription.isNotEmpty)
                  Text(
                    product.pairingDescription,
                    style: TextStyle(color: t.textTertiary, fontSize: 15, height: 1.4),
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 32),

                // "I've done this" button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: onDismissAll,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: t.accent,
                      foregroundColor: t.textPrimary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                      elevation: 0,
                    ),
                    child: Text(
                      context.l10n.iveDoneThis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // Report an issue
                GestureDetector(
                  onTap: () async {
                    PlatformManager.instance.analytics.connectionGuideReportIssue(product.id);
                    onDismissAll();
                    await IntercomManager.instance.intercom.displayMessenger();
                  },
                  child: Text(
                    context.l10n.reportAnIssue,
                    style: TextStyle(color: t.textTertiary, fontSize: 14),
                  ),
                ),

                SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
