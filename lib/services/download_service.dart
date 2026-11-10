import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import '../controllers/model_controller.dart';
import '../core/ui.dart';
import 'update_service.dart';

import 'download_native.dart' if (dart.library.html) 'download_web.dart'
    as platform_dl;

/// State for an individual download.
class DownloadProgress {
  final String filename;
  final RxDouble progress = 0.0.obs;
  final RxInt downloadedBytes = 0.obs;
  final RxInt totalBytes = 0.obs;
  final RxDouble bytesPerSecond = 0.0.obs;
  final RxBool isPaused = false.obs;

  /// Human-readable state from the downloader ("等待开始…",
  /// "已暂停：等待网络", ...); empty while simply downloading.
  final RxString status = ''.obs;
  DateTime startedAt = DateTime.now();

  DownloadProgress({required this.filename});

  Duration? get eta {
    final speed = bytesPerSecond.value;
    final total = totalBytes.value;
    if (speed <= 0 || total <= 0) return null;
    final remaining = total - downloadedBytes.value;
    if (remaining <= 0) return Duration.zero;
    return Duration(seconds: (remaining / speed).ceil());
  }
}

/// Service for downloading GGUF model files with progress tracking.
/// On web: downloads are not supported (models are too large for browser).
class DownloadService extends GetxService with WidgetsBindingObserver {
  /// Currently active downloads.
  final activeDownloads = <String, DownloadProgress>{}.obs;
  final _nativeDownloadIds = <String, int>{};
  // Kept so a stalled system download can be retried with our own downloader.
  final _nativeDownloadUrls = <String, String>{};

  bool get isDownloadingAny => activeDownloads.isNotEmpty;

  /// Whether the platform supports downloading models.
  bool get supportsDownload => !kIsWeb;

  Future<String> get modelsDir async => await platform_dl.getModelsDir();

  Future<String> modelPath(String filename) async {
    return '${await modelsDir}/$filename';
  }

  Future<bool> isModelDownloaded(String filename) async {
    if (kIsWeb) return false;
    return await platform_dl.isModelDownloaded(await modelPath(filename));
  }

  Future<List<String>> getDownloadedModels() async {
    if (kIsWeb) return [];
    return await platform_dl.getDownloadedModels(await modelsDir);
  }

  Future<int> getModelSize(String filename) async {
    if (kIsWeb) return 0;
    return await platform_dl.getModelSize(await modelPath(filename));
  }

  Future<int> getRemoteFileSize(String url, {String? authToken}) async {
    if (kIsWeb) return 0;
    return await platform_dl.getRemoteFileSize(url, authToken: authToken);
  }

  @override
  void onInit() {
    super.onInit();

    if (!kIsWeb && Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(this);

      // Initial reconciliation on startup
      reconcileActiveDownloads();

      // Permanent channel progress listener
      const MethodChannel('com.aichat.ai_chat/model_import')
          .setMethodCallHandler((call) async {
        if (call.method == 'importProgress') {
          final data = Map<String, dynamic>.from(call.arguments as Map);
          final filename = data['filename'] as String;
          final downloaded = (data['copiedBytes'] as num).toInt();
          final total = (data['totalBytes'] as num).toInt();
          final speed = (data['bytesPerSecond'] as num).toDouble();
          final status = data['status'] as String;

          // App update downloads are handled by UpdateService, not the
          // model download list.
          if (filename.startsWith('update:')) {
            if (Get.isRegistered<UpdateService>()) {
              Get.find<UpdateService>().onNativeProgress(
                  filename.substring(7), downloaded, total, status);
            }
            return;
          }

          var progress = activeDownloads[filename];
          if (progress == null &&
              (status == 'Downloading...' ||
                  status == '正在下载到手机…' ||
                  status == '等待开始…' ||
                  status.startsWith('Paused') ||
                  status.startsWith('导入中') ||
                  status.startsWith('Saving'))) {
            progress = DownloadProgress(filename: filename);
            activeDownloads[filename] = progress;
          }
          if (progress != null) {
            progress.downloadedBytes.value = downloaded;
            progress.totalBytes.value = total;
            progress.bytesPerSecond.value = speed;
            progress.status.value = status == 'Downloading...' ? '' : status;
            if (total > 0) {
              progress.progress.value = downloaded / total;
            }

            // Copy to the Downloads folder ("save:<name>") finished.
            if (status == '已保存到下载文件夹' || status == '保存失败') {
              activeDownloads.remove(filename);
              return;
            }

            if (status == '下载完成') {
              activeDownloads.remove(filename);
              _nativeDownloadIds.remove(filename);
              _nativeDownloadUrls.remove(filename);
              // Trigger reload
              try {
                Get.find<ModelController>().refreshDownloaded();
              } catch (_) {}
            } else if (status == '下载停滞') {
              // The system downloader never started (common on some OEM
              // ROMs); retry with the app's own resumable downloader.
              _nativeDownloadIds.remove(filename);
              final url = _nativeDownloadUrls.remove(filename);
              if (url == null) {
                activeDownloads.remove(filename);
              } else {
                unawaited(_directDownloadAfterStall(url, filename, progress));
              }
            } else if (status.startsWith('下载失败') ||
                status == '下载已取消') {
              activeDownloads.remove(filename);
              _nativeDownloadIds.remove(filename);
              _nativeDownloadUrls.remove(filename);
              if (status.startsWith('下载失败')) {
                _notifyFailure(filename, status);
              }
            }
          }

          // Also update ModelController import state in real-time if it is currently importing
          try {
            final modelCtrl = Get.find<ModelController>();
            if (modelCtrl.isImporting.value) {
              final isPhoneDownload =
                  modelCtrl.importStatus.value.contains('phone') ||
                      modelCtrl.importStatus.value.contains('Starting');

              modelCtrl.importFileName.value = filename;
              modelCtrl.importStatus.value = status;
              modelCtrl.importCopiedBytes.value = downloaded;
              modelCtrl.importTotalBytes.value = total;
              modelCtrl.importBytesPerSecond.value = speed;

              if (status == '下载完成' ||
                  status.startsWith('下载失败') ||
                  status == '下载已取消') {
                if (status == '下载完成' && isPhoneDownload) {
                  showToast(
                    '已保存到下载文件夹',
                    '导入此文件以在应用中使用。',
                    tone: ToastTone.success,
                    duration: const Duration(seconds: 5),
                  );
                }
                Future.delayed(const Duration(seconds: 3), () {
                  if (modelCtrl.importStatus.value == status) {
                    modelCtrl.isImporting.value = false;
                    modelCtrl.importFileName.value = '';
                    modelCtrl.importStatus.value = '';
                  }
                });
              }
            }
          } catch (_) {}
        }
        return null;
      });
    }
  }

  @override
  void onClose() {
    if (!kIsWeb && Platform.isAndroid) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      reconcileActiveDownloads();
    }
  }

  Future<void> reconcileActiveDownloads() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final list = await platform_dl.getActiveNativeDownloads();
      final recoveredFilenames = <String>{};
      for (final item in list) {
        final id = item['downloadId'] as int;
        final filename = item['filename'] as String;
        final downloaded = item['downloaded'] as int;
        final total = item['total'] as int;
        final status = item['status'] as String;
        recoveredFilenames.add(filename);

        _nativeDownloadIds[filename] = id;

        final progress =
            activeDownloads[filename] ?? DownloadProgress(filename: filename);
        progress.downloadedBytes.value = downloaded;
        progress.totalBytes.value = total;
        progress.bytesPerSecond.value = 0;
        progress.progress.value = total > 0 ? downloaded / total : 0;
        progress.isPaused.value = status == 'Paused';
        if (!activeDownloads.containsKey(filename)) {
          activeDownloads[filename] = progress;
        }
      }

      // Remove UI entries whose native DownloadManager jobs no longer exist.
      final staleFilenames = _nativeDownloadIds.keys
          .where((filename) => !recoveredFilenames.contains(filename))
          .toList();
      for (final filename in staleFilenames) {
        _nativeDownloadIds.remove(filename);
        activeDownloads.remove(filename);
      }
    } catch (e) {
      print('[DownloadService] Failed to reconcile active downloads: $e');
    }
  }

  Future<String> downloadModel({
    required String url,
    required String filename,
    String? authToken,
  }) async {
    if (kIsWeb) return '错误：Web 端不支持下载模型。';

    final downloadProgress = DownloadProgress(filename: filename);
    activeDownloads[filename] = downloadProgress;

    if (Platform.isAndroid) {
      try {
        final modelsDirectory = await modelsDir;
        final result = await platform_dl.startNativeDownload(
          url: url,
          filename: filename,
          modelsDir: modelsDirectory,
        );
        if (result != null) {
          final id = result['downloadId'] as int;
          _nativeDownloadIds[filename] = id;
          _nativeDownloadUrls[filename] = url;
          return 'NATIVE_BACKGROUND_STARTED';
        }
        throw Exception('原生下载未能启动。');
      } catch (e) {
        activeDownloads.remove(filename);
        rethrow;
      }
    } else {
      // iOS/desktop: the app's own resumable downloader.
      return _directDownload(url, filename, downloadProgress,
          authToken: authToken);
    }
  }

  Future<String> _directDownload(
    String url,
    String filename,
    DownloadProgress downloadProgress, {
    String? authToken,
  }) async {
    final savePath = await modelPath(filename);
    downloadProgress.startedAt = DateTime.now();
    try {
      final result = await platform_dl.downloadModel(
        url: url,
        savePath: savePath,
        authToken: authToken,
        onProgress: (received, total) {
          downloadProgress.status.value = '';
          downloadProgress.downloadedBytes.value = received;
          downloadProgress.totalBytes.value = total;
          final elapsed = DateTime.now()
              .difference(downloadProgress.startedAt)
              .inMilliseconds;
          if (elapsed > 0) {
            downloadProgress.bytesPerSecond.value = received / (elapsed / 1000);
          }
          if (total > 0) {
            downloadProgress.progress.value = received / total;
          }
        },
      );
      activeDownloads.remove(filename);
      return result;
    } catch (e) {
      activeDownloads.remove(filename);
      rethrow;
    }
  }

  Future<void> _directDownloadAfterStall(
      String url, String filename, DownloadProgress progress) async {
    progress.status.value = '正在切换为直接下载…';
    try {
      final result = await _directDownload(url, filename, progress);
      if (result != 'PAUSED') {
        try {
          await Get.find<ModelController>().refreshDownloaded();
        } catch (_) {}
      }
    } catch (e) {
      _notifyFailure(filename, '$e');
    }
  }

  void _notifyFailure(String filename, String message) {
    showToast(
      '下载失败',
      '$filename: ${message.replaceFirst('Download failed: ', '')}',
      tone: ToastTone.error,
      duration: const Duration(seconds: 6),
    );
  }

  void pauseDownload(String filename) {
    final nativeId = _nativeDownloadIds[filename];
    if (nativeId != null && Platform.isAndroid) {
      platform_dl.cancelNativeDownload(
          downloadId: nativeId, filename: filename);
      activeDownloads.remove(filename);
      _nativeDownloadIds.remove(filename);
      _nativeDownloadUrls.remove(filename);
    } else {
      platform_dl.pauseDownload(filename);
      activeDownloads[filename]?.isPaused.value = true;
    }
  }

  Future<void> deleteModel(String filename) async {
    if (kIsWeb) return;
    final nativeId = _nativeDownloadIds[filename];
    if (nativeId != null && Platform.isAndroid) {
      await platform_dl.cancelNativeDownload(
          downloadId: nativeId, filename: filename);
      _nativeDownloadIds.remove(filename);
    }
    await platform_dl.deleteModel(await modelPath(filename));
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String formatWholeMb(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = (bytes / (1024 * 1024)).round().clamp(1, 1 << 31);
    return '$mb MB';
  }

  static String formatSpeed(double bytesPerSecond) {
    return '${formatBytes(bytesPerSecond.round())}/s';
  }

  static String formatDuration(Duration? duration) {
    if (duration == null) return '--';
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    }
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
    }
    return '${duration.inSeconds}s';
  }
}
