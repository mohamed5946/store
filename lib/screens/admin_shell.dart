// Admin shell: dashboard (analytics), products, categories, orders,
// team, settings + diagnostics. Apple-level feel: weighted motion is kept
// simple and calm — animated switching, no popping, loading states first.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/analytics_steps.dart';
import '../core/dashboard_stats.dart';
import '../core/diagnostics.dart';
import '../core/homepage.dart';
import '../core/identifier.dart';
import '../core/sample_data.dart';
import '../core/store_update.dart';
import '../core/store_update_flow.dart';
import '../services/backend.dart';
import '../services/cloudinary.dart';
import '../services/templates_service.dart';
import '../screens/manual_order_screen.dart';
import '../screens/storefront_preview.dart';
import '../screens/updates_screen.dart';
import '../theme/flow_theme.dart';
import '../theme/store_design.dart';

part 'admin_shell_widgets.dart';
part 'admin_dashboard_tab.dart';
part 'admin_products_tab.dart';
part 'admin_categories_tab.dart';
part 'admin_orders_tab.dart';
part 'incomplete_orders_screen.dart';
part 'admin_team_tab.dart';
part 'admin_settings_tab.dart';
part 'feedback_screen.dart';
part 'templates_screen.dart';

class AdminShell extends StatefulWidget {
  const AdminShell({super.key, required this.onSignedOut, this.themeController});
  final VoidCallback onSignedOut;
  final FlowThemeController? themeController;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _tab = 0;

  // Incomplete orders (2026-11-27): count of new drafts for the nav
  // label. One-shot count query on mount + whenever the tab is
  // tapped — not a live listener. The FlowNavPill has no badge
  // support, so the count rides in the label string.
  int? _newDraftsCount;

  Future<void> _refreshNewDraftsCount() async {
    try {
      final count = await Backend.instance.newDraftsCount();
      if (mounted) setState(() => _newDraftsCount = count);
    } catch (_) {
      // Count failure never blocks the shell — the label just
      // shows without a number.
    }
  }

  // v1.1.2: the once-per-session launch update check lives in the
  // tab shell, under the MaterialApp Navigator so it can push the
  // Software Update screen. It renders nothing and runs once per
  // shell mount (see StoreUpdateLaunchCheck).
  late final StoreUpdateFlow _updateFlow =
      StoreUpdateFlow(service: StoreUpdateService());

  // Lazy sweep (contract §5): on app boot (this shell mounts after
  // sign-in) and every 30 minutes while the app is open. The third
  // trigger lives in the orders list load. Best-effort, logged.
  Timer? _sweepTimer;

  @override
  void initState() {
    super.initState();
    unawaited(Backend.instance.runLazySweep());
    _sweepTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => unawaited(Backend.instance.runLazySweep()),
    );
    unawaited(_refreshNewDraftsCount());
  }

  @override
  void dispose() {
    _sweepTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const _DashboardTab(),
      const _ProductsTab(),
      const _CategoriesTab(),
      _OrdersTab(onOpenIncompleteOrders: () => setState(() => _tab = 7)),
      const _TemplatesTab(),
      const _FeedbackTab(),
      const _TeamTab(),
      const _IncompleteOrdersTab(),
      _SettingsTab(
        onSignedOut: widget.onSignedOut,
        themeController: widget.themeController,
      ),
    ];
    final variant = FlowThemeControllerScope.maybeOf(context)?.variant ??
        FlowThemeVariant.liquidGloss;
    return FlowScaffold(
      variant: variant,
      appBar: AppBar(title: const Text('إدارة المتجر')),
      body: Stack(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: KeyedSubtree(key: ValueKey<int>(_tab), child: pages[_tab]),
          ),
          StoreUpdateLaunchCheck(flow: _updateFlow),
        ],
      ),
      bottomNavigationBar: FlowNavPill(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          unawaited(_refreshNewDraftsCount());
        },
        icons: const [
          Icons.analytics_outlined,
          Icons.inventory_2_outlined,
          Icons.category_outlined,
          Icons.receipt_long_outlined,
          Icons.style_outlined,
          Icons.feedback_outlined,
          Icons.group_outlined,
          Icons.phone_in_talk_outlined,
          Icons.settings_outlined,
        ],
        labels: [
          'الرئيسية',
          'المنتجات',
          'الأقسام',
          'الطلبات',
          'القوالب',
          'الشكاوى',
          'الفريق',
          'طلبات ناقصة${_newDraftsCount != null && _newDraftsCount! > 0 ? ' ($_newDraftsCount)' : ''}',
          'الإعدادات',
        ],
      ),
    );
  }
}

