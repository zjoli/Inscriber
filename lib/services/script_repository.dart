import 'package:shared_preferences/shared_preferences.dart';
import '../models/teleprompter_script.dart';

/// 本地提词稿件持久化仓库
class ScriptRepository {
  static const String _storageKey = 'inscriber_scripts_v2';

  Future<List<TeleprompterScript>> loadScripts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      final samples = _buildSampleScripts();
      await saveScripts(samples);
      return samples;
    }
    try {
      final list = TeleprompterScript.decodeList(raw);
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    } catch (_) {
      final samples = _buildSampleScripts();
      await saveScripts(samples);
      return samples;
    }
  }

  Future<void> saveScripts(List<TeleprompterScript> scripts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, TeleprompterScript.encodeList(scripts));
  }

  Future<List<TeleprompterScript>> upsertScript(
    TeleprompterScript script,
  ) async {
    final current = await loadScripts();
    final index = current.indexWhere((item) => item.id == script.id);
    if (index >= 0) {
      current[index] = script;
    } else {
      current.insert(0, script);
    }
    current.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await saveScripts(current);
    return current;
  }

  Future<List<TeleprompterScript>> deleteScript(String id) async {
    final current = await loadScripts();
    current.removeWhere((item) => item.id == id);
    await saveScripts(current);
    return current;
  }

  List<TeleprompterScript> _buildSampleScripts() {
    final now = DateTime.now();
    return [
      TeleprompterScript(
        id: 'sample_short_video',
        title: '短视频口播开场（示例）',
        content:
            '哈喽大家好，欢迎来到今天的分享！\n'
            '很多朋友在录口播或者直播的时候，最头疼的就是忘词和眼神飘忽。\n'
            '今天给大家演示一款极简悬浮提词器，它可以直接悬浮在相机和直播软件上方。\n'
            '整个界面除了正在朗读的这三行文字，其余部分完全透明，完全不会遮挡画面。\n'
            '就像音乐播放器滚动歌词一样，中间高亮显示当前这一句，上下两行自然过渡。\n'
            '你可以根据自己的语速自由调节滚动速度，让每一次表达都从容自然。',
        updatedAt: now,
        settings: const TeleprompterSettings(
          charsPerMinute: 190,
          fontSize: 22,
          visibleLines: 3,
          backgroundOpacity: 0.0,
        ),
      ),
      TeleprompterScript(
        id: 'sample_product_pitch',
        title: '产品演示 60 秒演讲稿',
        content:
            '各位评委老师好，今天我带来的项目叫做 Inscriber 悬浮提词器。\n'
            '我们解决的核心痛点是创作者跨应用拍摄时的提词干扰问题。\n'
            '第一阶段我们实现了极简透明的三行歌词式定速滚动，兼顾清晰度与视线聚焦。\n'
            '第二阶段我们将接入端侧流式语音识别，实现你说多快、提词就跟多快的 AI 智能滚动。\n'
            '感谢大家的聆听，欢迎随时提出宝贵建议！',
        updatedAt: now.subtract(const Duration(hours: 2)),
        settings: const TeleprompterSettings(
          charsPerMinute: 170,
          fontSize: 24,
          visibleLines: 3,
          activeTextColorValue: 0xFF20201E,
          inactiveTextColorValue: 0x996E6D68,
          backgroundOpacity: 0.0,
        ),
      ),
    ];
  }
}
