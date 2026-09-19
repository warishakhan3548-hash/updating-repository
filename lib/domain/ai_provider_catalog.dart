/// Provider routing is independent of the model owner (e.g. Meta/Llama on
/// Groq). Endpoints are bundled; model IDs always come from live discovery.
enum AiProviderProtocol { gemini, chatCompletions, anthropicMessages }

class AiProviderDefinition {
  const AiProviderDefinition(
    this.id,
    this.label,
    this.baseUrl, {
    this.protocol = AiProviderProtocol.chatCompletions,
    this.modelsPath = '/models',
  });
  final String id, label, baseUrl, modelsPath;
  final AiProviderProtocol protocol;
  bool get isCustom => id == 'Compatible';

  static const values = <AiProviderDefinition>[
    AiProviderDefinition(
      'Gemini',
      'Google Gemini',
      'https://generativelanguage.googleapis.com/v1beta',
      protocol: AiProviderProtocol.gemini,
    ),
    AiProviderDefinition('OpenAI', 'OpenAI', 'https://api.openai.com/v1'),
    AiProviderDefinition('xAI', 'xAI / Grok', 'https://api.x.ai/v1'),
    AiProviderDefinition(
      'Groq',
      'Groq (Llama and more)',
      'https://api.groq.com/openai/v1',
    ),
    AiProviderDefinition(
      'Anthropic',
      'Anthropic / Claude',
      'https://api.anthropic.com/v1',
      protocol: AiProviderProtocol.anthropicMessages,
    ),
    AiProviderDefinition('Mistral', 'Mistral', 'https://api.mistral.ai/v1'),
    AiProviderDefinition('DeepSeek', 'DeepSeek', 'https://api.deepseek.com'),
    AiProviderDefinition(
      'OpenRouter',
      'OpenRouter',
      'https://openrouter.ai/api/v1',
      modelsPath: '/models/user',
    ),
    AiProviderDefinition(
      'Together',
      'Together AI (Llama and more)',
      'https://api.together.ai/v1',
    ),
    AiProviderDefinition(
      'HuggingFace',
      'Hugging Face',
      'https://router.huggingface.co/v1',
    ),
    AiProviderDefinition('Compatible', 'Other / OpenAI-compatible', ''),
  ];

  static AiProviderDefinition forId(String id) {
    final canonical = id == 'OpenAI-compatible' ? 'Compatible' : id;
    return values.firstWhere(
      (p) => p.id == canonical,
      orElse: () => throw const FormatException('Choose a supported provider.'),
    );
  }
}
