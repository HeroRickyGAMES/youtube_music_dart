/// Linux stub for `flutter_inappwebview`.
///
/// The real Linux implementation depends on WPE WebKit, which is not needed:
/// this app only embeds a WebView for Google login on Android. On Linux the
/// login flow uses the external browser plus cookie import.
///
/// Registering a no-op class keeps the federated plugin resolvable without
/// pulling the WPE native build into the Linux bundle.
class FlutterInAppWebViewLinuxStub {
  static void registerWith() {}
}
