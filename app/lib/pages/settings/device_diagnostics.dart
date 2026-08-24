import 'dart:convert';
import 'dart:io';

import 'package:omi/utils/platform/platform_manager.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/share_sheet.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class DeviceDiagnostics extends StatefulWidget {
  final String deviceId;

  const DeviceDiagnostics({super.key, required this.deviceId});

  @override
  State<DeviceDiagnostics> createState() => _DeviceDiagnosticsState();
}

class _DeviceDiagnosticsState extends State<DeviceDiagnostics> {
  final List<_RssiPoint> _rssiPoints = [];
  static const int _maxRssiPoints = 120;

  List<BleBatteryPoint> _batteryHistory = [];
  bool _batteryDayView = true;

  BleDeviceDiagnostics? _diagnostics;
  bool _isLoading = true;
  final _bleHostApi = BleHostApi();
  final GlobalKey _shareButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    PlatformManager.instance.analytics.track('Diagnostics Opened');
    _loadAll();
    _startRssiStreaming();
  }

  @override
  void dispose() {
    _stopRssiStreaming();
    super.dispose();
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadDiagnostics(), _loadBatteryHistory()]);
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadDiagnostics() async {
    try {
      final diagnostics = await _bleHostApi.getDeviceDiagnostics(widget.deviceId);
      if (mounted) {
        setState(() => _diagnostics = diagnostics);
      }
    } catch (_) {}
  }

  Future<void> _loadBatteryHistory() async {
    try {
      final history = await _bleHostApi.getBatteryHistory(widget.deviceId);
      if (mounted) {
        setState(() => _batteryHistory = history);
      }
    } catch (e) {
      debugPrint('[DeviceDiagnostics] getBatteryHistory failed: $e');
    }
  }

  void _startRssiStreaming() {
    BleBridge.instance.registerRssiCallback(widget.deviceId, _onRssiUpdate);
    _bleHostApi.startRssiStreaming(widget.deviceId);
  }

  void _stopRssiStreaming() {
    _bleHostApi.stopRssiStreaming(widget.deviceId);
    BleBridge.instance.unregisterRssiCallback(widget.deviceId);
  }

  Future<void> _exportDiagnostics() async {
    final deviceProvider = context.read<DeviceProvider>();
    final data = {
      'device_id': widget.deviceId,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'firmware': deviceProvider.connectedDevice?.firmwareRevision ?? 'unknown',
      'battery': deviceProvider.batteryLevel,
      'connected_at': _diagnostics?.connectedAt ?? 0,
      'reconnection_count': _diagnostics?.reconnectionCount ?? 0,
      'fail_to_connect_count': _diagnostics?.failToConnectCount ?? 0,
      'rssi_samples': _rssiPoints.map((p) => {'ts': p.time.millisecondsSinceEpoch, 'rssi': p.rssi}).toList(),
      'battery_history': _batteryHistory.map((p) => {'ts': p.timestamp, 'level': p.level}).toList(),
      'disconnect_history': (_diagnostics?.disconnectHistory ?? [])
          .map(
            (e) => {
              'ts': e.timestamp,
              'reason': e.reason,
              'code': e.reasonCode,
              'manual': e.isManual,
              'event_type': e.eventType,
              'last_rssi': e.lastRssi,
              'connection_duration_ms': e.connectionDurationMs,
              'app_state': e.appState,
              'time_to_reconnect_ms': e.timeToReconnectMs,
              'rssi_trend': e.rssiTrend,
            },
          )
          .toList(),
    };

    // Every step here can fail — temp dir, file write, and the share sheet
    // itself. Unhandled, the whole handler is silent and the button looks dead.
    try {
      final json = const JsonEncoder.withIndent('  ').convert(data);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/omi_diagnostics_${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(json);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          title: 'Omi Device Diagnostics',
          subject: 'Omi Device Diagnostics',
          sharePositionOrigin: shareSheetOrigin(_shareButtonKey),
        ),
      );
      PlatformManager.instance.analytics.track(
        'Diagnostics Exported',
        properties: {
          'disconnect_count': (_diagnostics?.disconnectHistory ?? []).length,
          'reconnection_count': _diagnostics?.reconnectionCount ?? 0,
          'rssi_samples': _rssiPoints.length,
        },
      );
    } catch (e) {
      Logger.debug('Failed to export diagnostics: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.diagnosticsShareFailed)));
    }
  }

  void _onRssiUpdate(int rssi) {
    if (!mounted) return;
    setState(() {
      _rssiPoints.add(_RssiPoint(DateTime.now(), rssi));
      if (_rssiPoints.length > _maxRssiPoints) {
        _rssiPoints.removeAt(0);
      }
    });
  }

  String _formatUptime(int connectedAtMs) {
    if (connectedAtMs == 0) return '--';
    final connected = DateTime.fromMillisecondsSinceEpoch(connectedAtMs);
    final duration = DateTime.now().difference(connected);
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    } else if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
    }
    return '${duration.inSeconds}s';
  }

  Color _rssiColor(int rssi) {
    final t = context.omi;

    if (rssi >= -60) return t.success;
    if (rssi >= -75) return t.warning;
    return t.error;
  }

  String _rssiQuality(int rssi) {
    if (rssi >= -60) return context.l10n.excellent;
    if (rssi >= -75) return context.l10n.good;
    if (rssi >= -85) return context.l10n.fair;
    return context.l10n.weak;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Scaffold(
      backgroundColor: t.bgPrimary,
      appBar: AppBar(
        backgroundColor: t.bgPrimary,
        title: Text(
          context.l10n.deviceDiagnostics,
          style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios, color: t.textPrimary, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            key: _shareButtonKey,
            icon: Icon(Icons.ios_share, color: t.textPrimary, size: 22),
            onPressed: _exportDiagnostics,
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: t.textPrimary))
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatusCards(),
                  const SizedBox(height: 24),
                  _buildRssiChart(),
                  const SizedBox(height: 24),
                  _buildBatteryChart(),
                  const SizedBox(height: 24),
                  _buildDisconnectHistory(),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _buildStatusCards() {
    final t = context.omi;

    final deviceProvider = context.watch<DeviceProvider>();
    final battery = deviceProvider.batteryLevel;
    final connectedAt = _diagnostics?.connectedAt ?? 0;
    final reconnections = _diagnostics?.reconnectionCount ?? 0;
    final latestRssi = _rssiPoints.isNotEmpty ? _rssiPoints.last.rssi : null;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _statusCard(
                icon: FontAwesomeIcons.clock,
                label: context.l10n.connectionUptime,
                value: _formatUptime(connectedAt),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _statusCard(
                icon: FontAwesomeIcons.arrowsRotate,
                label: context.l10n.reconnections,
                value: '$reconnections',
                valueColor: reconnections > 5 ? t.error : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _statusCard(
                  icon: FontAwesomeIcons.batteryThreeQuarters,
                  label: context.l10n.battery,
                  value: battery >= 0 ? '$battery%' : '--',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _statusCard(
                  icon: FontAwesomeIcons.signal,
                  label: context.l10n.signal,
                  value: latestRssi != null ? '$latestRssi dBm' : '--',
                  valueColor: latestRssi != null ? _rssiColor(latestRssi) : null,
                  subtitle: latestRssi != null ? _rssiQuality(latestRssi) : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusCard({
    required FaIconData icon,
    required String label,
    required String value,
    Color? valueColor,
    String? subtitle,
  }) {
    final t = context.omi;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(t.cardRadius)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FaIcon(icon, color: t.textSecondary, size: 14),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(color: t.textSecondary, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(color: valueColor ?? t.textPrimary, fontSize: 22, fontWeight: FontWeight.w600),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(color: valueColor ?? t.textSecondary, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _buildRssiChart() {
    final t = context.omi;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.signalStrength,
          style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 16),
        Container(
          height: 200,
          padding: const EdgeInsets.only(top: 16, right: 16, bottom: 8),
          decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(t.cardRadius)),
          child: _rssiPoints.length < 2
              ? Center(
                  child: Text(
                    _rssiPoints.isEmpty ? context.l10n.noRssiDataYet : context.l10n.collectingData,
                    style: TextStyle(color: t.textSecondary, fontSize: 14),
                  ),
                )
              : LineChart(_buildLineChartData()),
        ),
      ],
    );
  }

  LineChartData _buildLineChartData() {
    final t = context.omi;

    final baseTime = _rssiPoints.first.time;
    final spots = _rssiPoints.asMap().entries.map((e) {
      final seconds = e.value.time.difference(baseTime).inMilliseconds / 1000.0;
      return FlSpot(seconds, e.value.rssi.toDouble());
    }).toList();

    final maxX = spots.last.x;
    final minX = spots.first.x;

    return LineChartData(
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: 25,
        getDrawingHorizontalLine: (value) => FlLine(color: t.rowFill, strokeWidth: 1),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 28,
            interval: _xInterval(maxX - minX),
            getTitlesWidget: (value, meta) {
              return Text('${value.toInt()}s', style: TextStyle(color: t.textSecondary, fontSize: 10));
            },
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 44,
            interval: 25,
            getTitlesWidget: (value, meta) {
              return Text('${value.toInt()}', style: TextStyle(color: t.textSecondary, fontSize: 10));
            },
          ),
        ),
      ),
      borderData: FlBorderData(show: false),
      minY: -100,
      maxY: -25,
      minX: minX,
      maxX: maxX,
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => t.bgTertiary,
          getTooltipItems: (touchedSpots) {
            return touchedSpots.map((spot) {
              return LineTooltipItem(
                '${spot.y.toInt()} dBm',
                TextStyle(color: _rssiColor(spot.y.toInt()), fontWeight: FontWeight.w600, fontSize: 13),
              );
            }).toList();
          },
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          curveSmoothness: 0.2,
          color: _rssiPoints.isNotEmpty ? _rssiColor(_rssiPoints.last.rssi) : t.textPrimary,
          barWidth: 2.5,
          isStrokeCapRound: true,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                (_rssiPoints.isNotEmpty ? _rssiColor(_rssiPoints.last.rssi) : Colors.white).withValues(alpha: 0.3),
                (_rssiPoints.isNotEmpty ? _rssiColor(_rssiPoints.last.rssi) : Colors.white).withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      ],
    );
  }

  double _xInterval(double range) {
    if (range <= 15) return 5;
    if (range <= 30) return 10;
    if (range <= 60) return 15;
    return 30;
  }

  Color _batteryColor(int level) {
    final t = context.omi;

    if (level > 50) return t.success;
    if (level > 20) return t.warning;
    return t.error;
  }

  Widget _buildBatteryChart() {
    final t = context.omi;

    final now = DateTime.now().millisecondsSinceEpoch;
    final windowMs = _batteryDayView ? 24 * 3600 * 1000 : 7 * 24 * 3600 * 1000;
    final cutoff = now - windowMs;
    final points = _batteryHistory.where((p) => p.timestamp >= cutoff).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              context.l10n.batteryHistory,
              style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            Container(
              decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  _segmentButton(context.l10n.day, _batteryDayView, () => setState(() => _batteryDayView = true)),
                  _segmentButton(context.l10n.week, !_batteryDayView, () => setState(() => _batteryDayView = false)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          height: 200,
          padding: const EdgeInsets.only(top: 16, right: 16, bottom: 8),
          decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(t.cardRadius)),
          child: points.length < 2
              ? Center(
                  child: Text(
                    context.l10n.noBatteryDataYet,
                    style: TextStyle(color: t.textSecondary, fontSize: 14),
                  ),
                )
              : LineChart(_buildBatteryLineChartData(points)),
        ),
      ],
    );
  }

  Widget _segmentButton(String label, bool active, VoidCallback onTap) {
    final t = context.omi;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: active ? t.divider : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? t.textPrimary : t.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  LineChartData _buildBatteryLineChartData(List<BleBatteryPoint> points) {
    final t = context.omi;

    final now = DateTime.now().millisecondsSinceEpoch;
    final spots = points.map((p) {
      final hoursAgo = (now - p.timestamp) / 3600000.0;
      return FlSpot(-hoursAgo, p.level.toDouble());
    }).toList();

    final minX = spots.first.x;
    final maxX = spots.last.x;
    final lastLevel = points.last.level.toInt();

    return LineChartData(
      gridData: FlGridData(
        show: true,
        drawVerticalLine: false,
        horizontalInterval: 25,
        getDrawingHorizontalLine: (value) => FlLine(color: t.rowFill, strokeWidth: 1),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 28,
            interval: _batteryDayView ? 4 : 24,
            getTitlesWidget: (value, meta) {
              final h = value.abs();
              if (_batteryDayView) {
                return Text('${h.toInt()}h', style: TextStyle(color: t.textSecondary, fontSize: 10));
              }
              return Text('${(h / 24).toInt()}d', style: TextStyle(color: t.textSecondary, fontSize: 10));
            },
          ),
        ),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 36,
            interval: 25,
            getTitlesWidget: (value, meta) {
              return Text('${value.toInt()}', style: TextStyle(color: t.textSecondary, fontSize: 10));
            },
          ),
        ),
      ),
      borderData: FlBorderData(show: false),
      minY: 0,
      maxY: 100,
      minX: minX,
      maxX: maxX,
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipColor: (_) => t.bgTertiary,
          getTooltipItems: (touchedSpots) {
            return touchedSpots.map((spot) {
              final level = spot.y.toInt();
              final hoursAgo = spot.x.abs();
              final timeLabel =
                  hoursAgo < 1 ? '${(hoursAgo * 60).toInt()}m ago' : '${hoursAgo.toStringAsFixed(1)}h ago';
              return LineTooltipItem(
                '$level%\n$timeLabel',
                TextStyle(color: _batteryColor(level), fontWeight: FontWeight.w600, fontSize: 13),
              );
            }).toList();
          },
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          curveSmoothness: 0.2,
          color: _batteryColor(lastLevel),
          barWidth: 2.5,
          isStrokeCapRound: true,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(
            show: true,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _batteryColor(lastLevel).withValues(alpha: 0.3),
                _batteryColor(lastLevel).withValues(alpha: 0.0),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDisconnectHistory() {
    final t = context.omi;

    final history = _diagnostics?.disconnectHistory ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.disconnectHistory,
          style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          history.isEmpty ? context.l10n.noDisconnectsRecorded : context.l10n.lastNEvents(history.length),
          style: TextStyle(color: t.textSecondary, fontSize: 14),
        ),
        const SizedBox(height: 16),
        if (history.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(t.cardRadius)),
            child: Center(
              child: Column(
                children: [
                  FaIcon(FontAwesomeIcons.circleCheck, color: t.textSecondary, size: 32),
                  const SizedBox(height: 12),
                  Text(context.l10n.noDisconnectsRecorded, style: TextStyle(color: t.textSecondary, fontSize: 14)),
                ],
              ),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(t.cardRadius)),
            child: Column(
              children: [
                for (int i = history.length - 1; i >= 0; i--) ...[
                  _buildDisconnectRow(history[i]),
                  if (i > 0) Divider(height: 1, color: t.divider),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDisconnectRow(BleDisconnectEvent event) {
    final t = context.omi;

    final time = DateTime.fromMillisecondsSinceEpoch(event.timestamp);
    final timeStr = DateFormat('MMM d, HH:mm:ss').format(time);
    final isManual = event.isManual;
    final isFail = event.eventType == 'fail_to_connect';
    final reason = _formatReason(event.reason);

    final Color dot = isManual ? t.textSecondary : (isFail ? t.warning : t.error);

    final metaParts = <String>[];
    if (event.rssiTrend.isNotEmpty) metaParts.add(event.rssiTrend);
    if (event.lastRssi != 0) metaParts.add('${event.lastRssi} dBm');
    if (event.connectionDurationMs > 0) metaParts.add(_formatDurationMs(event.connectionDurationMs));
    if (event.appState.isNotEmpty) metaParts.add(event.appState);
    if (event.timeToReconnectMs > 0) metaParts.add('reconn ${_formatDurationMs(event.timeToReconnectMs)}');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reason,
                  style: TextStyle(color: t.textPrimary, fontSize: 15, fontWeight: FontWeight.w400),
                ),
                const SizedBox(height: 2),
                Text(timeStr, style: TextStyle(color: t.textSecondary, fontSize: 12)),
                if (metaParts.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(metaParts.join(' · '), style: TextStyle(color: t.textSecondary, fontSize: 11)),
                ],
              ],
            ),
          ),
          if (isFail)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: t.isGlass ? t.warning.withValues(alpha: 0.12) : const Color(0xFF3A2A10),
                  borderRadius: BorderRadius.circular(8)),
              child: Text('fail', style: TextStyle(color: t.warning, fontSize: 11)),
            )
          else if (isManual)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: t.bgTertiary, borderRadius: BorderRadius.circular(8)),
              child: Text(context.l10n.manual, style: TextStyle(color: t.textSecondary, fontSize: 11)),
            ),
        ],
      ),
    );
  }

  String _formatDurationMs(int ms) {
    if (ms < 1000) return '${ms}ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    if (ms < 3600000) return '${(ms / 60000).toStringAsFixed(1)}m';
    return '${(ms / 3600000).toStringAsFixed(1)}h';
  }

  String _formatReason(String reason) {
    switch (reason) {
      case 'clean_disconnect':
        return context.l10n.cleanDisconnect;
      case 'connection_timeout':
        return context.l10n.connectionTimeout;
      case 'remote_device_terminated':
        return context.l10n.remoteDeviceTerminated;
      case 'paired_to_another_phone':
        return context.l10n.pairedToAnotherPhone;
      case 'link_key_mismatch':
        return context.l10n.linkKeyMismatch;
      case 'connection_failed_instant_passed':
        return context.l10n.connectionFailed;
      case 'app_closed':
        return context.l10n.appClosed;
      case 'manual':
        return context.l10n.manualDisconnect;
      default:
        if (reason.startsWith('gatt_error_')) {
          return context.l10n.gattError(reason.replaceFirst('gatt_error_', ''));
        }
        return reason;
    }
  }
}

class _RssiPoint {
  final DateTime time;
  final int rssi;

  _RssiPoint(this.time, this.rssi);
}
