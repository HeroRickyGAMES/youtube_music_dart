/// Describe uma mídia a ser reproduzida.
class TomatoMedia {
  const TomatoMedia(
    this.uri, {
    this.httpHeaders = const {},
    this.options = const {},
  });

  /// URL do stream.
  ///
  /// IMPORTANTE: quando a API exigir proxy, passe a URL já resolvida com o
  /// proxy (o app controla isso fora deste plugin).
  final String uri;

  /// Cabeçalhos HTTP adicionais (ex.: token da API).
  final Map<String, String> httpHeaders;

  /// Opções extras aplicadas no open (propriedades do motor).
  final Map<String, String> options;
}