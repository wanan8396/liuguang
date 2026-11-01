import 'package:flutter/material.dart';

import '../../core/app_controller.dart';
import '../home/home_page.dart';
import '../live/live_page.dart';
import '../profile/profile_page.dart';
import '../profile/subscriptions_page.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final AppController controller;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _liveVisited = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.controller.currentConfig != null &&
          widget.controller.homePage == null) {
        widget.controller.refreshHome();
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _index,
      children: [
        HomePage(
          controller: widget.controller,
          onSubscriptions: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => SubscriptionsPage(controller: widget.controller),
            ),
          ),
        ),
        if (_liveVisited)
          LivePage(controller: widget.controller)
        else
          const SizedBox.shrink(),
        ProfilePage(controller: widget.controller),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _index,
      onDestinationSelected: (index) => setState(() {
        _index = index;
        if (index == 1) _liveVisited = true;
      }),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: '首页',
        ),
        NavigationDestination(
          icon: Icon(Icons.live_tv_outlined),
          selectedIcon: Icon(Icons.live_tv),
          label: '电视',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: '我的',
        ),
      ],
    ),
  );
}
