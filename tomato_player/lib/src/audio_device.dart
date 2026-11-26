/// Dispositivo de saida de audio oferecido pelo motor.
class AudioDevice {
  const AudioDevice({required this.name, required this.description});

  /// Identificador exato aceito por `TomatoPlayer.setAudioDevice`.
  final String name;

  /// Rotulo legivel (ex.: "Built-in Audio Analog Stereo").
  final String description;

  /// `auto` devolve a escolha de dispositivo para o motor.
  static const String auto = 'auto';

  @override
  bool operator ==(Object other) =>
      other is AudioDevice &&
      other.name == name &&
      other.description == description;

  @override
  int get hashCode => Object.hash(name, description);
}