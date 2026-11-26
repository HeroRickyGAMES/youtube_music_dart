import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../player/player_controller.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'mini_player.dart';
import 'player_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'theme.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  StreamSubscription<String>? _messages;

  static const _pages = <Widget>[
    HomePage(),
    SearchPage(),
    LibraryPage(),
    SettingsPage(),
  ];

  static const _destinations = <_Destination>[
    _Destination('Início', Icons.home_outlined, Icons.home),
    _Destination('Buscar', Icons.search_outlined, Icons.search),
    _Destination('Biblioteca', Icons.library_music_outlined, Icons.library_music),
    _Destination('Ajustes', Icons.settings_outlined, Icons.settings),
  ];

  @override
  void initState() {
    super.initState();
    _messages = context.read<PlayerController>().messages.listen(_showMessage);
  }

  @override
  void dispose() {
    _messages?.cancel();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 800;
    final body = Column(
      children: [
        Expanded(
          child: IndexedStack(index: _index, children: _pages),
        ),
        const _MiniPlayerArea(),
      ],
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (index) => setState(() => _index = index),
              labelType: NavigationRailLabelType.all,
              minWidth: 80,
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: _BrandMark(),
              ),
              destinations: [
                for (final destination in _destinations)
                  NavigationRailDestination(
                    icon: Icon(destination.icon),
                    selectedIcon: Icon(destination.selectedIcon),
                    label: Text(destination.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1, color: Colors.white10),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          for (final destination in _destinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.label,
            ),
        ],
      ),
    );
  }
}

/// Keeps the mini player above the bottom navigation bar and reserves its
/// space so page content is never hidden behind it.
class _MiniPlayerArea extends StatelessWidget {
  const _MiniPlayerArea();

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerController>();
    if (player.currentTrack == null) return const SizedBox.shrink();
    return MiniPlayer(onOpen: () => _openPlayer(context));
  }

  void _openPlayer(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const PlayerPage(),
    ));
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      decoration: const BoxDecoration(
        color: AppColors.accent,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 26),
    );
  }
}

class _Destination {
  const _Destination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
