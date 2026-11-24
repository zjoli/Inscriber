import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inscriber/engine/line_splitter.dart';
import 'package:inscriber/engine/scroll_driver.dart';
import 'package:inscriber/engine/voice_alignment_engine.dart';
import 'package:inscriber/models/teleprompter_script.dart';
import 'package:inscriber/pages/script_settings_page.dart';
import 'package:inscriber/services/offline_model_manager.dart';
import 'package:inscriber/services/script_repository.dart';
import 'package:inscriber/theme/app_theme.dart';
import 'package:inscriber/widgets/lyric_teleprompter_view.dart';

void main() {
  group('LyricLineSplitter', () {
    test('splits long Chinese paragraph naturally around punctuation', () {
      const text =
          '哈喽大家好，欢迎来到今天的分享！今天给大家演示一款极简悬浮提词器，它可以直接悬浮在相机和直播软件上方。';
      final lines = LyricLineSplitter.split(text, maxCharsPerLine: 16);

      expect(lines.length, greaterThanOrEqualTo(3));
      expect(lines.first, contains('哈喽大家好'));
      for (final line in lines) {
        expect(line.trim().isNotEmpty, isTrue);
      }
    });

    test('returns placeholder line for empty input', () {
      expect(LyricLineSplitter.split('   \n  '), equals(['（暂无提词内容）']));
    });
  });

  group('FixedRateScrollDriver', () {
    test('advances progress smoothly and stops cleanly at the last line', () {
      final driver = FixedRateScrollDriver(
        lines: const ['第一行示例提词内容', '第二行示例提词内容', '第三行示例提词内容'],
        charsPerMinute: 180,
      );

      expect(driver.progress, 0.0);
      expect(driver.isPlaying, isFalse);

      driver.play();
      expect(driver.isPlaying, isTrue);

      driver.tick(const Duration(milliseconds: 500));
      expect(driver.progress, greaterThan(0.0));
      expect(driver.progress, lessThan(2.0));

      // 推进足够长时间直到结束
      for (int i = 0; i < 40; i++) {
        driver.tick(const Duration(milliseconds: 500));
      }
      expect(driver.progress, equals(2.0));
      expect(driver.isFinished, isTrue);
      expect(driver.isPlaying, isFalse);
    });

    test('updates speed dynamically without jumping progress', () {
      final driver = FixedRateScrollDriver(
        lines: const ['第一行十个字测试内容', '第二行十个字测试内容'],
        charsPerMinute: 120,
      );
      driver.play();
      driver.tick(const Duration(milliseconds: 500));
      final before = driver.progress;

      driver.updateCharsPerMinute(240);
      expect(driver.progress, equals(before));
      expect(driver.charsPerMinute, equals(240));
    });
  });

  group('TeleprompterScript serialization', () {
    test('encodes and decodes script list with settings intact', () {
      final original = [
        TeleprompterScript(
          id: 's1',
          title: '测试提词',
          content: '一二三四五六七八九十',
          updatedAt: DateTime(2026, 11, 24, 12, 0),
          settings: const TeleprompterSettings(
            charsPerMinute: 210,
            fontSize: 26,
            visibleLines: 3,
            backgroundOpacity: 0.0,
          ),
        ),
      ];

      final raw = TeleprompterScript.encodeList(original);
      final restored = TeleprompterScript.decodeList(raw);

      expect(restored.length, 1);
      expect(restored.first.id, 's1');
      expect(restored.first.title, '测试提词');
      expect(restored.first.settings.charsPerMinute, 210);
      expect(restored.first.settings.fontSize, 26);
      expect(restored.first.settings.backgroundOpacity, 0.0);
    });
  });

  group('LyricTeleprompterView widget', () {
    testWidgets('renders 3-line lyric view on transparent container', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(
              child: LyricTeleprompterView(
                lines: ['第一行台词', '第二行当前高亮台词', '第三行预告台词', '第四行隐藏台词'],
                progress: 1.0,
                settings: TeleprompterSettings(
                  visibleLines: 3,
                  backgroundOpacity: 0.0,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('第一行台词'), findsOneWidget);
      expect(find.text('第二行当前高亮台词'), findsOneWidget);
      expect(find.text('第三行预告台词'), findsOneWidget);
    });

    testWidgets('ScriptSettingsPage renders without ListTile Material assertion',
        (tester) async {
      final script = TeleprompterScript(
        id: 'test_settings',
        title: '设置页测试',
        content: '第一行内容，第二行内容，第三行内容。',
        updatedAt: DateTime(2026, 11, 24),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          home: ScriptSettingsPage(
            script: script,
            repository: ScriptRepository(),
          ),
        ),
      );
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pump();

      expect(find.text('文字描边阴影'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('splitToFitWidth wraps long lines cleanly without losing chars',
        (tester) async {
      const longText = '今天给大家演示一款极简悬浮提词器，它可以直接悬浮在相机和直播软件上方且绝不省略任何一个字。';
      final lines = LyricLineSplitter.splitToFitWidth(
        longText,
        maxWidth: 220,
        fontSize: 30,
        maxCharsPerLine: 24,
      );

      expect(lines.length, greaterThanOrEqualTo(4));
      expect(lines.join(), equals(longText));
      for (final line in lines) {
        expect(line.contains('...'), isFalse);
        expect(line.contains('…'), isFalse);
      }
    });
  });

  group('VoiceAlignmentEngine & AiVoiceScrollDriver', () {
    const sampleLines = [
      '哈喽大家好欢迎来到今天的分享',
      '今天给大家演示一款极简悬浮提词器',
      '它可以直接悬浮在相机和直播软件上方',
      '让每一次表达都从容自然',
    ];

    test('matches homophones, filler words, and skipped words smoothly', () {
      final engine = VoiceAlignmentEngine(lines: sampleLines);

      // 1. 正常开头 + 语气词“嗯”
      final r1 = engine.alignTranscript('嗯哈喽大家好欢迎来到');
      expect(r1.matched, isTrue);
      expect(r1.lineProgress, greaterThan(0.2));

      // 2. 同音错别字：“题词气” 对齐 “提词器”
      final r2 = engine.alignTranscript('今天给大家演示一款极简悬浮题词气');
      expect(r2.matched, isTrue);
      expect(r2.lineProgress, greaterThan(1.4));

      // 3. 跳过中间部分词直接念下一句
      final r3 = engine.alignTranscript('直接悬浮在相机和直播软件上方');
      expect(r3.matched, isTrue);
      expect(r3.lineProgress, greaterThan(2.3));
    });

    test('ignores unrelated ambient speech without false jumping', () {
      final engine = VoiceAlignmentEngine(lines: sampleLines);
      final r = engine.alignTranscript('请问外卖放门口就可以了谢谢');
      expect(r.matched, isFalse);
      expect(engine.cursorTokenIndex, equals(0));
    });

    test('AiVoiceScrollDriver eases smoothly toward matched target and supports seek',
        () {
      final driver = AiVoiceScrollDriver(lines: sampleLines);
      driver.play();
      driver.onPartialTranscript('今天给大家演示一款极简悬浮提词器');

      expect(driver.targetProgress, greaterThan(1.4));
      driver.tick(const Duration(milliseconds: 100));
      expect(driver.progress, greaterThan(0.0));
      expect(driver.progress, lessThanOrEqualTo(driver.targetProgress));

      // 手动拖回第 0 行后，语音对齐应能重新从第 0 行继续匹配
      driver.seekToLine(0.0);
      expect(driver.progress, equals(0.0));
      final rematch = driver.onPartialTranscript('哈喽大家好欢迎来到今天的分享');
      expect(rematch.matched, isTrue);
      expect(driver.targetProgress, lessThan(1.2));
    });

    test('OfflineModelManager validates local cache completeness and cleanup',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('inscriber_model_');
      try {
        final manager = OfflineModelManager.instance;
        expect(
          await manager.isModelReady(overrideRootPath: tempDir.path),
          isFalse,
        );

        final modelDir = Directory(
          '${tempDir.path}/sherpa_models/${OfflineModelManager.modelId}',
        );
        await modelDir.create(recursive: true);

        // 写入 4 个模拟完整模型文件
        final payload = List<int>.filled(2048, 1);
        for (final spec in OfflineModelManager.requiredFiles) {
          await File('${modelDir.path}/${spec.fileName}').writeAsBytes(payload);
        }

        expect(
          await manager.isModelReady(overrideRootPath: tempDir.path),
          isTrue,
        );
        final paths = await manager.getModelPaths(overrideRootPath: tempDir.path);
        expect(paths, isNotNull);
        expect(paths!.encoderPath, endsWith('encoder-epoch-99-avg-1.int8.onnx'));

        await manager.deleteModel(overrideRootPath: tempDir.path);
        expect(
          await manager.isModelReady(overrideRootPath: tempDir.path),
          isFalse,
        );
      } finally {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    });
  });
}
