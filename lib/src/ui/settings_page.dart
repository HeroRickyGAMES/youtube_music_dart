import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../player/player_controller.dart';
import '../state/settings_store.dart';
import 'theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  static const _categories = <String, String>{
    'intro': 'Introdução',
    'sponsor': 'Patrocínio',
    'selfpromo': 'Autopromoção',
    'interaction': 'Pedido de inscrição',
    'music_offtopic': 'Fora do tópico',
    'preview': 'Prévia',
  };

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final player = context.read<PlayerController>();

    Future<void> apply(void Function(SettingsStore s) change) async {
      await settings.update(change);
      player.applySettings();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 140),
        children: [
          const _SectionHeader('Anúncios e introduções'),
          SwitchListTile(
            title: const Text('Pular anúncios'),
            subtitle: const Text(
              'O áudio é resolvido direto do YouTube, então anúncios não '
              'chegam a ser carregados.',
            ),
            value: settings.skipAds,
            onChanged: (value) => apply((s) => s.skipAds = value),
          ),
          SwitchListTile(
            title: const Text('Pular introduções'),
            subtitle: const Text('Usa os trechos enviados pela comunidade.'),
            value: settings.skipIntros,
            onChanged: (value) => apply((s) => s.skipIntros = value),
          ),
          SwitchListTile(
            title: const Text('Pular patrocínios'),
            subtitle: const Text('Patrocínio e autopromoção.'),
            value: settings.skipSponsor,
            onChanged: (value) => apply((s) => s.skipSponsor = value),
          ),
          ListTile(
            title: const Text('Introdução fixa'),
            subtitle: Text(
              settings.fixedIntroSeconds == 0
                  ? 'Desligado'
                  : 'Pular os primeiros ${settings.fixedIntroSeconds}s de cada faixa',
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Slider(
              value: settings.fixedIntroSeconds.toDouble().clamp(0, 60),
              max: 60,
              divisions: 60,
              label: '${settings.fixedIntroSeconds}s',
              onChanged: (value) =>
                  apply((s) => s.fixedIntroSeconds = value.round()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final entry in _categories.entries)
                  FilterChip(
                    label: Text(entry.value),
                    selected: settings.sponsorCategories.contains(entry.key),
                    onSelected: (selected) => apply((s) {
                      if (selected) {
                        s.sponsorCategories.add(entry.key);
                      } else {
                        s.sponsorCategories.remove(entry.key);
                      }
                    }),
                  ),
              ],
            ),
          ),
          const Divider(height: 24),
          const _SectionHeader('Reprodução'),
          SwitchListTile(
            title: const Text('Rádio automática'),
            subtitle: const Text(
              'Continua tocando músicas parecidas quando a fila termina.',
            ),
            value: settings.autoplay,
            onChanged: (value) => apply((s) => s.autoplay = value),
          ),
          ListTile(
            title: const Text('Qualidade do áudio'),
            subtitle: Text(settings.quality.label),
            trailing: DropdownButton<AudioQuality>(
              value: settings.quality,
              underline: const SizedBox.shrink(),
              dropdownColor: AppColors.surfaceHigh,
              items: [
                for (final quality in AudioQuality.values)
                  DropdownMenuItem(
                    value: quality,
                    child: Text(quality.label),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                apply((s) => s.quality = value);
              },
            ),
          ),
          const Divider(height: 24),
          const _SectionHeader('Sobre'),
          const ListTile(
            title: Text('YouTube Music nativo'),
            subtitle: Text(
              'Player Flutter com motor nativo (libmpv no Linux, Media3 no '
              'Android), controle por teclas de mídia e skip automático via '
              'SponsorBlock.',
            ),
          ),
          const ListTile(
            title: Text('Conta'),
            subtitle: Text(
              'Os cookies de sessão ficam salvos apenas neste dispositivo.',
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
