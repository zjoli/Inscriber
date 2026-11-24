import 'dart:math' as math;
import 'package:pinyin/pinyin.dart';

/// 提词稿件中的单个可朗读字/词元
class _ScriptToken {
  const _ScriptToken({
    required this.raw,
    required this.pinyin,
    required this.fuzzyPinyin,
    required this.lineIndex,
    required this.fractionInLine,
  });

  final String raw;
  final String pinyin;
  final String fuzzyPinyin;
  final int lineIndex;

  /// 该字在当前行内的归一化进度 [0.0, 1.0]
  final double fractionInLine;
}

/// 单次对齐匹配结果
class AlignmentMatchResult {
  const AlignmentMatchResult({
    required this.matched,
    required this.tokenIndex,
    required this.lineProgress,
    required this.charRatio,
    required this.confidence,
    this.matchedLineSnippet = '',
  });

  final bool matched;
  final int tokenIndex;
  final double lineProgress;

  /// 当前匹配字在全文可读字中的归一化位置 [0.0, 1.0]，用于跨端不同换行宽度精确同步
  final double charRatio;
  final double confidence;
  final String matchedLineSnippet;
}

/// 中文拼音 + 局部滑动窗口模糊对齐引擎
/// 专为提词器流式语音跟随设计：
/// 1. 自动处理同音错别字（如“提词”识别成“题词”）与前后鼻音/平翘舌模糊音
/// 2. 容忍口播中的口误、加语气词（“嗯”、“那个”）、漏词跳读
/// 3. 限制在当前朗读指针附近的局部窗口内搜索，防止远处重复短语导致误跳
class VoiceAlignmentEngine {
  VoiceAlignmentEngine({required List<String> lines}) {
    updateLines(lines);
  }

  static final RegExp _readableCharRegex =
      RegExp(r'[\u4E00-\u9FFF\u3400-\u4DBFA-Za-z0-9]');

  List<String> _lines = const [];
  List<_ScriptToken> _tokens = const [];
  int _cursorTokenIndex = 0;

  int get cursorTokenIndex => _cursorTokenIndex;
  int get totalTokens => _tokens.length;

  /// 当前指针在全文可读字符中的进度比例 [0.0, 1.0]
  double get currentCharRatio => _tokens.length <= 1
      ? 0.0
      : (_cursorTokenIndex / (_tokens.length - 1)).clamp(0.0, 1.0);

  /// 当提词文本或因字号/屏幕宽度变化导致重新自动换行时，重建索引并尽量保留当前进度
  void updateLines(List<String> newLines) {
    final double oldRatio = _tokens.isEmpty
        ? 0.0
        : (_cursorTokenIndex / math.max(1, _tokens.length - 1)).clamp(0.0, 1.0);

    _lines = newLines.isEmpty ? const ['（暂无提词内容）'] : List.unmodifiable(newLines);
    final built = <_ScriptToken>[];

    for (int lineIdx = 0; lineIdx < _lines.length; lineIdx++) {
      final line = _lines[lineIdx];
      final readableChars = _extractReadableChars(line);
      if (readableChars.isEmpty) continue;
      final count = readableChars.length;

      for (int i = 0; i < count; i++) {
        final raw = readableChars[i];
        final py = _toPinyin(raw);
        built.add(
          _ScriptToken(
            raw: raw,
            pinyin: py,
            fuzzyPinyin: _toFuzzyPinyin(py),
            lineIndex: lineIdx,
            fractionInLine: count <= 1 ? 1.0 : (i + 1) / count,
          ),
        );
      }
    }

    _tokens = built;
    if (_tokens.isEmpty) {
      _cursorTokenIndex = 0;
    } else {
      _cursorTokenIndex =
          (oldRatio * (_tokens.length - 1)).round().clamp(0, _tokens.length - 1);
    }
  }

  void reset() {
    _cursorTokenIndex = 0;
  }

  /// 用户手动拖动歌词进度条后，将语音对齐指针同步到对应行位置
  void syncToLineProgress(double lineProgress) {
    if (_tokens.isEmpty) {
      _cursorTokenIndex = 0;
      return;
    }
    final targetLine = lineProgress.floor().clamp(0, math.max(0, _lines.length - 1));
    final frac = (lineProgress - targetLine).clamp(0.0, 1.0);

    int bestIdx = 0;
    for (int i = 0; i < _tokens.length; i++) {
      final t = _tokens[i];
      if (t.lineIndex < targetLine) {
        bestIdx = i;
      } else if (t.lineIndex == targetLine) {
        bestIdx = i;
        if (t.fractionInLine >= frac) {
          break;
        }
      } else {
        break;
      }
    }
    _cursorTokenIndex = bestIdx.clamp(0, _tokens.length - 1);
  }

  /// 接收流式 ASR 实时识别文本（通常是当前语音段不断增长的句子），返回最新对齐的行进度
  AlignmentMatchResult alignTranscript(String transcript) {
    if (_tokens.isEmpty) {
      return const AlignmentMatchResult(
        matched: false,
        tokenIndex: 0,
        lineProgress: 0.0,
        charRatio: 0.0,
        confidence: 0.0,
      );
    }

    final queryRawChars = _extractReadableChars(transcript);
    if (queryRawChars.isEmpty) {
      return AlignmentMatchResult(
        matched: false,
        tokenIndex: _cursorTokenIndex,
        lineProgress: _tokenIndexToLineProgress(_cursorTokenIndex),
        charRatio: currentCharRatio,
        confidence: 0.0,
      );
    }

    // 只截取最近说出的一段尾巴（最多 12 个可读字），聚焦实时说话位置，计算量极小（< 1ms）
    final int tailLength = math.min(queryRawChars.length, 12);
    final tailChars =
        queryRawChars.sublist(queryRawChars.length - tailLength);
    final queryTokens = tailChars.map((ch) {
      final py = _toPinyin(ch);
      return (raw: ch, pinyin: py, fuzzy: _toFuzzyPinyin(py));
    }).toList();

    // 局部滑动窗口：允许极小范围校准，向前最多看 40 字（兼容漏读/跳词）
    final int windowStart = math.max(0, _cursorTokenIndex - 3);
    final int windowEnd = math.min(_tokens.length, _cursorTokenIndex + 40);
    if (windowStart >= windowEnd) {
      return AlignmentMatchResult(
        matched: false,
        tokenIndex: _cursorTokenIndex,
        lineProgress: _tokenIndexToLineProgress(_cursorTokenIndex),
        charRatio: currentCharRatio,
        confidence: 0.0,
      );
    }

    // 针对很短的初始识别（1~2字），要求紧邻当前位置精确或同音命中，防止环境杂音误触发
    if (queryTokens.length == 1) {
      final q = queryTokens.first;
      final narrowEnd = math.min(windowEnd, _cursorTokenIndex + 4);
      for (int j = _cursorTokenIndex; j < narrowEnd; j++) {
        final s = _scorePair(q.raw, q.pinyin, q.fuzzy, _tokens[j]);
        if (s >= 2.5) {
          _cursorTokenIndex = j;
          return AlignmentMatchResult(
            matched: true,
            tokenIndex: _cursorTokenIndex,
            lineProgress: _tokenIndexToLineProgress(_cursorTokenIndex),
            charRatio: currentCharRatio,
            confidence: 0.85,
            matchedLineSnippet: _lines[_tokens[_cursorTokenIndex].lineIndex],
          );
        }
      }
      return AlignmentMatchResult(
        matched: false,
        tokenIndex: _cursorTokenIndex,
        lineProgress: _tokenIndexToLineProgress(_cursorTokenIndex),
        charRatio: currentCharRatio,
        confidence: 0.0,
      );
    }

    // 半全局局部动态规划（允许稿件窗口任意起点开始匹配，强制对齐到最近说出的 query 末尾）
    final int m = queryTokens.length;
    final int n = windowEnd - windowStart;
    const double gapPenalty = -1.25;

    // dp[i][j] 表示 query[0..i-1] 与 window[?..j-1] 的最佳局部对齐得分
    final dp = List.generate(m + 1, (_) => List<double>.filled(n + 1, 0.0));
    // 第一列初始化：允许跳过 query 开头的多余语气词（如“嗯、那个”），只施加轻惩罚
    for (int i = 1; i <= m; i++) {
      dp[i][0] = i * -0.9;
    }
    // 第一行保持 0：允许从稿件窗口内任意位置起配

    for (int i = 1; i <= m; i++) {
      final q = queryTokens[i - 1];
      for (int j = 1; j <= n; j++) {
        final target = _tokens[windowStart + j - 1];
        final matchScore =
            dp[i - 1][j - 1] + _scorePair(q.raw, q.pinyin, q.fuzzy, target);
        final delQuery = dp[i - 1][j] + gapPenalty; // 说话多加了语气词/重复字
        final skipScript = dp[i][j - 1] + gapPenalty; // 说话漏念了一个字
        dp[i][j] = math.max(matchScore, math.max(delQuery, skipScript));
      }
    }

    // 在最后一行 dp[m][1..n] 中寻找综合得分最高的结束位置
    double bestAdjustedScore = double.negativeInfinity;
    double bestRawScore = 0.0;
    int bestGlobalEndIdx = _cursorTokenIndex;

    for (int j = 1; j <= n; j++) {
      final globalEndIdx = windowStart + j - 1;
      final rawScore = dp[m][j];

      // 距离偏好：轻微惩罚一次跳太远（>14字），避免远处相同短语抢跳，同时不阻挡正常跳读
      final int jump = globalEndIdx - _cursorTokenIndex;
      double distancePenalty = 0.0;
      if (jump < 0) {
        distancePenalty = jump.abs() * 0.6;
      } else if (jump > 14) {
        distancePenalty = (jump - 14) * 0.16;
      }

      final adjusted = rawScore - distancePenalty;
      if (adjusted > bestAdjustedScore) {
        bestAdjustedScore = adjusted;
        bestRawScore = rawScore;
        bestGlobalEndIdx = globalEndIdx;
      }
    }

    final double maxPossibleScore = m * 3.0;
    final double confidence = (bestRawScore / maxPossibleScore).clamp(0.0, 1.0);

    // 置信度阈值：短尾词要求稍高，长尾词允许一定口误和噪音
    final double requiredConfidence = m <= 3 ? 0.56 : 0.44;
    if (confidence >= requiredConfidence &&
        bestGlobalEndIdx >= _cursorTokenIndex) {
      _cursorTokenIndex = bestGlobalEndIdx;
      return AlignmentMatchResult(
        matched: true,
        tokenIndex: _cursorTokenIndex,
        lineProgress: _tokenIndexToLineProgress(_cursorTokenIndex),
        charRatio: currentCharRatio,
        confidence: confidence,
        matchedLineSnippet: _lines[_tokens[_cursorTokenIndex].lineIndex],
      );
    }

    return AlignmentMatchResult(
      matched: false,
      tokenIndex: _cursorTokenIndex,
      lineProgress: _tokenIndexToLineProgress(_cursorTokenIndex),
      charRatio: currentCharRatio,
      confidence: confidence,
    );
  }

  /// 将当前已朗读到的字索引映射为丝滑的 3 行歌词滚动进度：
  /// 读到行前中段时保持当前行居中易读，临近行尾时平滑抬升下一行
  double _tokenIndexToLineProgress(int tokenIdx) {
    if (_tokens.isEmpty || _lines.length <= 1) return 0.0;
    final clampedIdx = tokenIdx.clamp(0, _tokens.length - 1);
    final token = _tokens[clampedIdx];
    final double maxP = (_lines.length - 1).toDouble();

    if (clampedIdx >= _tokens.length - 1) {
      return maxP;
    }

    // 缓入曲线：念完该行 50% 时行仅微移 0.35，念到行尾时平滑接近下一行
    final double easedFrac = math.pow(token.fractionInLine, 1.35).toDouble();
    return (token.lineIndex + easedFrac * 0.92).clamp(0.0, maxP);
  }

  static double _scorePair(
    String qRaw,
    String qPinyin,
    String qFuzzy,
    _ScriptToken target,
  ) {
    if (qRaw == target.raw) return 3.0;
    if (qPinyin.isNotEmpty && qPinyin == target.pinyin) return 2.6;
    if (qFuzzy.isNotEmpty && qFuzzy == target.fuzzyPinyin) return 2.0;
    return -1.6;
  }

  static List<String> _extractReadableChars(String text) {
    final result = <String>[];
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      if (_readableCharRegex.hasMatch(ch)) {
        result.add(ch.toLowerCase());
      }
    }
    return result;
  }

  static String _toPinyin(String singleChar) {
    if (singleChar.isEmpty) return '';
    final code = singleChar.codeUnitAt(0);
    // 英文/数字直接原样返回
    if (code <= 0x007F) return singleChar.toLowerCase();
    try {
      final py = PinyinHelper.getPinyinE(
        singleChar,
        separator: '',
        defPinyin: singleChar,
        format: PinyinFormat.WITHOUT_TONE,
      );
      return py.toLowerCase().trim();
    } catch (_) {
      return singleChar;
    }
  }

  /// 南北方口音模糊音归一化：平翘舌、前后鼻音、n/l、f/h
  static String _toFuzzyPinyin(String pinyin) {
    if (pinyin.length <= 1) return pinyin;
    var s = pinyin;
    if (s.startsWith('zh')) {
      s = 'z${s.substring(2)}';
    } else if (s.startsWith('ch')) {
      s = 'c${s.substring(2)}';
    } else if (s.startsWith('sh')) {
      s = 's${s.substring(2)}';
    } else if (s.startsWith('n')) {
      s = 'l${s.substring(1)}';
    } else if (s.startsWith('r')) {
      s = 'l${s.substring(1)}';
    }

    if (s.endsWith('ang')) {
      s = '${s.substring(0, s.length - 3)}an';
    } else if (s.endsWith('eng')) {
      s = '${s.substring(0, s.length - 3)}en';
    } else if (s.endsWith('ing')) {
      s = '${s.substring(0, s.length - 3)}in';
    }
    return s;
  }
}
