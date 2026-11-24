import 'package:flutter/material.dart';
import '../models/teleprompter_script.dart';
import '../services/background_overlay_voice_controller.dart';
import '../services/overlay_channel.dart';
import '../services/script_repository.dart';
import '../theme/app_theme.dart';
import 'floating_teleprompter_page.dart';
import 'script_settings_page.dart';

/// 页面 1：浏览和管理所有提词稿件（温暖纸感极简风格）
class ScriptListPage extends StatefulWidget {
  const ScriptListPage({super.key});

  @override
  State<ScriptListPage> createState() => _ScriptListPageState();
}

class _ScriptListPageState extends State<ScriptListPage> {
  final ScriptRepository _repository = ScriptRepository();
  final TextEditingController _searchController = TextEditingController();

  List<TeleprompterScript> _scripts = [];
  String _searchQuery = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadScripts();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadScripts() async {
    final loaded = await _repository.loadScripts();
    if (!mounted) return;
    setState(() {
      _scripts = loaded;
      _loading = false;
    });
  }

  List<TeleprompterScript> get _filteredScripts {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _scripts;
    return _scripts.where((s) {
      return s.title.toLowerCase().contains(q) ||
          s.content.toLowerCase().contains(q);
    }).toList();
  }

  Future<void> _createNewScript() async {
    final titleController = TextEditingController();
    final contentController = TextEditingController();

    final created = await showModalBottomSheet<TeleprompterScript>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 14,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const Text(
                '新建提词',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.inkPrimary,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: titleController,
                autofocus: true,
                style: const TextStyle(color: AppColors.inkPrimary),
                decoration: const InputDecoration(
                  labelText: '提词标题',
                  hintText: '例如：产品发布会开场白',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                maxLines: 5,
                style: const TextStyle(
                  color: AppColors.inkPrimary,
                  height: 1.5,
                ),
                decoration: const InputDecoration(
                  labelText: '提词正文',
                  hintText: '输入或粘贴要朗读的台词内容，支持按换行或标点自动断句…',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () {
                  final title = titleController.text.trim();
                  final content = contentController.text.trim();
                  if (content.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('请先输入提词正文')),
                    );
                    return;
                  }
                  final script = TeleprompterScript(
                    id: 'script_${DateTime.now().microsecondsSinceEpoch}',
                    title: title.isEmpty ? '未命名提词' : title,
                    content: content,
                    updatedAt: DateTime.now(),
                  );
                  Navigator.of(ctx).pop(script);
                },
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.check, size: 18),
                label: const Text('创建并进入设置'),
              ),
            ],
          ),
        );
      },
    );

    if (created == null) return;
    final updated = await _repository.upsertScript(created);
    if (!mounted) return;
    setState(() => _scripts = updated);
    await _openSettingsPage(created);
  }

  Future<void> _openSettingsPage(TeleprompterScript script) async {
    final updatedScript = await Navigator.of(context).push<TeleprompterScript>(
      MaterialPageRoute(
        builder: (_) => ScriptSettingsPage(
          script: script,
          repository: _repository,
        ),
      ),
    );
    if (updatedScript != null) {
      await _loadScripts();
    }
  }

  void _quickLaunchFloating(TeleprompterScript script) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, __, ___) => FloatingTeleprompterPage(script: script),
      ),
    );
  }

  Future<void> _confirmDelete(TeleprompterScript script) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.border),
        ),
        title: const Text(
          '删除提词',
          style: TextStyle(color: AppColors.inkPrimary),
        ),
        content: Text(
          '确定要删除「${script.title}」吗？此操作无法撤销。',
          style: const TextStyle(color: AppColors.inkSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              '取消',
              style: TextStyle(color: AppColors.inkSecondary),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final updated = await _repository.deleteScript(script.id);
      if (!mounted) return;
      setState(() => _scripts = updated);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredScripts;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 68,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Inscriber',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: AppColors.inkPrimary,
                letterSpacing: -0.4,
              ),
            ),
            Text(
              '3 行透明歌词式悬浮提词',
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.inkSecondary,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Tooltip(
              message: '关闭系统悬浮窗',
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () async {
                  await BackgroundOverlayVoiceController.instance.stop();
                  await OverlayChannel.stopOverlay();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已关闭系统悬浮窗并停止后台语音跟读')),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.border),
                  ),
                  child: const Icon(
                    Icons.layers_clear_outlined,
                    size: 19,
                    color: AppColors.inkSecondary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(
                color: AppColors.inkPrimary,
                fontSize: 14.5,
              ),
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: InputDecoration(
                hintText: '搜索提词标题或台词内容…',
                prefixIcon: const Icon(
                  Icons.search,
                  size: 20,
                  color: AppColors.inkTertiary,
                ),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(
                          Icons.close,
                          size: 18,
                          color: AppColors.inkSecondary,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      ),
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: const BorderSide(
                    color: AppColors.inkPrimary,
                    width: 1.3,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.inkPrimary,
                      strokeWidth: 2.2,
                    ),
                  )
                : items.isEmpty
                    ? _buildEmptyState()
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          return _ScriptCard(
                            script: items[index],
                            onTap: () => _openSettingsPage(items[index]),
                            onQuickPlay: () =>
                                _quickLaunchFloating(items[index]),
                            onDelete: () => _confirmDelete(items[index]),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewScript,
        icon: const Icon(Icons.add, size: 20),
        label: const Text(
          '新建提词',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.notes_rounded,
            size: 52,
            color: AppColors.inkPrimary.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 12),
          Text(
            _searchQuery.isEmpty ? '还没有提词稿件' : '未找到匹配的提词',
            style: const TextStyle(
              fontSize: 16,
              color: AppColors.inkSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '点击右下角「新建提词」开始创建',
            style: TextStyle(fontSize: 13, color: AppColors.inkTertiary),
          ),
        ],
      ),
    );
  }
}

class _ScriptCard extends StatelessWidget {
  const _ScriptCard({
    required this.script,
    required this.onTap,
    required this.onQuickPlay,
    required this.onDelete,
  });

  final TeleprompterScript script;
  final VoidCallback onTap;
  final VoidCallback onQuickPlay;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final preview = script.content.replaceAll('\n', ' ');
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppColors.border, width: 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 15, 12, 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: const BoxDecoration(
                      color: AppColors.accentGreen,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      script.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.inkPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Tooltip(
                    message: '直接悬浮提词',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: onQuickPlay,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.inkPrimary,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 16,
                            ),
                            SizedBox(width: 2),
                            Text(
                              '提词',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '删除',
                    onPressed: onDelete,
                    icon: const Icon(
                      Icons.delete_outline,
                      color: AppColors.inkTertiary,
                      size: 19,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: AppColors.inkSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 6,
                children: [
                  _MetaChip(
                    icon: Icons.text_fields,
                    label: '${script.charCount} 字',
                  ),
                  _MetaChip(
                    icon: Icons.schedule,
                    label: '约 ${script.formattedDuration}',
                  ),
                  _MetaChip(
                    icon: script.settings.scrollMode == ScrollMode.aiVoice
                        ? Icons.mic_none_rounded
                        : Icons.speed,
                    label: script.settings.scrollMode == ScrollMode.aiVoice
                        ? 'AI 语音跟随'
                        : '${script.settings.charsPerMinute} 字/分',
                    highlighted: true,
                  ),
                  _MetaChip(
                    icon: Icons.view_headline,
                    label: '${script.settings.visibleLines} 行显示',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    required this.label,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted
            ? AppColors.accentGreenSoft
            : AppColors.chipBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlighted
              ? AppColors.accentGreen.withValues(alpha: 0.35)
              : AppColors.border,
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12.5,
            color: highlighted
                ? AppColors.accentGreenDark
                : AppColors.inkSecondary,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: highlighted ? FontWeight.w600 : FontWeight.w500,
              color: highlighted
                  ? AppColors.accentGreenDark
                  : AppColors.inkSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
