import 'package:flutter/material.dart';
import 'pages/script_list_page.dart';
import 'theme/app_theme.dart';
import 'widgets/mobile_preview_frame.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InscriberApp());
}

class InscriberApp extends StatelessWidget {
  const InscriberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Inscriber 悬浮提词器',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      builder: (context, child) {
        return MobilePreviewFrame(child: child ?? const SizedBox.shrink());
      },
      home: const ScriptListPage(),
    );
  }
}
