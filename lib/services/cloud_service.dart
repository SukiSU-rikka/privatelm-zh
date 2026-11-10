import 'dart:async';
import 'dart:convert';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import 'hive_service.dart';
import 'app_log_service.dart';

/// Cloud API service supporting native and OpenAI-compatible providers.
class CloudService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  String get _provider =>
      _hive.getSetting(AppConstants.keyCloudProvider, defaultValue: 'openrouter') ??
      'openrouter';

  String get _apiKey {
    switch (_provider) {
      case 'anthropic':
        return _hive.getSetting(AppConstants.keyAnthropicKey) ?? '';
      case 'google':
        return _hive.getSetting(AppConstants.keyGoogleKey) ?? '';
      case 'kimi':
        return _hive.getSetting(AppConstants.keyKimiKey) ?? '';
      case 'stability':
        return _hive.getSetting(AppConstants.keyStabilityKey) ?? '';
      case 'nvidia':
        return _hive.getSetting(AppConstants.keyNvidiaKey) ?? '';
      case 'openrouter':
        return _hive.getSetting(AppConstants.keyOpenRouterKey) ?? '';
      case 'deepseek':
        return _hive.getSetting(AppConstants.keyDeepSeekKey) ?? '';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudKey) ?? '';
      default:
        return _hive.getSetting(AppConstants.keyOpenaiKey) ?? '';
    }
  }

  String get _model {
    switch (_provider) {
      case 'anthropic':
        return _hive.getSetting(AppConstants.keyAnthropicModel) ??
            'claude-sonnet-4-6';
      case 'google':
        return _hive.getSetting(AppConstants.keyGoogleModel) ??
            'gemini-2.5-flash';
      case 'kimi':
        return _hive.getSetting(AppConstants.keyKimiModel) ?? 'kimi-k2.6';
      case 'stability':
        return _hive.getSetting(AppConstants.keyStabilityModel) ??
            'sd3.5-flash';
      case 'nvidia':
        return _hive.getSetting(AppConstants.keyNvidiaModel) ??
            'meta/llama-3.1-8b-instruct';
      case 'openrouter':
        return _hive.getSetting(AppConstants.keyOpenRouterModel) ??
            'openai/gpt-4o-mini';
      case 'deepseek':
        return _hive.getSetting(AppConstants.keyDeepSeekModel) ??
            'deepseek-v4-flash';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudModel) ?? '';
      default:
        return _hive.getSetting(AppConstants.keyOpenaiModel) ?? 'gpt-5.2';
    }
  }

  bool get isConfigured {
    if (_provider == 'custom') {
      final baseUrl =
          _hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '';
      return _apiKey.isNotEmpty && _model.isNotEmpty && baseUrl.isNotEmpty;
    }
    return _apiKey.isNotEmpty;
  }

  http.Client? _activeStreamClient;

  // Without timeouts a stalled connection (captive Wi-Fi, a hung custom
  // endpoint) leaves the chat loading forever.
  static const _connectTimeout = Duration(seconds: 30);
  static const _responseTimeout = Duration(seconds: 120);
  /// Max gap between streamed chunks. Not const so tests can shorten it.
  static Duration streamIdleTimeout = const Duration(seconds: 60);

  Future<http.Response> _post(Uri url,
          {Map<String, String>? headers, Object? body}) =>
      http.post(url, headers: headers, body: body).timeout(_responseTimeout);

  /// Aborts the streaming response in progress, if any. Closing the client
  /// drops the connection, so the provider stops generating (and billing).
  void cancel() {
    final client = _activeStreamClient;
    _activeStreamClient = null;
    client?.close();
  }

  /// Send a message to the cloud API. Returns the response text.
  /// [messages] is a list of {role, content} maps forming the conversation.
  /// [imageBase64] is optional for multimodal requests.
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
    void Function(String token)? onToken,
  }) async {
    if (!isConfigured) {
      return '错误：尚未为 $_provider 配置 API Key。请前往设置。';
    }

    try {
      if (onToken != null && _supportsStreaming) {
        return await _streamOpenAICompatible(
          endpoint: _openAICompatibleEndpoint,
          providerLabel: _providerLabel,
          messages: messages,
          imageBase64: imageBase64,
          temperature: temperature,
          maxTokens: maxTokens,
          extraHeaders: _openAICompatibleExtraHeaders,
          onToken: onToken,
        );
      }

      switch (_provider) {
        case 'anthropic':
          return await _sendAnthropic(
              messages, imageBase64, temperature, maxTokens);
        case 'google':
          return await _sendGoogle(
              messages, imageBase64, temperature, maxTokens);
        case 'kimi':
          return await _sendKimi(messages, imageBase64, temperature, maxTokens);
        case 'stability':
          return await _sendStability(messages);
        case 'nvidia':
          return await _sendNvidia(
              messages, imageBase64, temperature, maxTokens);
        case 'openrouter':
          return await _sendOpenRouter(
              messages, imageBase64, temperature, maxTokens);
        case 'deepseek':
          return await _sendDeepSeek(
              messages, imageBase64, temperature, maxTokens);
        case 'custom':
          return await _sendCustomOpenAICompatible(
              messages, imageBase64, temperature, maxTokens);
        default:
          return await _sendOpenAI(
              messages, imageBase64, temperature, maxTokens);
      }
    } on TimeoutException {
      Get.find<AppLogService>().warning('云端 API 请求超时');
      return "错误：$_providerLabel 响应超时。请检查你的"
          '网络连接，然后重试。';
    } catch (e) {
      Get.find<AppLogService>().error('云端 API 请求失败', details: e);
      return '错误：云端 API 请求失败 — $e';
    }
  }

  bool get _supportsStreaming =>
      _provider == 'openai' ||
      _provider == 'nvidia' ||
      _provider == 'openrouter' ||
      _provider == 'deepseek' ||
      _provider == 'custom' ||
      _provider == 'kimi';

  String get _openAICompatibleEndpoint {
    switch (_provider) {
      case 'nvidia':
        return '${AppConstants.nvidiaEndpoint}/chat/completions';
      case 'openrouter':
        return '${AppConstants.openRouterEndpoint}/chat/completions';
      case 'deepseek':
        return '${AppConstants.deepSeekEndpoint}/chat/completions';
      case 'custom':
        final baseUrl =
            (_hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '')
                .toString()
                .replaceAll(RegExp(r'/+$'), '');
        return '$baseUrl/chat/completions';
      case 'kimi':
        return AppConstants.kimiEndpoint;
      default:
        return AppConstants.openaiEndpoint;
    }
  }

  String get _providerLabel {
    switch (_provider) {
      case 'nvidia':
        return 'NVIDIA NIM';
      case 'openrouter':
        return 'OpenRouter';
      case 'deepseek':
        return 'DeepSeek';
      case 'custom':
        return _hive.getSetting(AppConstants.keyCustomCloudName) ??
            '自定义 API';
      case 'kimi':
        return 'Kimi';
      default:
        return 'OpenAI';
    }
  }

  Map<String, String> get _openAICompatibleExtraHeaders {
    if (_provider == 'openrouter') {
      return const {
        'HTTP-Referer': 'https://ai-chat.local',
        'X-Title': 'AI Chat',
      };
    }
    return const {};
  }

  // ─── OpenAI ─────────────────────────────────────

  Future<String> _sendOpenAI(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    final response = await _post(
      Uri.parse(AppConstants.openaiEndpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return '错误：OpenAI 返回 ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  // ─── Anthropic ──────────────────────────────────

  Future<String> _sendAnthropic(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    // Extract system message
    String? systemMsg;
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'system') {
        systemMsg = msg['content'];
        continue;
      }

      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/jpeg',
                'data': imageBase64,
              }
            },
            {'type': 'text', 'text': msg['content']},
          ],
        });
      } else {
        apiMessages.add({
          'role': msg['role'],
          'content': msg['content'],
        });
      }
    }

    final body = <String, dynamic>{
      'model': _model,
      'messages': apiMessages,
      'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      'temperature': temperature ?? AppConstants.defaultTemperature,
    };
    if (systemMsg != null) body['system'] = systemMsg;

    final response = await _post(
      Uri.parse(AppConstants.anthropicEndpoint),
      headers: {
        'x-api-key': _apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      return '错误：Anthropic 返回 ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    final content = data['content'] as List;
    return content.isNotEmpty ? content[0]['text'] ?? '' : '';
  }

  // ─── Google Gemini ──────────────────────────────

  Future<String> _sendGoogle(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final parts = <Map<String, dynamic>>[];

    // Combine all messages into parts
    for (final msg in messages) {
      parts.add({'text': '${msg['role']}: ${msg['content']}'});
    }

    // Add image if present
    if (imageBase64 != null) {
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': imageBase64,
        }
      });
    }

    // Key goes in a header, not the URL, so it can't leak via exception
    // messages (http's ClientException includes the full URI).
    final url = '${AppConstants.googleEndpoint}/$_model:generateContent';

    final response = await _post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
        'x-goog-api-key': _apiKey,
      },
      body: jsonEncode({
        'contents': [
          {'parts': parts}
        ],
        'generationConfig': {
          'temperature': temperature ?? AppConstants.defaultTemperature,
          'maxOutputTokens': maxTokens ?? AppConstants.defaultMaxTokens,
        },
      }),
    );

    if (response.statusCode != 200) {
      return '错误：Google 返回 ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    final candidates = data['candidates'] as List?;
    if (candidates != null && candidates.isNotEmpty) {
      final contentParts = candidates[0]['content']['parts'] as List;
      return contentParts.map((p) => p['text'] ?? '').join('');
    }
    return '';
  }

  // ─── Kimi (Moonshot AI — OpenAI-compatible) ─────

  Future<String> _sendKimi(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      apiMessages.add({'role': msg['role'], 'content': msg['content']});
    }

    final response = await _post(
      Uri.parse(AppConstants.kimiEndpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return '错误：Kimi 返回 ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  Future<String> _sendNvidia(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    final response = await _post(
      Uri.parse('${AppConstants.nvidiaEndpoint}/chat/completions'),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return '错误：NVIDIA NIM 返回 ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  Future<String> _sendOpenRouter(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    return _sendOpenAICompatible(
      endpoint: '${AppConstants.openRouterEndpoint}/chat/completions',
      providerLabel: 'OpenRouter',
      messages: messages,
      imageBase64: imageBase64,
      temperature: temperature,
      maxTokens: maxTokens,
      extraHeaders: const {
        'HTTP-Referer': 'https://ai-chat.local',
        'X-Title': 'AI Chat',
      },
    );
  }

  Future<String> _sendDeepSeek(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    return _sendOpenAICompatible(
      endpoint: '${AppConstants.deepSeekEndpoint}/chat/completions',
      providerLabel: 'DeepSeek',
      messages: messages,
      imageBase64: imageBase64,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  Future<String> _sendCustomOpenAICompatible(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final baseUrl = (_hive.getSetting(AppConstants.keyCustomCloudBaseUrl) ?? '')
        .toString()
        .replaceAll(RegExp(r'/+$'), '');
    return _sendOpenAICompatible(
      endpoint: '$baseUrl/chat/completions',
      providerLabel:
          _hive.getSetting(AppConstants.keyCustomCloudName) ?? '自定义 API',
      messages: messages,
      imageBase64: imageBase64,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  Future<String> _sendOpenAICompatible({
    required String endpoint,
    required String providerLabel,
    required List<Map<String, String>> messages,
    required String? imageBase64,
    required double? temperature,
    required int? maxTokens,
    Map<String, String> extraHeaders = const {},
  }) async {
    final apiMessages = <Map<String, dynamic>>[];

    apiMessages.addAll(_buildOpenAICompatibleMessages(messages, imageBase64));

    final response = await _post(
      Uri.parse(endpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
        ...extraHeaders,
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return '错误：$providerLabel 返回 ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  Future<String> _streamOpenAICompatible({
    required String endpoint,
    required String providerLabel,
    required List<Map<String, String>> messages,
    required String? imageBase64,
    required double? temperature,
    required int? maxTokens,
    required void Function(String token) onToken,
    Map<String, String> extraHeaders = const {},
  }) async {
    final request = http.Request('POST', Uri.parse(endpoint));
    request.headers.addAll({
      'Authorization': 'Bearer $_apiKey',
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
      ...extraHeaders,
    });
    request.body = jsonEncode({
      'model': _model,
      'messages': _buildOpenAICompatibleMessages(messages, imageBase64),
      'temperature': temperature ?? AppConstants.defaultTemperature,
      'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      'stream': true,
    });

    final client = http.Client();
    _activeStreamClient = client;
    try {
      final response = await client.send(request).timeout(_connectTimeout);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        return '错误：$providerLabel 返回 ${response.statusCode} — $body';
      }

      final buffer = StringBuffer();
      final lines = response.stream
          .timeout(streamIdleTimeout)
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      // Providers can fail after the 200 (rate limits, moderation, upstream
      // errors) by sending an error event, or just drop the connection. Track
      // both so they aren't shown as a normal, complete reply.
      var finished = false;
      String? streamError;

      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;

        final payload = trimmed.substring(5).trim();
        if (payload == '[DONE]') {
          finished = true;
          break;
        }

        Map? data;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map) data = decoded;
        } catch (_) {
          continue; // Malformed keep-alive chunk.
        }
        if (data == null) continue;

        final error = data['error'];
        if (error != null) {
          streamError = error is Map
              ? '${error['message'] ?? error['code'] ?? error}'
              : '$error';
          break;
        }

        final choices = data['choices'];
        final choice =
            choices is List && choices.isNotEmpty ? choices.first : null;
        if (choice is! Map) continue;
        if (choice['finish_reason'] != null) finished = true;
        final delta = choice['delta'];
        final token = delta is Map ? delta['content']?.toString() : null;
        if (token != null && token.isNotEmpty) {
          buffer.write(token);
          onToken(token);
        }
      }

      final text = buffer.toString();
      if (streamError != null) {
        return text.isEmpty
            ? '错误：$providerLabel 返回了错误 — $streamError'
            : '$text\n\n⚠️ $providerLabel stopped with an error: $streamError';
      }
      if (text.isEmpty) {
        return 'ERROR: $providerLabel returned an empty response.';
      }
      if (!finished) {
        return '$text\n\n⚠️ The response was cut off before it finished.';
      }
      return text;
    } finally {
      if (identical(_activeStreamClient, client)) _activeStreamClient = null;
      client.close();
    }
  }

  List<Map<String, dynamic>> _buildOpenAICompatibleMessages(
    List<Map<String, String>> messages,
    String? imageBase64,
  ) {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    return apiMessages;
  }

  // ─── Stability AI (Image Generation) ────────────

  Future<String> _sendStability(
    List<Map<String, String>> messages,
  ) async {
    // Extract the latest user prompt for the image generation
    final userMessages = messages.where((m) => m['role'] == 'user').toList();
    if (userMessages.isEmpty) {
      return '错误：未找到用于生成图片的用户提示词。';
    }

    final prompt = userMessages.last['content'] ?? '';

    // Create a multipart request since stability AI v2beta uses multipart/form-data
    var request = http.MultipartRequest(
        'POST', Uri.parse(AppConstants.stabilityEndpoint));
    request.headers.addAll({
      'Authorization': 'Bearer $_apiKey',
      'Accept': 'application/json',
    });

    request.fields['prompt'] = prompt;
    request.fields['model'] = _model;
    request.fields['output_format'] = 'jpeg';

    final response = await request.send().timeout(_responseTimeout);
    final responseBody =
        await response.stream.bytesToString().timeout(_responseTimeout);

    if (response.statusCode != 200) {
      return '错误：Stability AI 返回 ${response.statusCode} — $responseBody';
    }

    final data = jsonDecode(responseBody);
    final base64Image = data['image'];
    if (base64Image != null) {
      return '[IMAGE_BASE64]$base64Image';
    }

    return '错误：未生成图片。';
  }
}
