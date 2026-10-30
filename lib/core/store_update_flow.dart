// Store Admin v1.1.2: coordinates the update check from both entry
// points — the automatic on-launch check and the manual check on the
// dedicated Updates screen. One policy object, so the two entries
// can never disagree:
//
// LAUNCH CHECK (foreground only — runs once per app session, from
// the admin tab shell, after the first frame):
// - Skipped when the user turned "Automatic Updates" OFF.
// - Silent on every non-update outcome: no update, check failure,
//   session dismissal, or an active "remind tonight" suppression.
//   Failures land in the diagnostics log with the real reason; the
//   user is never interrupted by a check that found nothing.
// - Shows the Software Update screen only for a strictly newer
//   versionCode. Closing it marks that versionCode dismissed for
//   this session (see [StoreUpdateSession]).
//
// MANUAL CHECK (Updates screen): always fetches fresh, ignores the
// session dismissal and the remind-tonight suppression, and always
// reports an outcome IN THE SCREEN ITSELF: a loading indicator
// while fetching, the update screen, an "up to date" message, or a
// loud error dialog with the real reason.
//
// THE BLACK-SCREEN LESSON (DeliveryFlow v27.37, ported here
// structurally): the manual check NEVER shows a progress dialog and
// NEVER pops anything blindly. Android Back during a check must
// return to the previous screen, never a black screen — so results
// that arrive after the screen is gone are ignored via mounted +
// generation-token guards in the Updates screen itself.
//
// "REMIND ME TONIGHT": stores the versionCode + time. The launch
// check suppresses that version only until 18:00 on the same day
// ([StoreUpdateSession.isRemindSuppressed]); at the next evening
// launch — or any later day — the screen returns. It never
// installs anything by itself.

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/diagnostics.dart';
import '../screens/updates_screen.dart';
import 'store_update.dart';

class StoreUpdateFlow {
  StoreUpdateFlow({
    required this.service,
    StoreUpdateSession? session,
    SharedPreferences? prefs,
  })  : _session = session ?? StoreUpdateSession(),
        _prefs = prefs;

  final StoreUpdateService service;
  final StoreUpdateSession _session;
  SharedPreferences? _prefs;

  static const String autoCheckKey = 'store_update_auto_check';
  static const String remindCodeKey = 'store_update_remind_code';
  static const String remindTimeKey = 'store_update_remind_time_millis';

  StoreUpdateSession get sessionForTest => _session;

  Future<SharedPreferences> _prefsInstance() async =>
      _prefs ??= await SharedPreferences.getInstance();

  Future<bool> autoCheckEnabled() async {
    final prefs = await _prefsInstance();
    // Default ON: a fresh install checks on launch until the user
    // turns "Automatic Updates" off on the update screen.
    return prefs.getBool(autoCheckKey) ?? true;
  }

  Future<void> setAutoCheckEnabled(bool value) async {
    final prefs = await _prefsInstance();
    await prefs.setBool(autoCheckKey, value);
    Diagnostics.instance.log(
        'Automatic update check ${value ? 'enabled' : 'disabled'}');
  }

  Future<void> _setRemindTonight(int versionCode) async {
    final prefs = await _prefsInstance();
    await prefs.setInt(remindCodeKey, versionCode);
    await prefs.setInt(
        remindTimeKey, DateTime.now().millisecondsSinceEpoch);
    Diagnostics.instance.log(
        'Update $versionCode: remind tonight (no install scheduled)');
  }

  Future<bool> _remindSuppressed(int versionCode) async {
    final prefs = await _prefsInstance();
    final code = prefs.getInt(remindCodeKey);
    final millis = prefs.getInt(remindTimeKey);
    return StoreUpdateSession.isRemindSuppressed(
      remindCode: code,
      remindSetAt:
          millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis),
      manifestCode: versionCode,
      now: DateTime.now(),
    );
  }

  Future<void> showUpdateScreen(
    BuildContext context,
    StoreUpdateManifest manifest, {
    required bool autoCheck,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SoftwareUpdateScreen(
          manifest: manifest,
          service: service,
          autoCheckEnabled: autoCheck,
          onAutoCheckChanged: setAutoCheckEnabled,
          onRemindTonight: () => _setRemindTonight(manifest.versionCode),
          onClosed: () => _session.dismiss(manifest.versionCode),
        ),
      ),
    );
  }

  /// Installed build number, or null when it cannot be read.
  Future<int?> currentVersionCode() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return int.tryParse(info.buildNumber);
    } catch (_) {
      return null;
    }
  }

  /// Human installed-version label ("1.1.2 (4)"), or null when it
  /// cannot be read. Used by the Updates screen's version display.
  Future<String?> currentVersionLabel() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version} (${info.buildNumber})';
    } catch (_) {
      return null;
    }
  }

  /// Automatic launch check. Never throws, never shows anything
  /// except the update screen for a genuinely newer version.
  Future<void> checkOnLaunch(BuildContext context) async {
    try {
      if (!await autoCheckEnabled()) return;
      final current = await currentVersionCode();
      if (current == null) {
        Diagnostics.instance.log(
            'Update check skipped: installed build number unreadable');
        return;
      }
      final manifest = await service.fetchManifest();
      if (!manifest.isNewerThan(current)) return;
      if (_session.isDismissed(manifest.versionCode)) return;
      if (await _remindSuppressed(manifest.versionCode)) return;
      if (!context.mounted) return;
      Diagnostics.instance.log(
          'Update available on launch: ${manifest.versionName}');
      // The screen's own Automatic Updates row must reflect the
      // real setting, not a hardcoded value.
      final auto = await autoCheckEnabled();
      if (!context.mounted) return;
      await showUpdateScreen(context, manifest, autoCheck: auto);
    } catch (_) {
      // Launch check is silent by design: the failure is already in
      // the diagnostics log (service logs every fetch failure).
    }
  }
}

/// Non-visual widget that runs the launch check exactly once per
/// app session. It lives inside the admin tab shell (under the
/// MaterialApp Navigator, so it can push the update screen) and
/// renders nothing.
class StoreUpdateLaunchCheck extends StatefulWidget {
  final StoreUpdateFlow flow;

  const StoreUpdateLaunchCheck({super.key, required this.flow});

  @override
  State<StoreUpdateLaunchCheck> createState() =>
      _StoreUpdateLaunchCheckState();
}

class _StoreUpdateLaunchCheckState extends State<StoreUpdateLaunchCheck> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_started || !mounted) return;
      _started = true;
      widget.flow.checkOnLaunch(context);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
