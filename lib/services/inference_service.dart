import 'dart:async';
import 'package:get/get.dart';
import 'hive_service.dart';
import '../core/constants.dart';
import 'device_info_service.dart';
import 'gguf_metadata.dart';
import 'app_log_service.dart';
import 'cluster_service.dart';
import 'stop_sequence_filter.dart';

// Conditionally import llama_flutter_android — only on Android
import 'inference_android.dart' if (dart.library.html) 'inference_stub.dart'
    as platform;

/// Cross-platform inference service.
/// - Android / iOS: uses llama_flutter_android for local GGUF models
/// - Android: uses flutter_litert_lm for LiteRT-LM models
/// - Web: cloud-only mode (local inference coming soon)
class InferenceService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  // ── Observable State ──
  final isModelLoaded = false.obs;
  final isGenerating = false.obs;
  final isLoadingModel = false.obs;
  final isVisionLoaded = false.obs;
  final loadingModelName = ''.obs;
  final loadedModelName = ''.obs;
  final tokenCount = 0.obs;
  final tokensPerSecond = 0.0.obs;
  final contextTokensUsed = 0.obs;
  final contextTokensTotal = 0.obs;
  final modelLoadProgress = 0.0.obs;
  final generationSource = ''.obs;
  final streamingText = ''.obs;
  final gpuName = ''.obs;
  final gpuLayersUsed = 0.obs;
  int _generationId = 0;

  /// Incremented whenever a generation is stopped early (by the user, a
  /// newer generation, or a disconnecting server client). Callers compare it
  /// before/after generate() to detect that their result was cut short.
  int get stopCount => _stopCount;
  int _stopCount = 0;
  final isGpuAccelerated = false.obs;
  final loadedModelRuntime = ''.obs;
  final loadedBackend = ''.obs;

  /// Whether the current platform supports local inference.
  bool get supportsLocalInference => platform.supportsLocalInference;

  // Platform-specific engine
  platform.InferenceEngine? _engine;
  String _sessionNativeRuntime = '';

  String get sessionNativeRuntime => _sessionNativeRuntime;

  /// The loaded GGUF model has a working vision projector (images allowed).
  bool get ggufVisionLoaded => _engine?.ggufVisionLoaded ?? false;

  Future<String> loadModel(
    String modelPath, {
    String? modelName,
    String? modelRuntime,
    bool enableLiteRtVision = false,
    String? mmprojPath,
  }) async {
    if (!supportsLocalInference) {
      return '错误：此平台不支持本地推理。请使用云端模式。';
    }
    if (isLoadingModel.value) return '错误：模型正在加载中。';

    if (platform.isRunning32Bit) {
      final lower = modelPath.toLowerCase();
      if (_runtimeFor(modelPath, modelRuntime) == 'litert') {
        return '错误：LiteRT 模型需要 64 位 Android。本手机运行的是'
            '32 位 Android；请改用较小的 GGUF 模型（1.5 GB 以下）。';
      }
      // A 32-bit process can't map a model this large next to everything else.
      if (lower.endsWith('.gguf') &&
          await _fileBytes(modelPath) > 1536 * 1024 * 1024) {
        return 'ERROR: This model is too large for 32-bit Android. Choose a '
            'GGUF model under 1.5 GB (for example a 1B Q4 model).';
      }
    }

    if (modelPath.toLowerCase().endsWith('.safetensors')) {
      return 'ERROR: Cannot load image generation models (.safetensors) into the local text engine. Native local image generation requires the upcoming stable-diffusion engine update. Use Cloud Stability AI for now.';
    }

    try {
      final runtime = _runtimeFor(modelPath, modelRuntime);
      final isLiteRt = runtime == 'litert';
      final liteRtMode = _hive.getSetting<String>(
            AppConstants.keyLiteRtPerformanceMode,
            defaultValue: AppConstants.defaultLiteRtPerformanceMode,
          ) ??
          AppConstants.defaultLiteRtPerformanceMode;
      // The Performance setting alone decides: CPU safe never uses the GPU;
      // Auto fast and GPU fast always try it. A crash doesn't pause the GPU
      // for later loads (Auto fast still falls back to CPU if a GPU load
      // itself fails).
      final cpuOnly = liteRtMode == 'cpu_safe';
      final forceLiteRtCpu = isLiteRt && cpuOnly;
      final shouldTryLiteRtGpu = isLiteRt && !cpuOnly;
      // GGUF GPU circuit breaker (the mechanism AppConstants
      // .keyGgufGpuPending always described but nothing implemented): the
      // flag is armed after a GPU load and disarmed by the first successful
      // reply. Still armed at this point means the last GPU session ended
      // before producing one — the process most likely died on the GPU
      // path. Force CPU for this load instead of risking a crash loop.
      final ggufGpuCrashedLastTime = !isLiteRt &&
          (_hive.getSetting<bool>(AppConstants.keyGgufGpuPending,
                  defaultValue: false) ??
              false);
      if (ggufGpuCrashedLastTime) {
        print('[Inference] GGUF GPU flag still armed from the last session '
            '— forcing CPU for this load');
        Get.find<AppLogService>().warning(
          'GGUF GPU circuit breaker tripped',
          details: 'previous GPU session ended before its first reply',
        );
      }
      final allowGgufGpu = !isLiteRt && !cpuOnly && !ggufGpuCrashedLastTime;
      // Clear crash state left by older versions of the app.
      await _hive.setSetting(AppConstants.keyLiteRtGpuCrashDetected, false);
      await _hive.setSetting(AppConstants.keyLiteRtGpuLoadPending, false);
      await _hive.setSetting(AppConstants.keyGgufGpuPending, false);

      await unloadModel();
      isLoadingModel.value = true;
      loadingModelName.value = modelName ?? modelPath.split('/').last;
      modelLoadProgress.value = 0.0;

      _engine = platform.InferenceEngine();

      final contextSize = _hive.getSetting<int>(
            AppConstants.keyContextSize,
            defaultValue: AppConstants.defaultContextSize,
          ) ??
          AppConstants.defaultContextSize;

      final finalContextSize =
          isLiteRt ? contextSize.clamp(512, 4096) : contextSize;

      // Stability: enforce the memory estimate here, in the one load path
      // every caller goes through. The model page's warning sheet is
      // advisory — tapping "continue" used to load at the raw setting, and
      // a long chat then grew the KV cache until Android killed the app.
      // Clamp the context to what actually fits, or refuse cleanly.
      var loadContextSize = finalContextSize;
      if (!isLiteRt && modelPath.toLowerCase().endsWith('.gguf')) {
        final clamped = await _clampGgufContext(modelPath, finalContextSize);
        if (clamped == null) {
          isModelLoaded.value = false;
          isLoadingModel.value = false;
          loadingModelName.value = '';
          modelLoadProgress.value = 0.0;
          Get.find<AppLogService>().error(
            'Local model load refused: does not fit in available RAM',
            details: 'model=$modelPath, requestedCtx=$finalContextSize',
          );
          return '错误：可用内存不足，这个模型即使使用最小上下文也装不下。'
              '请关闭其他应用后重试，或换一个更小的模型。';
        }
        loadContextSize = clamped;
      }

      final lastLoadedContext =
          _hive.getSetting<int>('last_loaded_context_size') ?? 0;
      final contextChanged = isLiteRt && lastLoadedContext != finalContextSize;

      final deviceTier = _getDeviceTier();
      final isTensorSoC = _getIsTensorSoC();

      // Phone cluster: GGUF layers spread across worker phones. This phone
      // then runs its share on the CPU.
      var clusterWorkers = 0;
      if (!isLiteRt && Get.isRegistered<ClusterService>()) {
        clusterWorkers = await Get.find<ClusterService>()
            .applyForNextLoad(modelPath, modelName: modelName);
      }

      final requestedModelName = modelName ?? modelPath.split('/').last;
      var activeModelName = requestedModelName;
      var result = await _loadModelOnEngine(
        modelPath: modelPath,
        modelRuntime: modelRuntime,
        contextSize: loadContextSize,
        deviceTier: deviceTier,
        isTensorSoC: isTensorSoC,
        liteRtPerformanceMode: liteRtMode,
        forceLiteRtCpu: forceLiteRtCpu,
        clearLiteRtCache: contextChanged,
        tryLiteRtGpu: shouldTryLiteRtGpu,
        enableLiteRtVision: enableLiteRtVision,
        allowGgufGpu: allowGgufGpu && clusterWorkers == 0,
        mmprojPath: mmprojPath,
      );

      if (!result.success) {
        isModelLoaded.value = false;
        isLoadingModel.value = false;
        loadingModelName.value = '';
        modelLoadProgress.value = 0.0;
        loadedModelName.value = '';
        loadedModelRuntime.value = '';
        loadedBackend.value = '';
        gpuName.value = '';
        gpuLayersUsed.value = 0;
        isGpuAccelerated.value = false;
        Get.find<AppLogService>().error(
          'Local model load failed',
          details:
              'model=$requestedModelName, runtime=$runtime, backend=${result.backend}, message=${result.message}',
        );
        return result.message;
      }

      isModelLoaded.value = result.success;
      isLoadingModel.value = false;
      loadingModelName.value = '';
      modelLoadProgress.value = 1.0;
      loadedModelName.value = activeModelName;
      loadedModelRuntime.value = result.runtime;
      if (result.runtime == 'llama' || result.runtime == 'litert') {
        _sessionNativeRuntime = result.runtime;
      }
      loadedBackend.value = result.backend;
      gpuName.value = result.gpuName;
      gpuLayersUsed.value = result.gpuLayers;
      isGpuAccelerated.value = result.backend == 'gpu' || result.gpuLayers > 0;
      if (!isLiteRt && result.backend == 'gpu') {
        // Arm the GPU circuit breaker; generate() disarms it once a reply
        // completes, proving the GPU path survives real work.
        await _hive.setSetting(AppConstants.keyGgufGpuPending, true);
      }
      contextTokensUsed.value = 0;
      contextTokensTotal.value = loadContextSize;

      await _hive.setSetting(AppConstants.keyLocalModelPath, modelPath);
      await _hive.setSetting(
          AppConstants.keyLocalModelName, loadedModelName.value);
      await _hive.setSetting(
          AppConstants.keyLocalModelRuntime, loadedModelRuntime.value);
      await _hive.setSetting(
          AppConstants.keyLocalModelBackend, loadedBackend.value);

      if (isLiteRt) {
        await _hive.setSetting('last_loaded_context_size', finalContextSize);
      }

      if (clusterWorkers > 0) {
        final cluster = Get.find<ClusterService>();
        await cluster.refreshSplit(modelPath);
        return 'Model loaded across ${cluster.splitSummary ?? '${clusterWorkers + 1} phones'}.';
      }
      return result.message;
    } catch (e) {
      isModelLoaded.value = false;
      isLoadingModel.value = false;
      loadingModelName.value = '';
      modelLoadProgress.value = 0.0;
      loadedBackend.value = '';
      Get.find<AppLogService>().error('Failed to load local model', details: e);
      return 'ERROR: Failed to load model — $e';
    }
  }

  Future<void> unloadModel() async {
    final engine = _engine;
    _engine = null;
    if (Get.isRegistered<ClusterService>()) {
      Get.find<ClusterService>().clearSplit();
    }
    if (engine != null) {
      await stopGeneration();
      await engine.dispose();
    }
    isModelLoaded.value = false;
    isVisionLoaded.value = false;
    loadedModelName.value = '';
    loadingModelName.value = '';
    loadedModelRuntime.value = '';
    loadedBackend.value = '';
    gpuLayersUsed.value = 0;
    isGpuAccelerated.value = false;
    gpuName.value = '';
    contextTokensUsed.value = 0;
    contextTokensTotal.value = 0;
    _sessionNativeRuntime = '';
  }

  Future<String> generate({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    int? maxTokens,
    List<String> stopSequences = const [],
    void Function(String token)? onToken,
  }) async {
    if (!supportsLocalInference || _engine == null || !isModelLoaded.value) {
      return '错误：未加载模型。请前往「模型」页下载并加载一个。';
    }

    if (isGenerating.value) {
      // Wait for previous generation
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!isGenerating.value) break;
      }
      if (isGenerating.value) {
        await stopGeneration();
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    // Identifies this generation so a stopped one that finishes late can't
    // reset the state of the generation that replaced it.
    final generationId = ++_generationId;
    bool isCurrent() => generationId == _generationId;

    isGenerating.value = true;
    tokenCount.value = 0;
    tokensPerSecond.value = 0.0;
    generationSource.value = source;
    streamingText.value = '';

    final startTime = DateTime.now();
    DateTime? firstVisibleTokenAt;
    Timer? tokenFlushTimer;
    final tokenFlushBuffer = StringBuffer();

    void flushTokenBuffer() {
      if (tokenFlushBuffer.isEmpty) return;
      final text = tokenFlushBuffer.toString();
      tokenFlushBuffer.clear();
      onToken?.call(text);
    }

    final stopFilter = StopSequenceFilter(stopSequences);
    var stopSequenceHit = false;

    try {
      final temperature = _hive.getSetting<double>(
            AppConstants.keyTemperature,
            defaultValue: AppConstants.defaultTemperature,
          ) ??
          AppConstants.defaultTemperature;

      final settingMaxTokens = _hive.getSetting<int>(
            AppConstants.keyMaxTokens,
            defaultValue: AppConstants.defaultMaxTokens,
          ) ??
          AppConstants.defaultMaxTokens;
      final effectiveMaxTokens = (maxTokens != null && maxTokens > 0)
          ? (maxTokens < settingMaxTokens ? maxTokens : settingMaxTokens)
          : settingMaxTokens;

      final result = await _engine!.generate(
        prompt: prompt,
        conversationHistory: conversationHistory,
        systemPrompt: systemPrompt ?? AppConstants.systemPrompt,
        modelName: loadedModelName.value,
        maxTokens: effectiveMaxTokens,
        temperature: temperature,
        imagePath: imagePath,
        audioPath: audioPath,
        source: source,
        onToken: (rawToken) {
          if (!isCurrent()) return;
          var token = rawToken;
          if (stopFilter.isActive) {
            token = stopFilter.add(rawToken);
            if (stopFilter.stopped && !stopSequenceHit) {
              stopSequenceHit = true;
              // Halt the engine directly: this is a normal finish, not a
              // user/server interruption, so stopCount must not change.
              unawaited(
                  _engine?.stop().catchError((_) {}) ?? Future<void>.value());
            }
            if (token.isEmpty) return;
          }
          firstVisibleTokenAt ??= DateTime.now();
          tokenCount.value++;
          streamingText.value += token;
          final speedStart = firstVisibleTokenAt ?? startTime;
          final elapsedSeconds =
              DateTime.now().difference(speedStart).inMilliseconds / 1000.0;
          if (elapsedSeconds > 0) {
            tokensPerSecond.value = tokenCount.value / elapsedSeconds;
          }
          if (loadedModelRuntime.value == 'litert') {
            tokenFlushBuffer.write(token);
            tokenFlushTimer ??= Timer(const Duration(milliseconds: 60), () {
              tokenFlushTimer = null;
              flushTokenBuffer();
            });
          } else {
            onToken?.call(token);
          }
        },
      );
      tokenFlushTimer?.cancel();
      if (!isCurrent()) return result;
      if (stopFilter.isActive) {
        final tail = stopFilter.flush();
        if (tail.isNotEmpty) {
          streamingText.value += tail;
          tokenFlushBuffer.write(tail);
        }
      }
      flushTokenBuffer();
      final finalText = stopSequenceHit ? stopFilter.text : result;

      await refreshContextInfo();
      if (isCurrent() && tokenCount.value > 0) {
        // A completed reply proves an armed GPU load was healthy; disarm
        // the circuit breaker so the next load may use the GPU again.
        unawaited(_hive.setSetting(AppConstants.keyGgufGpuPending, false));
      }
      if (isCurrent()) {
        isGenerating.value = false;
        generationSource.value = '';
      }

      // Detect Tensor SoC + Gemma Q4_K_M corruption: model outputs only
      // special tokens and terminates immediately with empty result.
      if (result.trim().isEmpty &&
          tokenCount.value < 5 &&
          loadedModelName.value.toLowerCase().contains('gemma')) {
        final isTensor = _getIsTensorSoC();
        if (isTensor) {
          return '⚠️ This Gemma model is incompatible with your Pixel\'s Google Tensor chip. '
              'The Q4_K_M quantization format has a known bug on Tensor SoC that produces empty responses.\n\n'
              'Try one of these fixes:\n'
              '1. Download a Q4_0 or Q5_K_M version of the same model\n'
              '2. Use a different model (Qwen, Phi, or Llama-3)\n'
              '3. Switch to Cloud mode in Settings';
        }
      }

      return finalText;
    } catch (e) {
      tokenFlushTimer?.cancel();
      if (isCurrent()) {
        isGenerating.value = false;
        generationSource.value = '';
        streamingText.value = '';
        flushTokenBuffer();
      }
      Get.find<AppLogService>().error('Local generation failed', details: e);
      return 'ERROR: $e';
    }
  }

  Future<void> stopGeneration() async {
    _generationId++;
    _stopCount++;
    isGenerating.value = false;
    tokenCount.value = 0;
    generationSource.value = '';
    streamingText.value = '';
    final engine = _engine;
    if (engine != null) {
      unawaited(engine.stop().timeout(const Duration(seconds: 1)).catchError(
            (_) {},
          ));
    }
  }

  /// Reset the native conversation context. Call this whenever the user
  /// switches to a different chat session so old context doesn't leak.
  Future<void> resetConversation() async {
    final engine = _engine;
    if (engine != null) {
      await engine.resetConversation();
    }
  }

  Future<void> refreshContextInfo() async {
    if (!supportsLocalInference || _engine == null || !isModelLoaded.value) {
      return;
    }

    final info = await _engine!.getContextInfo();
    if (info == null) return;

    contextTokensUsed.value = info.tokensUsed;
    contextTokensTotal.value = info.contextSize;
  }

  String _getDeviceTier() {
    try {
      final device = Get.find<DeviceInfoService>();
      return device.deviceTier.value;
    } catch (_) {
      return 'mid';
    }
  }

  bool _getIsTensorSoC() {
    try {
      final device = Get.find<DeviceInfoService>();
      return device.isTensorSoC.value;
    } catch (_) {
      return false;
    }
  }

  /// Largest context ≤ [requested] whose estimated footprint (weights +
  /// KV cache + runtime overhead, from the GGUF header) fits in the memory
  /// currently available. Returns [requested] unchanged when no estimate is
  /// possible (unreadable header or unknown RAM), and null when even a
  /// 512-token context cannot fit — loading anyway would just get the
  /// process killed by Android mid-chat.
  Future<int?> _clampGgufContext(String modelPath, int requested) async {
    try {
      final gguf = await readGgufInfo(modelPath);
      if (gguf == null) return requested;
      final device = Get.find<DeviceInfoService>();
      await device.refreshMemoryInfo();
      var budgetBytes =
          (device.availableRamGB.value * 1024 * 1024 * 1024).round();
      if (budgetBytes <= 0) return requested;
      // The currently loaded model is unloaded first; count its file size
      // as available again (same convention as the model page's estimate).
      if (isModelLoaded.value) {
        final prevPath = _hive.getSetting<String>(AppConstants.keyLocalModelPath);
        if (prevPath != null && prevPath.isNotEmpty && prevPath != modelPath) {
          budgetBytes += await _fileBytes(prevPath);
        }
      }
      if (gguf.estimateBytes(requested) <= budgetBytes) return requested;
      final fit = gguf.maxContextFitting(budgetBytes);
      if (fit == null) {
        print('[Inference] GGUF does not fit: needs '
            '~${gguf.estimateBytes(512) ~/ (1024 * 1024)}MB even at 512 ctx, '
            'budget ${budgetBytes ~/ (1024 * 1024)}MB');
        return null;
      }
      print('[Inference] Clamping context $requested -> $fit so the model '
          'fits in available RAM (est. '
          '${gguf.estimateBytes(fit) ~/ (1024 * 1024)}MB of '
          '${budgetBytes ~/ (1024 * 1024)}MB)');
      Get.find<AppLogService>().info(
        'Context clamped for memory',
        details: 'model=$modelPath, requested=$requested, clamped=$fit',
      );
      return fit;
    } catch (_) {
      return requested;
    }
  }

  Future<platform.LoadResult> _loadModelOnEngine({
    required String modelPath,
    required String? modelRuntime,
    required int contextSize,
    required String deviceTier,
    bool isTensorSoC = false,
    required String liteRtPerformanceMode,
    required bool forceLiteRtCpu,
    required bool clearLiteRtCache,
    required bool tryLiteRtGpu,
    required bool enableLiteRtVision,
    bool allowGgufGpu = false,
    String? mmprojPath,
  }) async {
    // Auto fast: if a LiteRT GPU load fails, retry this load on the CPU.
    // Nothing is remembered — the next load tries the GPU again.
    final fallbackToCpu = tryLiteRtGpu && liteRtPerformanceMode == 'auto_fast';
    Future<platform.LoadResult> loadOnCpu() {
      modelLoadProgress.value = 0.0;
      return _engine!.loadModel(
        modelPath: modelPath,
        modelRuntime: modelRuntime,
        contextSize: contextSize,
        deviceTier: deviceTier,
        isTensorSoC: isTensorSoC,
        liteRtPerformanceMode: liteRtPerformanceMode,
        forceLiteRtCpu: true,
        clearLiteRtCache: true,
        enableLiteRtVision: enableLiteRtVision,
        onProgress: (p) => modelLoadProgress.value = _normalizeProgress(p),
      );
    }

    try {
      final result = await _engine!.loadModel(
        modelPath: modelPath,
        modelRuntime: modelRuntime,
        contextSize: contextSize,
        deviceTier: deviceTier,
        isTensorSoC: isTensorSoC,
        liteRtPerformanceMode: liteRtPerformanceMode,
        forceLiteRtCpu: forceLiteRtCpu,
        clearLiteRtCache: clearLiteRtCache,
        enableLiteRtVision: enableLiteRtVision,
        allowGgufGpu: allowGgufGpu,
        mmprojPath: mmprojPath,
        onProgress: (p) => modelLoadProgress.value = _normalizeProgress(p),
      );
      if (result.success || !fallbackToCpu) return result;
      return await loadOnCpu();
    } catch (e) {
      if (fallbackToCpu) {
        try {
          return await loadOnCpu();
        } catch (cpuError) {
          return platform.LoadResult(
            success: false,
            message: '错误：模型加载失败 - $cpuError',
          );
        }
      }
      return platform.LoadResult(
        success: false,
        message: '错误：模型加载失败 - $e',
      );
    }
  }

  Future<int> _fileBytes(String path) async {
    try {
      return await platform.fileLength(path);
    } catch (_) {
      return 0;
    }
  }

  double _normalizeProgress(double progress) {
    if (progress.isNaN || progress.isInfinite) return 0.0;
    final normalized = progress > 1 ? progress / 100 : progress;
    return normalized.clamp(0.0, 1.0).toDouble();
  }

  String _runtimeFor(String modelPath, String? modelRuntime) {
    final runtime = modelRuntime?.toLowerCase();
    if (runtime == 'litert' || runtime == 'llama') return runtime!;
    return modelPath.toLowerCase().endsWith('.litertlm') ? 'litert' : 'llama';
  }
}
