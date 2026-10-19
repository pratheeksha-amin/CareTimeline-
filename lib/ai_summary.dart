import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'app_config.dart';

enum AiFailureCategory {
  missingConfiguration,
  authentication,
  quotaExceeded,
  timeout,
  network,
  invalidResponse,
  emptyRecords,
  unknown,
}

class AiSummaryException implements Exception {
  final AiFailureCategory category;
  final String message;
  final String diagnostic;

  const AiSummaryException({
    required this.category,
    required this.message,
    this.diagnostic = '',
  });

  String get userMessage => '[${categoryLabel(category)}] $message';

  static String categoryLabel(AiFailureCategory category) {
    switch (category) {
      case AiFailureCategory.missingConfiguration:
        return 'Missing configuration';
      case AiFailureCategory.authentication:
        return 'Authentication failure';
      case AiFailureCategory.quotaExceeded:
        return 'Quota exceeded';
      case AiFailureCategory.timeout:
        return 'Timeout';
      case AiFailureCategory.network:
        return 'Network error';
      case AiFailureCategory.invalidResponse:
        return 'Invalid response';
      case AiFailureCategory.emptyRecords:
        return 'Empty records';
      case AiFailureCategory.unknown:
        return 'Unknown error';
    }
  }

  @override
  String toString() => userMessage;
}

class LlmSummaryResult {
  final String text;
  final String model;
  final bool fromLlm;

  const LlmSummaryResult({
    required this.text,
    required this.model,
    this.fromLlm = true,
  });
}

class GeminiAiService {
  static final GeminiAiService instance = GeminiAiService._internal();
  GeminiAiService._internal();

  static const _storage = FlutterSecureStorage();
  static const _apiKeyStorageKey = 'gemini_api_key';
  static const _requestTimeout = Duration(seconds: 25);

  http.Client _client = http.Client();
  String? _debugApiKeyOverride;

  @visibleForTesting
  void debugSetHttpClient(http.Client client) {
    _client = client;
  }

  @visibleForTesting
  void debugSetApiKeyOverride(String? key) {
    _debugApiKeyOverride = key;
  }

  // -- Key management ---------------------------------------------------------

  Future<String?> getStoredOverrideKey() async {
    try {
      final key = await _storage.read(key: _apiKeyStorageKey);
      if (key != null && key.trim().isNotEmpty) {
        return key.trim();
      }
    } catch (_) {}
    return null;
  }

  Future<String?> getApiKey() async {
    if (_debugApiKeyOverride != null) {
      final override = _debugApiKeyOverride!.trim();
      return override.isEmpty ? null : override;
    }
    if (AppConfig.defaultApiKey.trim().isNotEmpty) {
      return AppConfig.defaultApiKey.trim();
    }
    final compileTimeKey = AppConfig.dartDefineApiKey.trim();
    if (compileTimeKey.isNotEmpty) return compileTimeKey;
    return getStoredOverrideKey();
  }

  Future<void> saveApiKey(String key) async {
    try {
      await _storage.write(key: _apiKeyStorageKey, value: key.trim());
    } catch (_) {}
  }

  Future<void> clearApiKey() async {
    try {
      await _storage.delete(key: _apiKeyStorageKey);
    } catch (_) {}
  }

  // -- Prompt / parsing helpers (testable) ------------------------------------

  @visibleForTesting
  static List<Map<String, dynamic>> anonymizeRecords(
    List<Map<String, dynamic>> records,
  ) {
    final chronological = List<Map<String, dynamic>>.from(records)
      ..sort((a, b) => '${a['recordDate']}'.compareTo('${b['recordDate']}'));

    return chronological.map((r) {
      return {
        'date': r['recordDate'],
        'symptom': r['symptomName'],
        'severity': '${r['severity']}/10',
        'description': (r['description'] ?? '').toString().trim().isEmpty
            ? null
            : r['description'],
        'medicine': (r['medicineName'] ?? '').toString().trim().isEmpty
            ? 'None recorded'
            : r['medicineName'],
        'medicine_taken': (r['medicineTaken'] == 1) ? 'Yes' : 'No',
        'observed_effects': (r['observedEffects'] ?? '').toString().trim().isEmpty
            ? 'None recorded'
            : r['observedEffects'],
        'notes': (r['notes'] ?? '').toString().trim().isEmpty ? null : r['notes'],
      }..removeWhere((key, value) => value == null);
    }).toList();
  }

  @visibleForTesting
  static String buildSummaryPrompt(List<Map<String, dynamic>> records) {
    final payload = anonymizeRecords(records);
    return '''
You are a factual clinical summarization assistant for CareTimeline.
The records below are patient-reported logs, not verified medical facts.

Strict rules:
- Never invent symptoms, medicines, dates, diagnoses, or patient history.
- If information is missing or too sparse, say so explicitly.
- Distinguish patient-reported observations from verified medical facts.
- Do not diagnose the patient.
- Do not independently recommend medication changes or new treatments.
- Treat this output as informational support for a doctor, not a substitute for professional judgement.
- Use only the records provided.

Patient-reported health timeline (JSON):
${const JsonEncoder.withIndent('  ').convert(payload)}

Write a concise, readable summary with exactly these section headings:
Overview:
Symptom patterns:
Medication observations:
Points for the doctor:

Keep the language factual. If a section has no supporting records, state that the available information is insufficient.
''';
  }

  @visibleForTesting
  static String? extractGeneratedText(dynamic decoded) {
    if (decoded is! Map) return null;
    final candidates = decoded['candidates'];
    if (candidates is! List || candidates.isEmpty) return null;

    final first = candidates.first;
    if (first is! Map) return null;
    final content = first['content'];
    if (content is! Map) return null;
    final parts = content['parts'];
    if (parts is! List || parts.isEmpty) return null;

    final texts = <String>[];
    for (final part in parts) {
      if (part is! Map) continue;
      if (part['thought'] == true) continue;
      final text = part['text'];
      if (text is String && text.trim().isNotEmpty) {
        texts.add(text.trim());
      }
    }
    if (texts.isEmpty) return null;
    return texts.join('\n\n');
  }

  @visibleForTesting
  static AiSummaryException classifyHttpError({
    required int statusCode,
    required String body,
    required String model,
  }) {
    final sanitized = _sanitizeForLog(body);
    final lower = sanitized.toLowerCase();

    if (statusCode == 400 || statusCode == 401 || statusCode == 403) {
      if (lower.contains('api key') ||
          lower.contains('api_key') ||
          lower.contains('unauthenticated') ||
          lower.contains('permission') ||
          lower.contains('unauthorized')) {
        return AiSummaryException(
          category: AiFailureCategory.authentication,
          message: 'The AI service rejected the configured API key.',
          diagnostic: 'HTTP $statusCode model=$model',
        );
      }
      if (statusCode == 403 && (lower.contains('quota') || lower.contains('exceed'))) {
        return AiSummaryException(
          category: AiFailureCategory.quotaExceeded,
          message: 'Quota exceeded for this API key.',
          diagnostic: 'HTTP 403 model=$model',
        );
      }
    }

    if (statusCode == 429) {
      return AiSummaryException(
        category: AiFailureCategory.quotaExceeded,
        message: 'Rate limit or quota exceeded. Try again later.',
        diagnostic: 'HTTP 429 model=$model',
      );
    }

    if (statusCode == 404) {
      return AiSummaryException(
        category: AiFailureCategory.invalidResponse,
        message: 'Model "$model" is not available for this key.',
        diagnostic: 'HTTP 404 model=$model',
      );
    }

    return AiSummaryException(
      category: AiFailureCategory.unknown,
      message: 'AI service returned HTTP $statusCode while generating summary.',
      diagnostic: 'HTTP $statusCode model=$model',
    );
  }

  static String _sanitizeForLog(String raw) {
    var text = raw.replaceAll(RegExp(r'gsk_[0-9A-Za-z\-_]{10,}'), '[REDACTED_KEY]');
    text = text.replaceAll(RegExp(r'AIza[0-9A-Za-z\-_]{10,}'), '[REDACTED_KEY]');
    text = text.replaceAll(RegExp(r'key=[^&\s"]+'), 'key=[REDACTED]');
    return text;
  }

  // -- Groq API Call -----------------------------------------------------------

  Future<LlmSummaryResult> _callGroqSummary({
    required String apiKey,
    required List<Map<String, dynamic>> records,
  }) async {
    final prompt = buildSummaryPrompt(records);
    final url = Uri.parse(AppConfig.groqBaseUrl);

    for (final model in AppConfig.groqModels) {
      try {
        final requestBody = jsonEncode({
          'model': model,
          'messages': [
            {
              'role': 'system',
              'content': 'You are CareTimeline AI, a factual clinical health summarization assistant.'
            },
            {'role': 'user', 'content': prompt},
          ],
          'temperature': 0.2,
          'max_tokens': 1000,
        });

        final response = await _client
            .post(
              url,
              headers: {
                'Authorization': 'Bearer $apiKey',
                'Content-Type': 'application/json',
              },
              body: requestBody,
            )
            .timeout(_requestTimeout);

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final choices = data['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final text = choices[0]['message']?['content'] as String?;
            if (text != null && text.trim().isNotEmpty) {
              return LlmSummaryResult(
                text: _formatLlmSummary(text.trim(), model),
                model: model,
              );
            }
          }
        } else {
          throw classifyHttpError(
            statusCode: response.statusCode,
            body: response.body,
            model: model,
          );
        }
      } catch (e) {
        if (e is AiSummaryException) rethrow;
      }
    }

    throw const AiSummaryException(
      category: AiFailureCategory.network,
      message: 'Groq LLM service failed to generate summary.',
    );
  }

  static String _formatLlmSummary(String text, String model) {
    return '=== CARETIMELINE LLM-GENERATED SUMMARY ===\n'
        'Source: AI Model ($model)\n'
        'Note: Patient-reported records were processed by CareTimeline AI.\n'
        '----------------------------------------------------\n'
        '$text\n'
        '----------------------------------------------------\n'
        'Disclaimer: Informational support for a doctor. Not a diagnosis or a substitute for professional judgement.';
  }

  // -- Core summary generator --------------------------------------------------

  Future<LlmSummaryResult> generateSummary({
    required List<Map<String, dynamic>> records,
  }) async {
    if (records.isEmpty) {
      throw const AiSummaryException(
        category: AiFailureCategory.emptyRecords,
        message: 'No health records are available to summarize.',
      );
    }

    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw const AiSummaryException(
        category: AiFailureCategory.missingConfiguration,
        message: 'No AI key is configured.',
      );
    }

    if (apiKey.startsWith('gsk_')) {
      return await _callGroqSummary(apiKey: apiKey, records: records);
    }

    final prompt = buildSummaryPrompt(records);
    final requestBody = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.2,
        'maxOutputTokens': 1200,
      }
    });

    for (final model in AppConfig.geminiModels) {
      final url = Uri.parse(AppConfig.geminiEndpointWithKey(apiKey, model: model));

      try {
        final response = await _client
            .post(
              url,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': apiKey,
              },
              body: requestBody,
            )
            .timeout(_requestTimeout);

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          final text = extractGeneratedText(decoded);
          if (text != null && text.trim().isNotEmpty) {
            return LlmSummaryResult(
              text: _formatLlmSummary(text.trim(), model),
              model: model,
            );
          }
          throw const AiSummaryException(
            category: AiFailureCategory.invalidResponse,
            message: 'Gemini returned an empty or unreadable summary.',
          );
        }

        final classified = classifyHttpError(
          statusCode: response.statusCode,
          body: response.body,
          model: model,
        );
        if (response.statusCode == 404) continue;
        throw classified;
      } on AiSummaryException {
        rethrow;
      } on TimeoutException {
        throw const AiSummaryException(
          category: AiFailureCategory.timeout,
          message: 'The AI request timed out.',
        );
      } on SocketException catch (e) {
        throw AiSummaryException(
          category: AiFailureCategory.network,
          message: 'Could not reach AI service. Check internet connection.',
          diagnostic: e.osError?.message ?? e.message,
        );
      } on http.ClientException catch (e) {
        throw AiSummaryException(
          category: AiFailureCategory.network,
          message: 'Could not reach AI service. Check internet connection.',
          diagnostic: e.message,
        );
      } catch (e) {
        if (e is AiSummaryException) rethrow;
      }
    }

    throw const AiSummaryException(
      category: AiFailureCategory.unknown,
      message: 'Failed to generate LLM summary.',
    );
  }

  /// Tries LLM only.
  Future<(String, bool)> generateSummaryWithFallback({
    required List<Map<String, dynamic>> records,
  }) async {
    final result = await generateSummary(records: records);
    return (result.text, true);
  }

  // -- Interactive AI Health Assistant -----------------------------------------

  Future<String> askAiAssistant({
    required List<Map<String, dynamic>> records,
    required String question,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw const AiSummaryException(
        category: AiFailureCategory.missingConfiguration,
        message: 'No AI key is configured for the assistant.',
      );
    }

    final prompt = '''
You are CareTimeline AI, a factual clinical health-timeline assistant.
Answer using only the patient-reported records below.
Do not diagnose or recommend medication changes.
If the records are insufficient, say so.

User Question: "$question"

Health Records:
${const JsonEncoder.withIndent('  ').convert(anonymizeRecords(records))}
''';

    if (apiKey.startsWith('gsk_')) {
      final url = Uri.parse(AppConfig.groqBaseUrl);
      for (final model in AppConfig.groqModels) {
        try {
          final requestBody = jsonEncode({
            'model': model,
            'messages': [
              {
                'role': 'system',
                'content': 'You are CareTimeline AI, an intelligent clinical health assistant.'
              },
              {'role': 'user', 'content': prompt},
            ],
            'temperature': 0.3,
            'max_tokens': 700,
          });

          final response = await _client
              .post(
                url,
                headers: {
                  'Authorization': 'Bearer $apiKey',
                  'Content-Type': 'application/json',
                },
                body: requestBody,
              )
              .timeout(_requestTimeout);

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            final choices = data['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final text = choices[0]['message']?['content'] as String?;
              if (text != null && text.trim().isNotEmpty) {
                return text.trim();
              }
            }
          }
        } catch (_) {}
      }
    }

    final requestBody = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.3,
        'maxOutputTokens': 700,
      }
    });

    for (final model in AppConfig.geminiModels) {
      final url = Uri.parse(AppConfig.geminiEndpointWithKey(apiKey, model: model));
      try {
        final response = await _client
            .post(
              url,
              headers: {
                'Content-Type': 'application/json',
                'x-goog-api-key': apiKey,
              },
              body: requestBody,
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode == 200) {
          final decoded = jsonDecode(response.body);
          final text = extractGeneratedText(decoded);
          if (text != null && text.trim().isNotEmpty) {
            return text.trim();
          }
        }
      } catch (_) {}
    }

    throw const AiSummaryException(
      category: AiFailureCategory.unknown,
      message: 'The AI assistant could not complete the request.',
    );
  }
}
