// Admin shell: dashboard (analytics), products, categories, orders,
// team, settings + diagnostics. Apple-level feel: weighted motion is kept
// simple and calm — animated switching, no popping, loading states first.
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/analytics_steps.dart';
import '../core/dashboard_stats.dart';
import '../core/diagnostics.dart';
import '../core/homepage.dart';
import '../core/sample_data.dart';
import '../core/store_update.dart';
import '../core/store_update_flow.dart';
import '../services/backend.dart';
import '../services/cloudinary.dart';
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
part 'admin_team_tab.dart';
part 'admin_settings_tab.dart';
part 'feedback_screen.dart';

class AdminShell extends StatefulWidget {
  const AdminShell({super.key, required this.onSignedOut, this.themeController});
  final VoidCallback onSignedOut;
  final FlowThemeController? themeController;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _tab = 0;

  // v1.1.2: the once-per-session launch update check lives in the
  // tab shell, under the MaterialApp Navigator so it can push the
  // Software Update screen. It renders nothing and runs once per
  // shell mount (see StoreUpdateLaunchCheck).
  late final StoreUpdateFlow _updateFlow =
      StoreUpdateFlow(service: StoreUpdateService());

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const _DashboardTab(),
      const _ProductsTab(),
      const _CategoriesTab(),
      const _OrdersTab(),
      const _FeedbackTab(),
      const _TeamTab(),
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
        onDestinationSelected: (i) => setState(() => _tab = i),
        icons: const [
          Icons.analytics_outlined,
          Icons.inventory_2_outlined,
          Icons.category_outlined,
          Icons.receipt_long_outlined,
          Icons.feedback_outlined,
          Icons.group_outlined,
          Icons.settings_outlined,
        ],
        labels: const ['الرئيسية', 'المنتجات', 'الأقسام', 'الطلبات', 'الشكاوى', 'الفريق', 'الإعدادات'],
      ),
    );
  }
}

