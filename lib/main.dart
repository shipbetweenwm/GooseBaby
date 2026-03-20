import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core/pet_engine.dart';
import 'ai/llm_manager.dart';
import 'skills/skill_manager.dart';
import 'ai/memory/memory_manager.dart';
import 'utils/storage.dart';
import 'ui/pet/pet_window.dart';

/// 鹅宝 - GooseBaby
/// AI 驱动的桌面智能宠物伙伴
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 全局错误处理
  FlutterError.onError = (details) {
    debugPrint('🦢 Flutter Error: ${details.exceptionAsString()}');
    debugPrint('${details.stack}');
  };

  try {
    // 初始化存储系统
    await StorageManager.initialize();
    debugPrint('🦢 存储初始化完成');
  } catch (e, stack) {
    debugPrint('🦢 存储初始化失败: $e\n$stack');
  }

  // 桌面平台特定初始化（web 平台跳过）
  if (!kIsWeb) {
    try {
      await windowManager.ensureInitialized();

      const windowOptions = WindowOptions(
        size: Size(600, 450),
        minimumSize: Size(220, 250),
        center: false,
        backgroundColor: Colors.transparent,
        skipTaskbar: true,
        alwaysOnTop: true,
        titleBarStyle: TitleBarStyle.hidden,
      );

      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.setAsFrameless();
        await windowManager.setHasShadow(false);
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setPosition(const Offset(900, 400));
        await windowManager.show();
        await windowManager.focus();
      });
    } catch (e) {
      debugPrint('🦢 桌面窗口初始化失败: $e');
    }
  }

  runApp(const GooseBabyApp());
}

class GooseBabyApp extends StatelessWidget {
  const GooseBabyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) {
          try {
            return PetEngine();
          } catch (e) {
            debugPrint('🦢 PetEngine 创建失败: $e');
            rethrow;
          }
        }),
        ChangeNotifierProvider(create: (_) {
          try {
            return LLMManager();
          } catch (e) {
            debugPrint('🦢 LLMManager 创建失败: $e');
            rethrow;
          }
        }),
        ChangeNotifierProvider(create: (_) => SkillManager()),
        ChangeNotifierProvider(create: (_) => MemoryManager()),
      ],
      child: MaterialApp(
        title: '鹅宝',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4FC3F7),
          ),
          useMaterial3: true,
        ),
        home: const _SafeHome(),
      ),
    );
  }
}

/// 安全的首页包装器 - 捕获子组件错误
class _SafeHome extends StatelessWidget {
  const _SafeHome();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF0F8FF),
      body: PetWindow(),
    );
  }
}
