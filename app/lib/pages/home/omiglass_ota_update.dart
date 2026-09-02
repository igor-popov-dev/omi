import 'dart:async';

import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:version/version.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/pages/home/page.dart';
import 'package:omi/services/devices/connectors/omiglass_connection.dart';
import 'package:omi/services/services.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/temp.dart';
import 'package:provider/provider.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class OmiGlassOtaUpdate extends StatefulWidget {
  final BtDevice? device;
  final Map<String, dynamic>? latestFirmwareDetails;

  const OmiGlassOtaUpdate({super.key, this.device, this.latestFirmwareDetails});

  @override
  State<OmiGlassOtaUpdate> createState() => _OmiGlassOtaUpdateState();
}

class _OmiGlassOtaUpdateState extends State<OmiGlassOtaUpdate> {
  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _isUpdating = false;
  bool _isSuccess = false;
  bool _isFailed = false;
  String _statusMessage = '';
  int _progress = 0;
  bool _obscurePassword = true;

  StreamSubscription? _otaStatusSubscription;
  OmiGlassConnection? _connection;
  DeviceProvider? _deviceProvider;

  // Track high progress for handling device reboot/disconnection
  bool _reachedHighProgress = false;
  Timer? _successTimer;
  static const int _highProgressThreshold = 90;
  static const Duration _successTimeout = Duration(seconds: 5);

  // Version checking state
  bool _hasUpdate = false;
  String _latestVersion = '';
  String _currentVersion = '';
  String _downloadUrl = '';
  String _changelog = '';

  @override
  void initState() {
    super.initState();
    _ssidController.text = SharedPreferencesUtil().otaWifiSsid;
    _passwordController.text = SharedPreferencesUtil().otaWifiPassword;
    _currentVersion = widget.device?.firmwareRevision ?? '';
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _deviceProvider = Provider.of<DeviceProvider>(context, listen: false);
      _deviceProvider!.setOnFirmwareUpdatePage(true);
    });
    _initializeAndCheck();
  }

  @override
  void dispose() {
    _otaStatusSubscription?.cancel();
    _successTimer?.cancel();
    _ssidController.dispose();
    _passwordController.dispose();
    final provider = _deviceProvider;
    if (provider != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        provider.setOnFirmwareUpdatePage(false);
        provider.resetFirmwareUpdateState();
      });
    }
    super.dispose();
  }

  Future<void> _initializeAndCheck() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Checking for updates...';
    });

    try {
      // Check OTA support
      final connection = await ServiceManager.instance().device.ensureConnection(widget.device!.id, force: true);
      if (connection is OmiGlassConnection) {
        _connection = connection;
        final isSupported = await connection.isOtaSupported();
        if (!isSupported) {
          if (mounted) {
            setState(() {
              _isFailed = true;
              _statusMessage = 'OTA updates are not supported on this firmware version.';
              _isLoading = false;
            });
          }
          return;
        }
      } else {
        if (mounted) {
          setState(() {
            _isFailed = true;
            _statusMessage = 'Device connection type mismatch: ${connection.runtimeType}';
            _isLoading = false;
          });
        }
        return;
      }

      // Check for firmware updates - use provider's data if widget didn't receive details
      Map<String, dynamic> details = widget.latestFirmwareDetails ?? {};
      if (details.isEmpty && _deviceProvider != null) {
        details = _deviceProvider!.latestOmiGlassFirmwareDetails;
      }

      if (details.isNotEmpty && details['version'] != null) {
        _latestVersion = details['version'];
        _downloadUrl = details['download_url'] ?? '';
        _changelog = details['changelog'] ?? '';

        try {
          final current = Version.parse(_currentVersion);
          final latest = Version.parse(_latestVersion);
          _hasUpdate = latest > current;
        } catch (e) {
          Logger.debug('OmiGlassOtaUpdate: Version parse error: $e');
          // If we can't parse, assume update available if versions differ
          _hasUpdate = _currentVersion != _latestVersion;
        }
      }
    } catch (e) {
      Logger.debug('OmiGlassOtaUpdate: Error during init: $e');
      if (mounted) {
        setState(() {
          _isFailed = true;
          _statusMessage = 'Error connecting to device: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _startOtaUpdate() async {
    final ssid = _ssidController.text.trim();
    final password = _passwordController.text;

    if (ssid.isEmpty) {
      _showError('Please enter WiFi network name (SSID)');
      return;
    }

    if (password.isEmpty) {
      _showError('Please enter WiFi password');
      return;
    }

    if (_downloadUrl.isEmpty) {
      _showError('No firmware download URL available');
      return;
    }

    // Save credentials for next time
    SharedPreferencesUtil().otaWifiSsid = ssid;
    SharedPreferencesUtil().otaWifiPassword = password;

    setState(() {
      _isUpdating = true;
      _statusMessage = 'Starting OTA update...';
      _progress = 0;
      _reachedHighProgress = false;
    });
    _successTimer?.cancel();

    try {
      if (_connection == null) {
        final connection = await ServiceManager.instance().device.ensureConnection(widget.device!.id, force: true);
        if (connection is! OmiGlassConnection) {
          throw Exception('Connection type mismatch: expected OmiGlassConnection, got ${connection.runtimeType}');
        }
        _connection = connection;
      }

      print('OmiGlassOtaUpdate: Calling performOtaUpdate...');
      final success = await _connection!.performOtaUpdate(
        ssid: ssid,
        password: password,
        firmwareUrl: _downloadUrl,
        onStatusUpdate: _handleOtaStatus,
        onConnectionLost: _handleConnectionLost,
      );

      if (!success) {
        if (mounted) {
          setState(() {
            _isUpdating = false;
            _isFailed = true;
            _statusMessage = 'Failed to start OTA update. Check WiFi credentials and try again.';
          });
        }
      }
    } catch (e) {
      Logger.debug('OmiGlassOtaUpdate: Error during OTA: $e');
      if (_reachedHighProgress) {
        _handleConnectionLost();
      } else if (mounted) {
        setState(() {
          _isUpdating = false;
          _isFailed = true;
          _statusMessage = 'Error: ${e.toString()}';
        });
      }
    }
  }

  void _handleOtaStatus(OmiGlassOtaStatus status) {
    if (!mounted) return;
    _successTimer?.cancel();

    setState(() {
      _statusMessage = status.statusMessage;
      _progress = status.progress;

      if (status.progress >= _highProgressThreshold || status.isInstallComplete || status.isRebooting) {
        _reachedHighProgress = true;
      }

      if (status.isSuccess) {
        _isUpdating = false;
        _isSuccess = true;
      } else if (status.isFailed) {
        _isUpdating = false;
        _isFailed = true;
      } else if (_reachedHighProgress) {
        _startSuccessTimer();
      }
    });
  }

  void _startSuccessTimer() {
    _successTimer?.cancel();
    _successTimer = Timer(_successTimeout, () {
      if (!mounted) return;
      if (_reachedHighProgress && _isUpdating && !_isSuccess && !_isFailed) {
        setState(() {
          _isUpdating = false;
          _isSuccess = true;
          _statusMessage = 'Device is rebooting with new firmware';
        });
      }
    });
  }

  void _handleConnectionLost() {
    if (!mounted) return;
    if (_reachedHighProgress && _isUpdating && !_isSuccess && !_isFailed) {
      setState(() {
        _isUpdating = false;
        _isSuccess = true;
        _statusMessage = 'Device is rebooting with new firmware';
      });
    }
  }

  void _showError(String message) {
    final t = context.omi;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: t.error));
  }

  Future<void> _cancelUpdate() async {
    if (_connection != null) {
      await _connection!.cancelOtaUpdate();
    }
    setState(() {
      _isUpdating = false;
      _statusMessage = 'Update cancelled';
    });
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required FaIconData icon,
    bool obscureText = false,
    Widget? suffixIcon,
    int maxLines = 1,
  }) {
    final t = context.omi;
    return Container(
      decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        maxLines: maxLines,
        style: TextStyle(color: t.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle: TextStyle(color: t.textTertiary),
          labelStyle: TextStyle(color: t.textSecondary),
          prefixIcon: SizedBox(
            width: 48,
            child: Center(child: FaIcon(icon, color: t.textSecondary, size: 18)),
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          suffixIcon: suffixIcon,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        ),
      ),
    );
  }

  Widget _buildVersionItem({
    required FaIconData icon,
    required String label,
    required String version,
    Color? iconColor,
    Color? chipColor,
  }) {
    final t = context.omi;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: SizedBox(width: 24, height: 24, child: FaIcon(icon, color: iconColor ?? t.textSecondary, size: 18)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: t.textPrimary, fontSize: 17, fontWeight: FontWeight.w400),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: chipColor ?? t.bgTertiary, borderRadius: BorderRadius.circular(100)),
            child: Text(
              version,
              style: TextStyle(color: t.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateSection() {
    final t = context.omi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Version cards
        Container(
          decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(20)),
          child: Column(
            children: [
              _buildVersionItem(
                icon: FontAwesomeIcons.microchip,
                label: context.l10n.currentVersion,
                version: _currentVersion,
                chipColor: _hasUpdate ? (t.isGlass ? t.error.withValues(alpha: 0.12) : const Color(0xFF3D2A2A)) : null,
              ),
              if (_hasUpdate) ...[
                Divider(height: 1, color: t.divider),
                _buildVersionItem(
                  icon: FontAwesomeIcons.cloudArrowDown,
                  label: context.l10n.latestVersion,
                  version: _latestVersion,
                  chipColor: (t.isGlass ? t.success.withValues(alpha: 0.12) : const Color(0xFF1A3D2E)),
                ),
              ],
            ],
          ),
        ),

        // Up to date status line (only when not needing update)
        if (!_hasUpdate) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Row(
              children: [
                Text(context.l10n.deviceUpToDate, style: TextStyle(color: t.textSecondary, fontSize: 14)),
                const SizedBox(width: 8),
                FaIcon(FontAwesomeIcons.circleCheck, color: t.success, size: 14),
              ],
            ),
          ),
        ],

        // Changelog
        if (_hasUpdate && _changelog.isNotEmpty) ...[
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.only(left: 4, right: 4, bottom: 12),
            child: Text(
              context.l10n.whatsNew,
              style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
            ),
          ),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _changelog
                    .split('\n')
                    .where((line) => line.trim().isNotEmpty)
                    .map(
                      (change) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              margin: const EdgeInsets.only(top: 6),
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(color: t.textSecondary, borderRadius: BorderRadius.circular(3)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                change.trim(),
                                style: TextStyle(color: t.textSecondary, fontSize: 15, height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ],

        if (_hasUpdate) ...[
          const SizedBox(height: 24),
          // WiFi credentials section
          _buildSectionHeader(context.l10n.wifiConfiguration, subtitle: context.l10n.wifiConfigurationSubtitle),
          const SizedBox(height: 16),
          _buildTextField(
            controller: _ssidController,
            label: context.l10n.networkNameSsid,
            hint: context.l10n.enterWifiNetworkName,
            icon: FontAwesomeIcons.wifi,
          ),
          const SizedBox(height: 12),
          _buildTextField(
            controller: _passwordController,
            label: context.l10n.password,
            hint: context.l10n.enterWifiPassword,
            icon: FontAwesomeIcons.lock,
            obscureText: _obscurePassword,
            suffixIcon: IconButton(
              icon: FaIcon(
                _obscurePassword ? FontAwesomeIcons.eye : FontAwesomeIcons.eyeSlash,
                color: t.textSecondary,
                size: 16,
              ),
              onPressed: () {
                setState(() {
                  _obscurePassword = !_obscurePassword;
                });
              },
            ),
          ),
          const SizedBox(height: 24),
          // Warning card
          Container(
            decoration: BoxDecoration(
              color: (t.isGlass ? t.warning.withValues(alpha: 0.12) : const Color(0xFF2A2215)),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: (t.isGlass ? t.warning.withValues(alpha: 0.3) : const Color(0xFF4A3D1A))),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  FaIcon(FontAwesomeIcons.triangleExclamation, color: t.warning, size: 18),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'Keep your device powered on and nearby during the update. Do not close the app.',
                      style: TextStyle(color: t.warning, fontSize: 14, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Update button
          GestureDetector(
            onTap: _startOtaUpdate,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(color: t.textPrimary, borderRadius: BorderRadius.circular(14)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FaIcon(FontAwesomeIcons.download, color: t.bgPrimary, size: 16),
                  const SizedBox(width: 10),
                  Text(
                    'Install Update',
                    style: TextStyle(color: t.bgPrimary, fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildProgressSection() {
    final t = context.omi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                SizedBox(
                  width: 120,
                  height: 120,
                  child: Stack(
                    children: [
                      SizedBox(
                        width: 120,
                        height: 120,
                        child: CircularProgressIndicator(
                          value: _progress > 0 ? _progress / 100 : null,
                          strokeWidth: 8,
                          backgroundColor: t.bgTertiary,
                          valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
                        ),
                      ),
                      if (_progress > 0)
                        Center(
                          child: Text(
                            '$_progress%',
                            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: t.textPrimary),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: t.textPrimary),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          decoration: BoxDecoration(
            color: (t.isGlass ? t.warning.withValues(alpha: 0.12) : const Color(0xFF2A2215)),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: (t.isGlass ? t.warning.withValues(alpha: 0.3) : const Color(0xFF4A3D1A))),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                FaIcon(FontAwesomeIcons.triangleExclamation, color: t.warning, size: 18),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Do not turn off your device or close the app during the update.',
                    style: TextStyle(color: t.warning, fontSize: 14, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: _cancelUpdate,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: t.bgSecondary,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.error.withValues(alpha: 0.5)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FaIcon(FontAwesomeIcons.xmark, color: t.error, size: 16),
                const SizedBox(width: 10),
                Text(
                  'Cancel Update',
                  style: TextStyle(color: t.error, fontSize: 17, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessSection() {
    final t = context.omi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                      color: (t.isGlass ? t.success.withValues(alpha: 0.12) : const Color(0xFF1A3D2E)),
                      borderRadius: BorderRadius.circular(40)),
                  child: Center(child: FaIcon(FontAwesomeIcons.check, color: t.success, size: 32)),
                ),
                const SizedBox(height: 24),
                Text(
                  'Firmware Updated!',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: t.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your ${widget.device?.name ?? "OmiGlass"} has been updated successfully. The device will restart automatically.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: t.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: () {
            routeToPage(context, const HomePageWrapper(), replace: true);
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(color: t.textPrimary, borderRadius: BorderRadius.circular(14)),
            child: Center(
              child: Text(
                context.l10n.done,
                style: TextStyle(color: t.bgPrimary, fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFailedSection() {
    final t = context.omi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                      color: (t.isGlass ? t.error.withValues(alpha: 0.12) : const Color(0xFF3D1A1A)),
                      borderRadius: BorderRadius.circular(40)),
                  child: Center(child: FaIcon(FontAwesomeIcons.xmark, color: t.error, size: 32)),
                ),
                const SizedBox(height: 24),
                Text(
                  'Update Failed',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: t.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  _statusMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: t.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: () {
            setState(() {
              _isFailed = false;
              _statusMessage = '';
              _progress = 0;
            });
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(color: t.textPrimary, borderRadius: BorderRadius.circular(14)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                FaIcon(FontAwesomeIcons.arrowRotateLeft, color: t.bgPrimary, size: 16),
                const SizedBox(width: 10),
                Text(
                  'Try Again',
                  style: TextStyle(color: t.bgPrimary, fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(14)),
            child: Center(
              child: Text(
                'Go Back',
                style: TextStyle(color: t.textSecondary, fontSize: 17, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingSection() {
    final t = context.omi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(color: t.bgSecondary, borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(48),
            child: Center(
              child: Column(
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(t.textPrimary),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(_statusMessage, style: TextStyle(color: t.textPrimary, fontSize: 15)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title, {String? subtitle}) {
    final t = context.omi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(color: t.textPrimary, fontSize: 20, fontWeight: FontWeight.w600),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(subtitle, style: TextStyle(color: t.textSecondary, fontSize: 14)),
        ],
      ],
    );
  }

  Widget _buildContent() {
    if (_isLoading) return _buildLoadingSection();
    if (_isSuccess) return _buildSuccessSection();
    if (_isFailed) return _buildFailedSection();
    if (_isUpdating) return _buildProgressSection();
    return _buildUpdateSection();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return PopScope(
      canPop: !_isUpdating,
      child: Scaffold(
        backgroundColor: t.bgPrimary,
        appBar: AppBar(
          backgroundColor: t.bgPrimary,
          elevation: 0,
          leading: _isUpdating
              ? const SizedBox()
              : IconButton(
                  icon: const FaIcon(FontAwesomeIcons.chevronLeft, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                ),
          title: Text(
            'Firmware Update',
            style: TextStyle(color: t.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: _buildContent(),
          ),
        ),
      ),
    );
  }
}
