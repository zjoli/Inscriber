import 'package:flutter/material.dart';
import '../services/offline_model_manager.dart';
import '../theme/app_theme.dart';

/// 确保离线 AI 语音模型就绪：
/// - Web 端无需本地权重（直接返回 true，走浏览器语音）
/// - 移动端/桌面端若模型已下载，直接返回 true
/// - 移动端/桌面端若尚未下载，自动弹出带实时进度的加载弹窗下载完成后返回 true
Future<bool> ensureAiVoiceModelReady(
  BuildContext context, {
  OfflineModelManager? manager,
}) async {
  final modelManager = manager ?? OfflineModelManager.instance;
  if (!modelManager.supportsLocalOfflineModel) {
    return true;
  }

  if (await modelManager.isModelReady()) {
    return true;
  }

  if (!context.mounted) return false;
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ModelDownloadDialog(manager: modelManager),
  );
  return result == true;
}

/// 首次开启 AI 语音跟随时的离线模型加载/下载弹窗（温暖纸感风格）
class ModelDownloadDialog extends StatefulWidget {
  const ModelDownloadDialog({
    super.key,
    required this.manager,
  });

  final OfflineModelManager manager;

  @override
  State<ModelDownloadDialog> createState() => _ModelDownloadDialogState();
}

class _ModelDownloadDialogState extends State<ModelDownloadDialog> {
  ModelDownloadProgress _progress = const ModelDownloadProgress(
    stage: ModelDownloadStage.checking,
  );

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    final paths = await widget.manager.downloadModel(
      onProgress: (p) {
        if (!mounted) return;
        setState(() => _progress = p);
      },
    );

    if (!mounted) return;
    if (paths != null) {
      await Future<void>.delayed(const Duration(milliseconds: 280));
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } else if (_progress.stage == ModelDownloadStage.cancelled) {
      Navigator.of(context).pop(false);
    }
  }

  void _cancel() {
    widget.manager.cancelDownload();
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final isError = _progress.stage == ModelDownloadStage.error;
    final isReady = _progress.stage == ModelDownloadStage.ready;
    final percent = (_progress.progress * 100).round().clamp(0, 100);

    return Dialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isError
                        ? AppColors.danger.withValues(alpha: 0.12)
                        : AppColors.accentGreenSoft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isError
                        ? Icons.cloud_off_rounded
                        : (isReady
                            ? Icons.check_circle_rounded
                            : Icons.downloading_rounded),
                    color: isError
                        ? AppColors.danger
                        : AppColors.accentGreenDark,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isError
                            ? '离线模型下载中断'
                            : (isReady ? '模型已就绪' : '正在加载离线语音模型'),
                        style: const TextStyle(
                          fontSize: 16.5,
                          fontWeight: FontWeight.w700,
                          color: AppColors.inkPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '中英双语 Zipformer (int8 · ${widget.manager.estimatedTotalSizeLabel})',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.inkSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              isError
                  ? (_progress.errorMessage ?? '网络请求失败，请检查网络后重试。')
                  : (isReady
                      ? '下载完成，正在开启本地离线 AI 语音跟随…'
                      : '首次使用 AI 语音跟随需下载端侧离线模型，下载完成后永久离线可用，无需流量与 API 费用。'),
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: isError ? AppColors.danger : AppColors.inkSecondary,
              ),
            ),
            const SizedBox(height: 18),
            // 进度条
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: _progress.stage == ModelDownloadStage.checking
                    ? null
                    : _progress.progress.clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: AppColors.surfaceMuted,
                valueColor: AlwaysStoppedAnimation<Color>(
                  isError ? AppColors.danger : AppColors.accentGreen,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _statusSubtitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.inkSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _progress.stage == ModelDownloadStage.checking
                      ? '准备中…'
                      : '$percent%',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.accentGreenDark,
                  ),
                ),
              ],
            ),
            if (_progress.totalBytes > 0 &&
                _progress.stage == ModelDownloadStage.downloading)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Text(
                      _progress.formattedSizeProgress,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppColors.inkTertiary,
                      ),
                    ),
                    const Spacer(),
                    if (_progress.mirrorLabel.isNotEmpty)
                      Text(
                        _progress.mirrorLabel,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.inkTertiary,
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!isReady)
                  OutlinedButton(
                    onPressed: _cancel,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                    ),
                    child: const Text('取消'),
                  ),
                if (isError) ...[
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _startDownload,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                    ),
                    child: const Text('重试下载'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _statusSubtitle() {
    switch (_progress.stage) {
      case ModelDownloadStage.checking:
        return '正在检查本地模型缓存…';
      case ModelDownloadStage.downloading:
        return '正在下载 ${_progress.currentFileName} (${_progress.currentFileIndex}/${_progress.totalFiles})';
      case ModelDownloadStage.ready:
        return '离线模型校验完成';
      case ModelDownloadStage.cancelled:
        return '已取消下载';
      case ModelDownloadStage.error:
        return '下载失败';
      case ModelDownloadStage.idle:
        return '等待开始';
    }
  }
}
