import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omi/backend/http/api/users.dart';
import 'package:omi/services/wals/sync_rate_limit_reconciliation.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/theme/omi_tokens.dart';
import 'package:omi/utils/theme/omi_icons.dart';

class FairUsePage extends StatefulWidget {
  const FairUsePage({super.key});

  @override
  State<FairUsePage> createState() => _FairUsePageState();
}

class _FairUsePageState extends State<FairUsePage> {
  Map<String, dynamic>? _status;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final result = await getFairUseStatus();
      // Reconcile the rate-limit cooldown regardless of whether the widget is
      // still mounted — this only touches the SyncRateLimiter singleton and
      // must not be skipped if the user navigates away before the response
      // returns (otherwise a stale cooldown is never cleared).
      reconcileSyncRateLimitWithFairUseStatus(result);
      if (mounted) {
        if (result == null) {
          setState(() {
            _error = 'Unable to load fair use status';
            _isLoading = false;
          });
        } else {
          setState(() {
            _status = result;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Scaffold(
      backgroundColor: t.bgPrimary,
      appBar: AppBar(
        backgroundColor: t.bgPrimary,
        title: Text(context.l10n.fairUsePolicy),
        leading: IconButton(icon: const Icon(Icons.arrow_back_ios), onPressed: () => Navigator.of(context).pop()),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: t.textPrimary))
          : _error != null
              ? _buildError()
              : _status == null
                  ? _buildError()
                  : RefreshIndicator(
                      onRefresh: _loadStatus,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildStatusBanner(),
                            _buildUsageSection(),
                            _buildBudgetSection(),
                            _buildMessageBanner(),
                            const SizedBox(height: 24),
                            _buildAboutFooter(),
                          ],
                        ),
                      ),
                    ),
    );
  }

  Widget _buildError() {
    final t = context.omi;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              context.l10n.fairUseLoadError,
              style: TextStyle(color: t.textSecondary, fontSize: 15),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _loadStatus,
              child: Text(context.l10n.retry, style: TextStyle(color: t.accent)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBanner() {
    final t = context.omi;

    final stage = _status!['stage'] as String? ?? 'none';
    if (stage == 'none') return const SizedBox.shrink();

    final caseRef = _status!['case_ref'] as String? ?? '';

    Color dotColor;
    String stageLabel;

    switch (stage) {
      case 'warning':
        dotColor = t.warning;
        stageLabel = context.l10n.fairUseStageWarning;
        break;
      case 'throttle':
        dotColor = t.warning;
        stageLabel = context.l10n.fairUseStageThrottle;
        break;
      case 'restrict':
        dotColor = t.error;
        stageLabel = context.l10n.fairUseStageRestrict;
        break;
      default:
        return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: dotColor.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Text(
              stageLabel,
              style: TextStyle(color: dotColor, fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const Spacer(),
            if (caseRef.isNotEmpty)
              GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: caseRef));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(context.l10n.fairUseCaseRefCopied(caseRef)),
                      duration: const Duration(seconds: 2),
                      backgroundColor: t.bgTertiary,
                    ),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      caseRef,
                      style: TextStyle(color: t.textSecondary, fontSize: 12, fontFamily: 'monospace'),
                    ),
                    const SizedBox(width: 4),
                    OmiIconWidget(icon: OmiIcon.copy, size: 12, color: t.textSecondary),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsageSection() {
    final t = context.omi;

    final usagePct = _status!['usage_pct'] as Map<String, dynamic>? ?? {};
    final limits = _status!['limits'] as Map<String, dynamic>? ?? {};
    final speechToday = (_status!['speech_hours_today'] as num?)?.toDouble() ?? 0;
    final speech3day = (_status!['speech_hours_3day'] as num?)?.toDouble() ?? 0;
    final speechWeekly = (_status!['speech_hours_weekly'] as num?)?.toDouble() ?? 0;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(t.cardRadius)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.fairUseSpeechUsage,
            style: TextStyle(color: t.textSecondary, fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 16),
          _buildUsageBar(
            label: context.l10n.fairUseToday,
            hours: speechToday,
            limit: (limits['daily_hours'] as num?)?.toDouble() ?? 2.0,
            pct: (usagePct['daily'] as num?)?.toDouble() ?? 0,
          ),
          const SizedBox(height: 14),
          _buildUsageBar(
            label: context.l10n.fairUse3Day,
            hours: speech3day,
            limit: (limits['three_day_hours'] as num?)?.toDouble() ?? 8.0,
            pct: (usagePct['three_day'] as num?)?.toDouble() ?? 0,
          ),
          const SizedBox(height: 14),
          _buildUsageBar(
            label: context.l10n.fairUseWeekly,
            hours: speechWeekly,
            limit: (limits['weekly_hours'] as num?)?.toDouble() ?? 10.0,
            pct: (usagePct['weekly'] as num?)?.toDouble() ?? 0,
          ),
        ],
      ),
    );
  }

  Widget _buildUsageBar({required String label, required double hours, required double limit, required double pct}) {
    final t = context.omi;

    final barColor = pct >= 100
        ? t.error
        : pct >= 80
            ? t.warning
            : t.accent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(color: t.textSecondary, fontSize: 13)),
            Text(
              '${hours.toStringAsFixed(1)}h / ${limit.toStringAsFixed(0)}h',
              style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (pct / 100).clamp(0.0, 1.0),
            backgroundColor: t.bgTertiary,
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
            minHeight: 4,
          ),
        ),
      ],
    );
  }

  Widget _buildBudgetSection() {
    final t = context.omi;

    final stage = _status!['stage'] as String? ?? 'none';
    if (stage != 'restrict') return const SizedBox.shrink();

    final dgBudget = _status!['dg_budget'] as Map<String, dynamic>?;
    if (dgBudget == null) return const SizedBox.shrink();

    final dailyLimitMs = (dgBudget['daily_limit_ms'] as num?)?.toInt() ?? 0;
    final usedMs = (dgBudget['used_ms'] as num?)?.toInt() ?? 0;
    final exhausted = dgBudget['exhausted'] as bool? ?? false;
    final resetsAt = dgBudget['resets_at'] as String? ?? '';

    if (dailyLimitMs <= 0) return const SizedBox.shrink();

    final usedMin = (usedMs / 60000).round();
    final limitMin = (dailyLimitMs / 60000).round();
    final pct = (usedMs / dailyLimitMs * 100).clamp(0.0, 100.0);
    final barColor = exhausted ? t.error : t.accent;

    String resetLabel = '';
    if (resetsAt.isNotEmpty) {
      try {
        final resetTime = DateTime.parse(resetsAt);
        final now = DateTime.now().toUtc();
        final diff = resetTime.difference(now);
        if (diff.inHours > 0) {
          resetLabel = context.l10n.fairUseBudgetResetsAt('${diff.inHours}h');
        } else if (diff.inMinutes > 0) {
          resetLabel = context.l10n.fairUseBudgetResetsAt('${diff.inMinutes}m');
        }
      } catch (_) {}
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: exhausted ? t.error.withValues(alpha: 0.06) : t.bgSecondary,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  context.l10n.fairUseDailyTranscription,
                  style: TextStyle(color: t.textSecondary, fontSize: 13, fontWeight: FontWeight.w500),
                ),
                Text(
                  context.l10n.fairUseBudgetUsed('$usedMin', '$limitMin'),
                  style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (pct / 100).clamp(0.0, 1.0),
                backgroundColor: t.bgTertiary,
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
                minHeight: 4,
              ),
            ),
            if (exhausted) ...[
              const SizedBox(height: 10),
              Text(
                context.l10n.fairUseBudgetExhausted,
                style: TextStyle(color: t.error, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
            if (resetLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(resetLabel, style: TextStyle(color: t.textTertiary, fontSize: 12)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBanner() {
    final t = context.omi;

    final message = _status!['message'] as String? ?? '';
    if (message.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(12)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OmiIconWidget(icon: OmiIcon.info, color: t.textSecondary, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Text(message, style: TextStyle(color: t.textSecondary, fontSize: 13, height: 1.4)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAboutFooter() {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.fairUseAboutTitle,
            style: TextStyle(color: t.textTertiary, fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            context.l10n.fairUseAboutBody,
            // [OmiTokens.divider] is a separator tone, not an ink tone: under
            // Glass it is a hairline and disappears as body copy. Classic keeps
            // the exact shade it renders today.
            style: TextStyle(color: t.isGlass ? t.textSecondary : t.divider, fontSize: 12, height: 1.4),
          ),
        ],
      ),
    );
  }
}
