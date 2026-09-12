class AiConfiguration {
  const AiConfiguration({
    this.provider = 'Gemini',
    this.model = '',
    this.endpoint = '',
    this.key = '',
    this.localBrainEnabled = false,
  });
  final String provider, model, endpoint, key;
  final bool localBrainEnabled;

  AiConfiguration copyWith({
    String? provider,
    String? model,
    String? endpoint,
    String? key,
    bool? localBrainEnabled,
  }) => AiConfiguration(
    provider: provider ?? this.provider,
    model: model ?? this.model,
    endpoint: endpoint ?? this.endpoint,
    key: key ?? this.key,
    localBrainEnabled: localBrainEnabled ?? this.localBrainEnabled,
  );

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'model': model,
    'endpoint': endpoint,
    'key': key,
    'localBrainEnabled': localBrainEnabled,
  };
  factory AiConfiguration.fromJson(Map<String, dynamic> data) =>
      AiConfiguration(
        provider: data['provider'] as String? ?? 'Gemini',
        model: data['model'] as String? ?? '',
        endpoint: data['endpoint'] as String? ?? '',
        key: data['key'] as String? ?? '',
        localBrainEnabled: data['localBrainEnabled'] == true,
      );

  Uri get uri {
    if (model.trim().isEmpty || key.trim().isEmpty) {
      throw const FormatException('Enter your model name and API key.');
    }
    if (provider == 'Gemini') {
      if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(model)) {
        throw const FormatException('Enter a model name, not a URL.');
      }
      return Uri.https(
        'generativelanguage.googleapis.com',
        '/v1beta/models/$model:generateContent',
      );
    }
    final value = Uri.tryParse(endpoint.trim());
    if (value == null ||
        value.scheme != 'https' ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment) {
      throw const FormatException(
        'Enter a full HTTPS chat/completions endpoint without credentials or query parameters.',
      );
    }
    return value;
  }
}
