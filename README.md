# YouTube Music Player (Flutter, nativo)

Cliente de YouTube Music em Flutter com reprodução nativa, sem WebView tocando
áudio. Roda em **Linux** (libmpv) e **Android** (Media3/ExoPlayer), usando
`tomato_player` como motor e `audio_service` para segundo plano e teclas de
mídia.

## Recursos

- Navegação pelo YouTube Music: home, busca, biblioteca, playlists e artistas.
- Reprodução nativa de áudio (MP4/AAC ou WebM/Opus), com fila e troca de faixa.
- Segundo plano:
  - Linux: MPRIS (`audio_service_mpris`).
  - Android: serviço em primeiro plano e notificação de mídia.
- Teclas de mídia do teclado (Play/Pause, Próxima, Anterior).
- Skip automático:
  - Anúncios não existem no fluxo: o app pede o áudio direto, não o player web.
  - Intro/sponsor via SponsorBlock, com categorias configuráveis.
  - Opção de pular N segundos fixos de intro.
- Login Google (cookies), com conta, curtidas e biblioteca.
- Qualidade de áudio configurável (baixa, normal, alta).
- Seleção de saída de áudio no Linux (quando o backend expõe dispositivos).

## Estrutura

```
lib/
  src/api/          cliente InnerTube (WEB_REMIX), parser e fachada
  src/auth/         captura de cookies, sessão persistida
  src/models/       modelos de mídia e respostas
  src/player/       resolução de stream, SponsorBlock, audio_service
  src/state/        preferências
  src/ui/           telas e widgets
tomato_player/      plugin do motor (libmpv no Linux, Media3 no Android)
third_party/        stub Linux do flutter_inappwebview
```

## Requisitos

- Flutter estável com Dart 3.8 ou mais novo.
- Linux:
  - `libmpv-dev` e `mpv` (o plugin compila contra `mpv.pc`).
  - Verifique com `pkg-config --modversion mpv`.
  - Em Pop!_OS/Ubuntu: `sudo apt install libmpv-dev mpv`.
- Android:
  - SDK e AGP 9 (o projeto já está configurado).
  - JDK compatível com o AGP.
  - O plugin `flutter_inappwebview` precisa da versão `6.2.0-beta.3`: a
    `6.1.5` quebra no AGP 9.

## Como rodar

```bash
flutter pub get
flutter run -d linux
flutter run -d <device-android>
```

Builds:

```bash
flutter build linux --release
flutter build apk --release
```

## Pipeline (GitHub Actions)

A pipeline em `.github/workflows/build.yml` compila **Linux**, **Android** e
**Windows** em paralelo apenas quando você cria uma tag `v*` ou dispara
manualmente (`workflow_dispatch`). Commits comuns não rodam pipeline.

- **Linux**: instala `libmpv-dev`/GTK no runner e gera
  `youtube_music_player_linux_x64.tar.gz`.
- **Android**: usa JDK 17 e gera `youtube_music_player_android.apk`.
- **Windows**: baixa automaticamente o pacote `mpv-dev` prebuilt (shinchiro),
  define `MPV_PREFIX` e gera `youtube_music_player_windows_x64.zip` com a
  `libmpv-2.dll` incluída. Não precisa instalar nada manualmente.

Os três arquivos são anexados como *artifacts* do run. Ao criar uma tag `v*`
(ex.: `v1.0.0`), a pipeline também publica uma GitHub Release com os mesmos
arquivos.

## Como o áudio é resolvido

`lib/src/player/stream_resolver.dart` chama o endpoint privado
`youtubei/v1/player` com o cliente **VISIONOS** e um `visitorData` obtido em
`youtubei/v1/visitor_id`.

Por que esse caminho:

- O cliente devolve URL de áudio direta, sem cifra de assinatura e sem o
  parâmetro `n` de throttling.
- O `visitorData` é obrigatório. Sem ele o YouTube libera só os primeiros
  ~750 KiB do arquivo e responde `403` no resto, o que fazia o mpv falhar com
  `HTTP error 403 Forbidden`.
- Se a faixa só tiver HLS, o manifesto `.m3u8` é devolvido. O mpv toca HLS
  nativamente e o Android já inclui `media3-exoplayer-hls`.
- Quando há sessão Google salva, o cabeçalho `Cookie` também é enviado, o que
  ajuda em conteúdo restrito por idade ou conta.
- Existe fallback para `youtube_explode_dart` (`androidSdkless`) em vídeos que o
  cliente VISIONOS não atende, por exemplo conteúdo "made for kids".

MPRIS fica em `org.mpris.MediaPlayer2.app.ytmusic.player.audio.instance<pid>`.

## Login

Android:

1. Abra **Conta** e use o WebView de login do Google.
2. Os cookies são capturados e guardados na sessão do app.

Linux:

1. Abra **Conta** e escolha uma das opções:
   - Importar cookies do Firefox (`cookies.sqlite` do perfil mais recente).
    Procura em `~/.mozilla/firefox`, `~/.config/mozilla/firefox`,
    `~/.local/share/mozilla/firefox`, snap e flatpak.
   - Colar o cabeçalho `Cookie:` copiado do DevTools.
   - Colar um `cookies.txt` (formato Netscape) ou um JSON de extensão.
2. A sessão fica em `getApplicationSupportDirectory()` com permissão `600`.

### Conta de marca (brand account)

O app lê `DELEGATED_SESSION_ID` e `SESSION_INDEX` da página inicial do YouTube
Music e envia `onBehalfOfUser`/`X-Goog-PageId` nas chamadas. Assim, curtidas,
playlists e biblioteca ficam no canal correto.

- Capture os cookies com o **canal da conta de marca já selecionado** no site.
  No Android, troque o canal no avatar dentro do WebView antes de tocar em
  "Concluir".
- Se a detecção automática falhar, use **Conta → Conta de marca** e informe o ID
  numérico. Ele aparece em `myaccount.google.com/brandaccounts`, na URL
  `myaccount.google.com/b/ID`.
- Deixe o campo vazio para voltar à conta Google padrão.

Limitações do login:

- O Google pode bloquear login embutido em WebView. Se falhar, use a importação
  de cookies.
- Contas com 2FA podem exigir concluir o login no navegador antes de copiar os
  cookies.
- Os cookies expiram. Se a biblioteca parar de carregar, refaça o login.

## WebView no Linux

O app só embute WebView no Android. No Linux o login usa navegador externo e
importação de cookies, então o plugin real (que exige WPE WebKit) não é
necessário. Por isso `pubspec.yaml` aponta `flutter_inappwebview_linux` para o
stub em `third_party/flutter_inappwebview_linux/`.

Se quiser o WebView real no Linux, remova o `dependency_overrides` e instale as
dependências de WPE WebKit exigidas pela versão do plugin.

## Testes

```bash
flutter test
RUN_NETWORK_TESTS=1 flutter test test/api_smoke_test.dart
```

O teste de rede cobre home, busca e resolução de stream. Os demais testes não
usam rede.

## Observações

- O arquivo de referência HAR usado durante o desenvolvimento
  (`~/Downloads/youtubemusic_reference_api`) contém respostas autenticadas e não
  deve ser versionado. Tokens e cookies expiram.
- SponsorBlock depende dos dados enviados pela comunidade.
- Não há cache offline de faixas.
- O skip de anúncio é consequência de tocar o stream de áudio direto; não há
  lógica de "fechar banner".
