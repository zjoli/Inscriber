import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 单个待下载模型文件描述
class ModelFileSpec {
  const ModelFileSpec({
    required this.fileName,
    required this.displayName,
    required this.approxBytes,
  });

  final String fileName;
  final String displayName;
  final int approxBytes;
}

/// 离线模型本地路径集合
class SherpaModelPaths {
  const SherpaModelPaths({
    required this.directoryPath,
    required this.encoderPath,
    required this.decoderPath,
    required this.joinerPath,
    required this.tokensPath,
  });

  final String directoryPath;
  final String encoderPath;
  final String decoderPath;
  final String joinerPath;
  final String tokensPath;
}

enum ModelDownloadStage {
  idle,
  checking,
  downloading,
  ready,
  cancelled,
  error,
}

class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.stage,
    this.progress = 0.0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.currentFileIndex = 0,
    this.totalFiles = 4,
    this.currentFileName = '',
    this.mirrorLabel = '',
    this.errorMessage,
  });

  final ModelDownloadStage stage;
  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  final int currentFileIndex;
  final int totalFiles;
  final String currentFileName;
  final String mirrorLabel;
  final String? errorMessage;

  String get formattedSizeProgress {
    final downloadedMb = (downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
    return '$downloadedMb MB / $totalMb MB';
  }
}

/// Sherpa-ONNX 离线流式双语模型按需下载与本地缓存管理器
/// - 模型：csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20（int8 量化版，约 135 MB）
/// - 仅按需下载运行所需的 4 个精简文件，而非 511 MB 完整压缩包
/// - 支持断点跳过已下文件、临时 .part 原子落盘、国内镜像与官方源自动切换
class OfflineModelManager {
  OfflineModelManager._();

  static final OfflineModelManager instance = OfflineModelManager._();

  static const String modelId =
      'sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20';
  static const String modelDisplayName =
      'Sherpa-ONNX 中英双语流式语音模型 (Zipformer int8)';

  static const List<ModelFileSpec> requiredFiles = [
    ModelFileSpec(
      fileName: 'tokens.txt',
      displayName: '词表文件',
      approxBytes: 60 * 1024,
    ),
    ModelFileSpec(
      fileName: 'joiner-epoch-99-avg-1.int8.onnx',
      displayName: '连接网络 (int8)',
      approxBytes: 3300 * 1024,
    ),
    ModelFileSpec(
      fileName: 'decoder-epoch-99-avg-1.onnx',
      displayName: '解码网络',
      approxBytes: 11200 * 1024,
    ),
    ModelFileSpec(
      fileName: 'encoder-epoch-99-avg-1.int8.onnx',
      displayName: '声学编码器 (int8)',
      approxBytes: 121000 * 1024,
    ),
  ];

  static const List<({String name, String baseUrl})> _mirrors = [
    (
      name: 'hf-mirror 加速镜像',
      baseUrl:
          'https://hf-mirror.com/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/main',
    ),
    (
      name: 'HuggingFace 官方源',
      baseUrl:
          'https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20/resolve/main',
    ),
  ];

  http.Client? _activeClient;
  bool _cancelRequested = false;

  /// 当前平台是否支持本地文件系统存放离线 ONNX 模型（Android/iOS/macOS/Win/Linux 为 true，Web 为 false）
  bool get supportsLocalOfflineModel => !kIsWeb;

  int get estimatedTotalBytes =>
      requiredFiles.fold(0, (sum, f) => sum + f.approxBytes);

  String get estimatedTotalSizeLabel =>
      '约 ${(estimatedTotalBytes / (1024 * 1024)).round()} MB';

  Future<Directory> _modelDirectory({String? overrideRootPath}) async {
    final basePath = overrideRootPath ??
        (await getApplicationSupportDirectory()).path;
    final dir = Directory('$basePath/sherpa_models/$modelId');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 检查 4 个核心模型文件是否均已完整下载到本地
  Future<bool> isModelReady({String? overrideRootPath}) async {
    if (!supportsLocalOfflineModel && overrideRootPath == null) {
      return false;
    }
    try {
      final dir = await _modelDirectory(overrideRootPath: overrideRootPath);
      for (final spec in requiredFiles) {
        final file = File('${dir.path}/${spec.fileName}');
        if (!await file.exists()) return false;
        final length = await file.length();
        if (length < 1024) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 获取本地已下载模型的完整路径；若未就绪返回 null
  Future<SherpaModelPaths?> getModelPaths({String? overrideRootPath}) async {
    if (!await isModelReady(overrideRootPath: overrideRootPath)) {
      return null;
    }
    final dir = await _modelDirectory(overrideRootPath: overrideRootPath);
    return SherpaModelPaths(
      directoryPath: dir.path,
      encoderPath: '${dir.path}/encoder-epoch-99-avg-1.int8.onnx',
      decoderPath: '${dir.path}/decoder-epoch-99-avg-1.onnx',
      joinerPath: '${dir.path}/joiner-epoch-99-avg-1.int8.onnx',
      tokensPath: '${dir.path}/tokens.txt',
    );
  }

  /// 获取本地已缓存模型总占用字节数
  Future<int> getCachedSizeBytes({String? overrideRootPath}) async {
    if (!supportsLocalOfflineModel && overrideRootPath == null) return 0;
    try {
      final dir = await _modelDirectory(overrideRootPath: overrideRootPath);
      if (!await dir.exists()) return 0;
      int total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 按需下载缺失的模型文件，实时回调进度
  Future<SherpaModelPaths?> downloadModel({
    required ValueChanged<ModelDownloadProgress> onProgress,
    String? overrideRootPath,
  }) async {
    if (!supportsLocalOfflineModel && overrideRootPath == null) {
      onProgress(
        const ModelDownloadProgress(
          stage: ModelDownloadStage.error,
          errorMessage: 'Web 端不支持本地 ONNX 权重存储，将自动使用浏览器内置语音识别。',
        ),
      );
      return null;
    }

    _cancelRequested = false;
    onProgress(
      ModelDownloadProgress(
        stage: ModelDownloadStage.checking,
        totalBytes: estimatedTotalBytes,
        totalFiles: requiredFiles.length,
      ),
    );

    if (await isModelReady(overrideRootPath: overrideRootPath)) {
      final paths = await getModelPaths(overrideRootPath: overrideRootPath);
      onProgress(
        ModelDownloadProgress(
          stage: ModelDownloadStage.ready,
          progress: 1.0,
          downloadedBytes: estimatedTotalBytes,
          totalBytes: estimatedTotalBytes,
          currentFileIndex: requiredFiles.length,
          totalFiles: requiredFiles.length,
        ),
      );
      return paths;
    }

    final dir = await _modelDirectory(overrideRootPath: overrideRootPath);
    final totalApprox = estimatedTotalBytes;
    int completedBytesBeforeCurrent = 0;

    for (int i = 0; i < requiredFiles.length; i++) {
      if (_cancelRequested) {
        onProgress(
          const ModelDownloadProgress(stage: ModelDownloadStage.cancelled),
        );
        return null;
      }

      final spec = requiredFiles[i];
      final targetFile = File('${dir.path}/${spec.fileName}');

      // 已完整下载的文件自动跳过（支持断点重下）
      if (await targetFile.exists() && await targetFile.length() > 1024) {
        completedBytesBeforeCurrent += await targetFile.length();
        onProgress(
          ModelDownloadProgress(
            stage: ModelDownloadStage.downloading,
            progress:
                (completedBytesBeforeCurrent / totalApprox).clamp(0.0, 0.99),
            downloadedBytes: completedBytesBeforeCurrent,
            totalBytes: totalApprox,
            currentFileIndex: i + 1,
            totalFiles: requiredFiles.length,
            currentFileName: spec.displayName,
            mirrorLabel: '已缓存跳过',
          ),
        );
        continue;
      }

      bool fileDownloaded = false;
      String? lastError;

      for (final mirror in _mirrors) {
        if (_cancelRequested) break;
        final url = '${mirror.baseUrl}/${spec.fileName}';
        try {
          await _downloadSingleFile(
            url: url,
            targetFile: targetFile,
            onBytes: (receivedInFile, contentLength) {
              final effectiveTotal = totalApprox;
              final totalReceived = completedBytesBeforeCurrent + receivedInFile;
              onProgress(
                ModelDownloadProgress(
                  stage: ModelDownloadStage.downloading,
                  progress:
                      (totalReceived / effectiveTotal).clamp(0.0, 0.99),
                  downloadedBytes: totalReceived,
                  totalBytes: effectiveTotal,
                  currentFileIndex: i + 1,
                  totalFiles: requiredFiles.length,
                  currentFileName: spec.displayName,
                  mirrorLabel: mirror.name,
                ),
              );
            },
          );
          completedBytesBeforeCurrent += await targetFile.length();
          fileDownloaded = true;
          break;
        } catch (e) {
          lastError = e.toString();
          if (_cancelRequested) break;
          // 尝试下一个镜像源
        }
      }

      if (_cancelRequested) {
        onProgress(
          const ModelDownloadProgress(stage: ModelDownloadStage.cancelled),
        );
        return null;
      }

      if (!fileDownloaded) {
        onProgress(
          ModelDownloadProgress(
            stage: ModelDownloadStage.error,
            currentFileIndex: i + 1,
            totalFiles: requiredFiles.length,
            currentFileName: spec.displayName,
            errorMessage: '下载「${spec.displayName}」失败，请检查网络后重试。\n($lastError)',
          ),
        );
        return null;
      }
    }

    final paths = await getModelPaths(overrideRootPath: overrideRootPath);
    if (paths == null) {
      onProgress(
        const ModelDownloadProgress(
          stage: ModelDownloadStage.error,
          errorMessage: '模型文件校验不完整，请重试下载。',
        ),
      );
      return null;
    }

    onProgress(
      ModelDownloadProgress(
        stage: ModelDownloadStage.ready,
        progress: 1.0,
        downloadedBytes: completedBytesBeforeCurrent,
        totalBytes: completedBytesBeforeCurrent,
        currentFileIndex: requiredFiles.length,
        totalFiles: requiredFiles.length,
      ),
    );
    return paths;
  }

  Future<void> _downloadSingleFile({
    required String url,
    required File targetFile,
    required void Function(int receivedBytes, int totalBytes) onBytes,
  }) async {
    final partFile = File('${targetFile.path}.part');
    if (await partFile.exists()) {
      await partFile.delete();
    }

    final client = http.Client();
    _activeClient = client;
    IOSink? sink;

    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 25));

      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      final contentLength = response.contentLength ?? 0;
      sink = partFile.openWrite();
      int received = 0;
      DateTime lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

      await for (final chunk in response.stream) {
        if (_cancelRequested) {
          throw const _DownloadCancelledException();
        }
        sink.add(chunk);
        received += chunk.length;

        final now = DateTime.now();
        if (now.difference(lastNotify).inMilliseconds >= 80) {
          lastNotify = now;
          onBytes(received, contentLength);
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (received < 1024) {
        throw const HttpException('下载文件大小异常');
      }
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await partFile.rename(targetFile.path);
      onBytes(received, contentLength);
    } catch (_) {
      await sink?.close();
      if (await partFile.exists()) {
        await partFile.delete();
      }
      rethrow;
    } finally {
      client.close();
      if (_activeClient == client) {
        _activeClient = null;
      }
    }
  }

  void cancelDownload() {
    _cancelRequested = true;
    _activeClient?.close();
    _activeClient = null;
  }

  /// 清理已下载的离线模型缓存
  Future<void> deleteModel({String? overrideRootPath}) async {
    cancelDownload();
    if (!supportsLocalOfflineModel && overrideRootPath == null) return;
    final dir = await _modelDirectory(overrideRootPath: overrideRootPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}

class _DownloadCancelledException implements Exception {
  const _DownloadCancelledException();
}
