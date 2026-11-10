import 'dart:async';

class OpenAiServerService {
  bool get isRunning => false;
  String? get localUrl => null;

  Future<void> start({
    int port = 8080,
    String? apiKey,
    bool allowNetwork = false,
    void Function(String)? onLog,
  }) async {
    throw UnsupportedError('此平台不支持本地 API 服务器。');
  }

  void updateApiKey(String? apiKey) {}

  Future<void> stop() async {}
}
