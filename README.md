# Inscriber 悬浮提词器（Flutter + 原生悬浮层）

一款支持 **3 行音乐歌词式平滑滚动**、**全透明悬浮** 的移动端提词器。  
第一阶段已完整实现 **固定速率滚动** 与跨应用悬浮底层，并预留了 **AI 语音智能跟随** 驱动接口。

---

## 一、三个核心页面与功能

1. **页面 1：提词列表页（`lib/pages/script_list_page.dart`）**
   - 浏览、搜索、新建、删除本地提词稿件（内置 2 份示例稿件）。
   - 展示每份提词字数、按当前速率估算的朗读时长、行显示设置。
   - 支持点击进入设置页，或一键快捷进入悬浮提词。
2. **页面 2：提词设置页（`lib/pages/script_settings_page.dart`）**
   - 顶部内置 **实时 3 行透明歌词效果预览**（可随时点击试看滚动）。
   - 支持编辑标题与正文，调节**固定朗读速率（字/分）**、**字体大小**、**每行断句字数**、**背景透明度（默认 0% 全透明）**、**当前行高亮配色**、**文字描边阴影**与**镜像模式**。
   - 滚动模式已预留 **AI 语音跟随** 入口。
3. **页面 3：悬浮提词页 & 跨应用系统悬浮**
   - **应用内透明悬浮页（`lib/pages/floating_teleprompter_page.dart`）**：默认 2.8 秒后自动隐藏控制条，仅保留 3 行歌词式滚动提词（上一行淡出、当前行高亮放大、下一行预告），支持上下拖动调整高度贴近镜头。
   - **Android 真透明跨应用悬浮窗（`android/app/src/main/kotlin/com/inscriber/inscriber/`）**：基于 `WindowManager` + `ForegroundService` + 60fps 原生 Canvas 绘制，真正全透明悬浮在相机/直播等其他 App 上方，轻点呼出微控条（暂停/变速/重头/关闭），2.8 秒后自动隐藏。
   - **iOS 画中画跨应用悬浮（`ios/Runner/PiPTeleprompterManager.swift`）**：基于 Apple 合规的 `AVPictureInPictureController` + `AVSampleBufferDisplayLayer` 30fps 离屏渲染 3 行歌词滚动帧，支持系统画中画播放/暂停联动。

---

## 二、目录结构

```text
lib/
├── main.dart                                 # 应用入口与深色主题
├── models/
│   └── teleprompter_script.dart              # 提词稿件与播放配置模型
├── engine/
│   ├── line_splitter.dart                    # 智能标点/视觉宽度断句器
│   └── scroll_driver.dart                    # ScrollDriver 抽象接口（已实现 FixedRateScrollDriver，预留 AiVoiceScrollDriver）
├── services/
│   ├── script_repository.dart                # 本地持久化仓库（SharedPreferences）
│   └── overlay_channel.dart                  # Flutter <-> Android/iOS 原生悬浮桥接
├── widgets/
│   └── lyric_teleprompter_view.dart          # 3 行音乐歌词式透明滚动组件
└── pages/
    ├── script_list_page.dart                 # 页面 1：提词浏览
    ├── script_settings_page.dart             # 页面 2：提词设置
    └── floating_teleprompter_page.dart       # 页面 3：透明悬浮提词
android/app/src/main/
├── AndroidManifest.xml                       # 悬浮窗与前台服务权限
└── kotlin/com/inscriber/inscriber/
    ├── MainActivity.kt                       # MethodChannel 通道
    ├── TeleprompterOverlayService.kt         # 透明悬浮窗前台服务
    └── LyricTeleprompterOverlayView.kt       # 60fps 透明 3 行歌词原生绘制视图
ios/Runner/
├── Info.plist                                # 后台 audio 模式（PiP 必需）
├── AppDelegate.swift                         # MethodChannel 通道
└── PiPTeleprompterManager.swift              # 30fps 画中画 3 行歌词帧渲染管理器
test/
└── teleprompter_engine_test.dart             # 断句、定速驱动、序列化与组件单元测试
```

---

## 三、本地初始化与运行指南

> 当前机器未检测到 `flutter` CLI，安装 Flutter SDK 后按以下步骤即可运行：

### 1. 补齐本地 Gradle / Xcode 工程脚手架（不会覆盖已有源码）
```bash
cd /Users/gouxu/Downloads/Inscriber
flutter create --platforms=android,ios --org com.inscriber .
flutter pub get
```

### 2. 运行单元测试
```bash
flutter test
```

### 3. 运行到真机 / 模拟器
```bash
# Android（推荐真机测试全透明系统悬浮窗）
flutter run -d android

# iOS（需 iOS 15+ 真机或支持 PiP 的模拟器）
# 注意：首次用 Xcode 打开 ios/Runner.xcworkspace 时，确认 PiPTeleprompterManager.swift 已加入 Runner Target
flutter run -d ios
```

---

## 四、后续 Phase 2：AI 语音智能滚动接入说明

底层已抽象 `ScrollDriver` 接口并在 `lib/engine/scroll_driver.dart` 中预留了 `AiVoiceScrollDriver`：
1. 接入端侧流式 ASR（推荐 **Sherpa-ONNX** + 阿里流式 Paraformer 中文模型），采集 16kHz PCM 音频实时输出识别片段。
2. 在 `AiVoiceScrollDriver.onPartialTranscript` 中将实时识别字词转拼音并与当前窗口内台词做模糊对齐，更新 `_targetProgress`。
3. 现有 3 行歌词 UI 及悬浮渲染层无需改动即可平滑跟随语速滚动。
