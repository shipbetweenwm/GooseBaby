import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:media_kit/media_kit.dart';

import 'core/pet_engine.dart';
import 'core/achievement_manager.dart';
import 'ai/llm_manager.dart';
import 'ai/self_improvement.dart';
import 'skills/skill_manager.dart';
import 'skills/scheduled_task.dart';
import 'ai/memory/memory_manager.dart';
import 'services/diary_service.dart';
import 'utils/storage.dart';
import 'ui/pet/pet_window.dart';
import 'ui/widgets/tray_manager.dart';

/// 鹅宝 - GooseBaby
/// AI 驱动的桌面智能宠物伙伴
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化 MediaKit（视频播放引擎）
  MediaKit.ensureInitialized();

  // 全局错误处理
  FlutterError.onError = (details) {
    debugPrint('🦢 Flutter Error: ${details.exceptionAsString()}');
    debugPrint('${details.stack}');
  };

  try {
    // 初始化存储系统
    await StorageManager.initialize();
    debugPrint('🦢 存储初始化完成');
    
    // 初始化日记服务
    await DiaryService.instance.init();
    debugPrint('🦢 日记服务初始化完成');
  } catch (e, stack) {
    debugPrint('🦢 存储初始化失败: $e\n$stack');
  }

  // 桌面平台特定初始化（web 平台跳过）
  if (!kIsWeb) {
    try {
      await windowManager.ensureInitialized();

      // 先获取屏幕尺寸，用于计算窗口初始大小
      // 初始窗口大小 = 宠物区域大小（400x450）
      const Size windowSize = Size(400, 450);
      const Size minSize = Size(180, 250);

      try {
        final primaryScreen = await screenRetriever.getPrimaryDisplay();
        final screenSize = primaryScreen.size;
        debugPrint('🦢 屏幕尺寸: ${screenSize.width} x ${screenSize.height}');
      } catch (e) {
        debugPrint('🦢 获取屏幕尺寸失败，使用默认值: $e');
      }

      final windowOptions = WindowOptions(
        size: windowSize,
        minimumSize: minSize,
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

        // 计算窗口位置：右下角固定
        Offset startPos = const Offset(900, 400); // 回退默认值
        try {
          // 使用 screen_retriever 获取主屏幕尺寸
          final primaryScreen = await screenRetriever.getPrimaryDisplay();
          final screenSize = primaryScreen.size;

          // 防御：如果获取到的屏幕尺寸不合理（太小或为零），使用回退值
          if (screenSize.width > windowSize.width && screenSize.height > windowSize.height) {
            // 右下角：窗口右下角固定在屏幕右下角附近（距右边缘 20px，距底部 80px）
            startPos = Offset(
              screenSize.width - windowSize.width - 20,
              screenSize.height - windowSize.height - 80,
            );
          } else {
            debugPrint('🦢 屏幕尺寸异常(${screenSize.width}x${screenSize.height})，使用默认位置');
          }
        } catch (e) {
          debugPrint('🦢 获取屏幕尺寸失败，使用默认位置: $e');
        }

        // 确保坐标不为负数（防止窗口出现在屏幕外）
        startPos = Offset(
          startPos.dx.clamp(0, double.infinity),
          startPos.dy.clamp(0, double.infinity),
        );
        debugPrint('🦢 窗口初始位置: (${startPos.dx}, ${startPos.dy})，大小: ${windowSize.width}x${windowSize.height}');
        await windowManager.setPosition(startPos);

        await windowManager.setPreventClose(true);
        await windowManager.show();
        await windowManager.focus();
      });

      // Fix: 启动后做一次微小的窗口尺寸抖动，强制触发 WM_SIZE，
      // 让 Flutter 重新布局并正确渲染视频纹理。
      Future.delayed(const Duration(milliseconds: 500), () async {
        try {
          final size = await windowManager.getSize();
          await windowManager.setSize(Size(size.width + 1, size.height + 1));
          await Future.delayed(const Duration(milliseconds: 50));
          await windowManager.setSize(size);
        } catch (_) {}
      });

      // 初始化系统托盘
      await TrayManager.initialize();
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
        ChangeNotifierProvider(create: (_) => ScheduledTaskManager()),
        ChangeNotifierProvider(create: (_) => AchievementManager()),
        // 日记服务（单例模式，已在 main() 中初始化）
        ChangeNotifierProvider.value(value: DiaryService.instance),
        // Self-improvement 引擎（依赖 LLMManager 和 MemoryManager）
        ChangeNotifierProxyProvider2<LLMManager, MemoryManager, SelfImprovementEngine>(
          create: (_) => SelfImprovementEngine(
            llmManager: LLMManager(),
            memoryManager: MemoryManager(),
          ),
          update: (_, llm, memory, prev) {
            if (prev != null) return prev;
            return SelfImprovementEngine(llmManager: llm, memoryManager: memory);
          },
        ),
      ],
      child: MaterialApp(
        title: '鹅宝',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4FC3F7),
          ),
          useMaterial3: true,
          scaffoldBackgroundColor: Colors.transparent,
          canvasColor: Colors.transparent,
        ),
        home: const _SafeHome(),
      ),
    );
  }
}

/// 安全的首页包装器 - 捕获子组件错误 + 窗口关闭拦截
class _SafeHome extends StatefulWidget {
  const _SafeHome();

  @override
  State<_SafeHome> createState() => _SafeHomeState();
}

class _SafeHomeState extends State<_SafeHome> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  /// 拦截窗口关闭事件：最小化到系统托盘，而不是退出
  @override
  void onWindowClose() async {
    // 隐藏到系统托盘（不退出应用）
    await windowManager.hide();
    TrayManager.notifyHidden();
    debugPrint('🦢 窗口已最小化到系统托盘');
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.transparent,
      body: PetWindow(),
    );
  }
}
