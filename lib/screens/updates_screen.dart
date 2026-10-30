// Store Admin v1.1.2: the dedicated Updates screen + the iOS-style
// Software Update screen, ported from DeliveryFlow's proven pair
// (v27.37/v27.38) and restyled for the Store app.
//
// WHY THIS SHAPE (the v27.37 black-screen lesson, ported
// structurally): a manual check used to show a progress DIALOG and
// dismiss it with an unconditional Navigator.pop() after the fetch.
// Android Back is NOT blocked by barrierDismissible:false, so
// pressing Back mid-check meant the dialog was already gone and the
// blind pop removed the page underneath — an empty navigator that
// Flutter renders as a blank black screen. Here the check lives IN
// THIS SCREEN: tapping "Check for updates" shows a loading card
// inside the screen itself — never a dialog, never a blind pop.
// Results that arrive after the screen is gone (Back pressed
// mid-check) are ignored via mounted + generation-token guards, and
// the page underneath is never touched.
//
// Outcomes: update available → the iOS-style Software Update screen;
// no update → a clear "You're on the latest update" card with the
// installed version; failure → a loud dialog with the exact reason.
import 'package:flutter/material.dart';

import '../core/store_update.dart';
import '../core/store_update_flow.dart';
import '../theme/flow_theme.dart';
import '../theme/store_design.dart';

class UpdatesScreen extends StatefulWidget {
  /// Production callers pass nothing: the real service/flow are
  /// built fresh. Tests inject fakes.
  const UpdatesScreen({super.key, this.service, this.flow});

  final StoreUpdateService? service;
  final StoreUpdateFlow? flow;

  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  late final StoreUpdateService _service;
  late final StoreUpdateFlow _flow;

  bool _ready = false;
  bool _autoCheck = true;
  String? _versionLabel;
  bool _checking = false;
  bool _upToDate = false;

  /// Generation counter: a check that finishes after a newer check
  /// started — or after this screen was popped — must not touch
  /// state. Combined with mounted checks, this is what makes the
  /// black-screen path impossible here: nothing pops.
  int _checkToken = 0;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? StoreUpdateService();
    _flow = widget.flow ?? StoreUpdateFlow(service: _service);
    _load();
  }

  Future<void> _load() async {
    final auto = await _flow.autoCheckEnabled();
    final label = await _flow.currentVersionLabel();
    if (!mounted) return;
    setState(() {
      _autoCheck = auto;
      _versionLabel = label;
      _ready = true;
    });
  }

  Future<void> _onCheck() async {
    if (_checking) return;
    final token = ++_checkToken;
    setState(() {
      _checking = true;
      _upToDate = false;
    });
    StoreUpdateManifest? manifest;
    String? failure;
    int? current;
    try {
      current = await _flow.currentVersionCode();
      manifest = await _service.fetchManifest();
    } catch (e) {
      failure = e is StoreUpdateException ? e.reason : '$e';
    }
    // The screen may be gone (Back pressed mid-check): ignore the
    // result entirely. Never pop, never touch a dead tree.
    if (!mounted || token != _checkToken) return;
    setState(() => _checking = false);
    if (failure != null || manifest == null) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تعذر التحقق من التحديثات'),
          content: Text(failure ?? 'تعذر التحقق من التحديثات'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
      return;
    }
    if (current == null || !manifest.isNewerThan(current)) {
      if (!mounted) return;
      setState(() => _upToDate = true);
      return;
    }
    final auto = await _flow.autoCheckEnabled();
    if (!mounted || token != _checkToken) return;
    await _flow.showUpdateScreen(context, manifest, autoCheck: auto);
  }

  Future<void> _onAutoCheckChanged(bool value) async {
    setState(() => _autoCheck = value);
    await _flow.setAutoCheckEnabled(value);
  }

  @override
  Widget build(BuildContext context) {
    final variant = FlowThemeControllerScope.maybeOf(context)?.variant ??
        FlowThemeVariant.liquidGloss;
    return FlowScaffold(
      variant: variant,
      appBar: AppBar(title: const Text('التحديثات')),
      body: !_ready
          // Near-instant (SharedPreferences + PackageInfo), but a
          // real indicator beats a blank frame every time.
          ? const Center(
              key: ValueKey('updates-loading'),
              child: CircularProgressIndicator(color: FlowPalette.cyan),
            )
          : SingleChildScrollView(
              padding: FlowTokens.screenPadding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FlowCard(
                    key: const ValueKey('updates-current-version'),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline_rounded,
                            color: FlowPalette.cyan, size: 22),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'النسخة الحالية',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Text(_versionLabel ?? '—'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  FlowCard(
                    child: Row(
                      children: [
                        const Icon(Icons.system_update_rounded,
                            color: FlowPalette.cyan, size: 22),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'التحديثات التلقائية',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Switch(
                          key: const ValueKey('updates-auto-check-switch'),
                          value: _autoCheck,
                          onChanged: _onAutoCheckChanged,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  FlowButton(
                    key: const ValueKey('updates-check-button'),
                    label: 'التحقق من التحديثات',
                    icon: Icons.system_update_rounded,
                    onPressed: _checking ? null : _onCheck,
                  ),
                  if (_checking) ...[
                    const SizedBox(height: 12),
                    const FlowCard(
                      key: ValueKey('updates-checking-indicator'),
                      child: Row(
                        children: [
                          CircularProgressIndicator(
                              color: FlowPalette.cyan),
                          SizedBox(width: 16),
                          Expanded(
                              child: Text('جارٍ التحقق من التحديثات…')),
                        ],
                      ),
                    ),
                  ],
                  if (_upToDate && !_checking) ...[
                    const SizedBox(height: 12),
                    FlowCard(
                      key: const ValueKey('updates-up-to-date'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.check_circle_rounded,
                                  color: FlowPalette.success, size: 22),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'أنت على أحدث نسخة',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                              'مفيش تحديثات متاحة دلوقتي — النسخة اللي عندك هي الأحدث.'),
                          if (_versionLabel != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              _versionLabel!,
                              style: const TextStyle(
                                  color: FlowPalette.textSecondary),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

/// The "Updates" settings row, rendered EXACTLY like the sibling rows
/// (same FlowCard + row layout: blue icon, semibold label, chevron).
/// Tapping pushes the Updates screen. Kept as a separate widget so
/// its shape + navigation are testable without pumping Settings.
class UpdatesSettingsRow extends StatelessWidget {
  const UpdatesSettingsRow({super.key});

  @override
  Widget build(BuildContext context) {
    return FlowCard(
      child: Pressable(
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => const UpdatesScreen()),
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Icon(Icons.system_update_rounded,
                  color: FlowPalette.cyan, size: 22),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'التحديثات',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Icon(
                Icons.chevron_left_rounded,
                size: 20,
                color: FlowPalette.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The iOS-style Software Update screen, replicating DeliveryFlow's
/// reference layout in the Store app's Arabic RTL:
///
/// - Light gray screen background (#F2F2F7), white rounded cards.
/// - Top bar: back arrow (in a white circle) + centered
///   "تحديث البرنامج" title.
/// - First card, one row: "التحديثات التلقائية" | "تشغيل/إيقاف >".
///   Tapping opens an On/Off choice: it toggles the automatic update
///   CHECK on launch ONLY. It never means silent install — there is
///   no silent install for sideloaded apps, and this screen never
///   implies one.
/// - Main card: app icon (ST gradient tile) + "إدارة المتجر" and the
///   version name big + real APK size below it + the REAL changelog
///   from the manifest (never invented notes).
/// - BIG blue pill button "تحديث الآن": foreground download with
///   progress, SHA-256 + size verification, then the Android system
///   install prompt (one-tap confirmation is unavoidable).
/// - Below it, a blue text link "ذكّرني الليلة": NOT an overnight
///   install. It dismisses now and re-shows this screen at the next
///   evening launch.
/// - Small gray line under the card: an honest neutral line. No
///   invented legal terms, no fake terms link.
/// - The reference's "ALSO AVAILABLE" section is DELIBERATELY
///   OMITTED: the Store has no parallel version line, so there is
///   nothing else available to offer.
///
/// Closing the screen (back arrow or system back) counts as a
/// session dismissal (via [onClosed]); the launch check will not nag
/// again this session. A manual check always re-opens it.
class SoftwareUpdateScreen extends StatefulWidget {
  final StoreUpdateManifest manifest;
  final StoreUpdateService service;

  /// Current automatic-check setting (true = check on launch).
  final bool autoCheckEnabled;

  /// Called when the user picks a new automatic-check value.
  final ValueChanged<bool> onAutoCheckChanged;

  /// Called when the user taps "Remind Me Tonight" (before pop).
  final VoidCallback onRemindTonight;

  /// Called when the screen closes WITHOUT an update action
  /// (back arrow / system back). Not called after Update Now or
  /// Remind Me Tonight.
  final VoidCallback onClosed;

  const SoftwareUpdateScreen({
    super.key,
    required this.manifest,
    required this.service,
    required this.autoCheckEnabled,
    required this.onAutoCheckChanged,
    required this.onRemindTonight,
    required this.onClosed,
  });

  @override
  State<SoftwareUpdateScreen> createState() => _SoftwareUpdateScreenState();
}

class _SoftwareUpdateScreenState extends State<SoftwareUpdateScreen> {
  static const _iosBlue = Color(0xFF007AFF);
  static const _iosGrayBg = Color(0xFFF2F2F7);
  static const _iosGrayText = Color(0xFF8A8A8E);
  static const _iosCardRadius = 12.0;

  late bool _autoCheck = widget.autoCheckEnabled;
  bool _downloading = false;
  double? _progress;
  String? _error;

  /// True once a close callback has been reported, so the PopScope
  /// handler never double-reports after an explicit button close.
  bool _closeReported = false;

  void _finish({required bool reminded}) {
    if (_closeReported) return;
    _closeReported = true;
    if (reminded) {
      widget.onRemindTonight();
    } else {
      widget.onClosed();
    }
    Navigator.of(context).pop();
  }

  Future<void> _pickAutoCheck() async {
    final picked = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                'التحديثات التلقائية',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                'التحقق من التحديثات عند فتح البرنامج فقط — التثبيت نفسه بيحتاج تأكيدك دايمًا.',
                style: TextStyle(fontSize: 14, color: _iosGrayText),
              ),
            ),
            _autoCheckOption(ctx, true, 'تشغيل'),
            _autoCheckOption(ctx, false, 'إيقاف'),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _autoCheck = picked);
    widget.onAutoCheckChanged(picked);
  }

  Widget _autoCheckOption(BuildContext ctx, bool value, String label) {
    final selected = _autoCheck == value;
    return ListTile(
      title: Text(label),
      trailing: selected
          ? const Icon(Icons.check_rounded, color: _iosBlue)
          : null,
      onTap: () => Navigator.of(ctx).pop(value),
    );
  }

  Future<void> _showError(String reason) async {
    setState(() => _error = reason);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تعذر التحديث'),
        content: Text(reason),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  Future<void> _showPermissionGuidance() async {
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إذن التثبيت مطلوب'),
        content: const Text(
            'عشان البرنامج يثبّت التحديث، لازم تسمح للتطبيق بتثبيت التطبيقات من مصادر غير معروفة من إعدادات الموبايل.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('فتح الإعدادات'),
          ),
        ],
      ),
    );
    if (open == true) {
      try {
        await widget.service.openUnknownAppsSettings();
      } catch (e) {
        if (mounted) await _showError('$e');
      }
    }
  }

  Future<void> _onUpdateNow() async {
    // Unknown-apps permission FIRST: without it Android cannot show
    // the install prompt at all, so downloading first would waste
    // the user's data and time.
    bool allowed;
    try {
      allowed = await widget.service.canInstallUnknownApps();
    } catch (e) {
      await _showError('$e');
      return;
    }
    if (!mounted) return;
    if (!allowed) {
      await _showPermissionGuidance();
      return;
    }
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });
    try {
      final file = await widget.service.downloadAndVerify(
        widget.manifest,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      // Verified: hand to Android's system install prompt. This is
      // the one-tap confirmation — never a silent install.
      await widget.service.installVerifiedApk(file);
      if (!mounted) return;
      // The install prompt is now on top; close this screen behind it.
      _closeReported = true;
      Navigator.of(context).pop();
      return;
    } on StoreUpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _progress = null;
      });
      await _showError(e.reason);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _progress = null;
      });
      await _showError('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final manifest = widget.manifest;
    final sizeText = formatApkSize(manifest.apkSizeBytes);
    final changelog = manifest.changelog.isEmpty
        ? 'نسخة جديدة من إدارة المتجر.'
        : manifest.changelog;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_closeReported) {
          _closeReported = true;
          widget.onClosed();
        }
      },
      child: Scaffold(
        backgroundColor: _iosGrayBg,
        appBar: AppBar(
          backgroundColor: _iosGrayBg,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          leading: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              key: const ValueKey('software-update-back'),
              icon: const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.black87,
                  size: 26,
                ),
              ),
              onPressed: () => _finish(reminded: false),
            ),
          ),
          title: const Text(
            'تحديث البرنامج',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Automatic Updates row (reference card 1) ──
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(_iosCardRadius),
                ),
                child: InkWell(
                  key: const ValueKey('automatic-updates-row'),
                  borderRadius: BorderRadius.circular(_iosCardRadius),
                  onTap: _pickAutoCheck,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const Text(
                          'التحديثات التلقائية',
                          style: TextStyle(fontSize: 16),
                        ),
                        const Spacer(),
                        Text(
                          _autoCheck ? 'تشغيل' : 'إيقاف',
                          style: const TextStyle(
                              fontSize: 16, color: _iosGrayText),
                        ),
                        const SizedBox(width: 2),
                        const Icon(
                          Icons.chevron_left_rounded,
                          size: 20,
                          color: _iosGrayText,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // ── Main update card (reference card 2) ──
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(_iosCardRadius),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFF38BDF8),
                                Color(0xFF2563EB),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          alignment: Alignment.center,
                          child: const Text(
                            'ST',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'إدارة المتجر ${manifest.versionName}',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black87,
                                ),
                              ),
                              if (sizeText.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  sizeText,
                                  style: const TextStyle(
                                      fontSize: 15, color: _iosGrayText),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      changelog,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.45,
                        color: Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        key: const ValueKey('update-now-button'),
                        onPressed: _downloading ? null : _onUpdateNow,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _iosBlue,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              _iosBlue.withValues(alpha: 0.6),
                          disabledForegroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(25),
                          ),
                          elevation: 0,
                        ),
                        child: Text(
                          _downloading
                              ? (_progress == null
                                  ? 'جارٍ التحقق…'
                                  : 'جارٍ التنزيل… ${(_progress! * 100).round()}٪')
                              : 'تحديث الآن',
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    if (_downloading && _progress != null) ...[
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _progress,
                          backgroundColor:
                              _iosBlue.withValues(alpha: 0.15),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              _iosBlue),
                          minHeight: 6,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextButton(
                      key: const ValueKey('remind-tonight-button'),
                      onPressed: _downloading
                          ? null
                          : () => _finish(reminded: true),
                      child: const Text(
                        'ذكّرني الليلة',
                        style: TextStyle(fontSize: 16, color: _iosBlue),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style:
                            const TextStyle(fontSize: 13, color: Colors.red),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'التحديث بيتم من إصدار GitHub الرسمي للمتجر، والملف بيتم التحقق منه قبل التثبيت.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: _iosGrayText),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
