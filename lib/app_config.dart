// ============================================================
// CareTimeline - App Configuration
// ============================================================

class AppConfig {
  /// Integrated AI Key
  static const String defaultApiKey = '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';

  /// Compile-time fallback API key if provided via --dart-define
  static const String dartDefineApiKey = String.fromEnvironment('GEMINI_API_KEY');

  /// Groq API Endpoint & Active Models
  static const String groqBaseUrl = 'https://api.groq.com/openai/v1/chat/completions';
  static const List<String> groqModels = [
    'openai/gpt-oss-20b',
    'openai/gpt-oss-120b',
    'qwen/qwen3.8-27b',
    'allam-2-7b',
  ];

  /// Gemini API Endpoint & Active Models
  static const List<String> geminiModels = [
    'gemini-1.5-flash',
    'gemini-2.0-flash',
    'gemini-1.5-pro',
  ];

  static const String geminiModel = 'gemini-1.5-flash';
  static const String geminiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models';

  static String geminiEndpointWithKey(String apiKey, {String model = geminiModel}) =>
      '$geminiBaseUrl/$model:generateContent?key=$apiKey';

  static bool get hasDefaultApiKey => defaultApiKey.trim().isNotEmpty;
}
