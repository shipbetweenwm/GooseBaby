/// CUA Brain 模块
///
/// 参考 TuriX-CUA 的 Brain-Actor 双模型架构：
/// - Brain（视觉模型）：看截图 → 分析当前状态 → 判断上步是否成功 → 决定下一步目标
/// - Actor（主模型）：根据 Brain 的目标 → 输出具体 cua 工具调用（坐标、按键等）
///
/// 核心优势：Brain 专注"看图判断"，Actor 专注"操作执行"，避免单模型认知负担。
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Brain 的分析结果
class CuaBrainResult {
  /// 分析内容（当前屏幕状态的详细描述）
  final String analysis;

  /// 上一步操作评估：Success / Failed / N/A（第一步无前操作）
  final String stepEvaluate;

  /// 是否需要向用户确认
  final String askHuman;

  /// 下一步操作目标（给 Actor 执行的具体指令）
  final String nextGoal;

  const CuaBrainResult({
    required this.analysis,
    required this.stepEvaluate,
    required this.askHuman,
    required this.nextGoal,
  });

  bool get isAskHuman => askHuman != 'No' && askHuman.isNotEmpty;
  bool get isStepSuccess => stepEvaluate == 'Success';
  bool get isStepFailed => stepEvaluate == 'Failed';

  @override
  String toString() =>
      'CuaBrainResult(evaluate=$stepEvaluate, nextGoal=$nextGoal, analysis=${analysis.length > 50 ? '${analysis.substring(0, 50)}...' : analysis})';
}

/// CUA Brain prompt 构建器
class CuaBrainPrompts {
  /// 构建 Brain 的 system prompt
  ///
  /// [installedApps] 系统已安装的应用列表（动态生成）
  /// [currentTask] 用户原始任务描述
  /// [somMarkerCount] SOM 标记数量（>0 时启用 SOM 模式）
  /// [somMarkerList] SOM 标记列表文本（供 Brain 参考）
  static String buildSystemPrompt({
    required String currentTask,
    String? installedApps,
    int somMarkerCount = 0,
    String somMarkerList = '',
  }) {
    final appsInfo = installedApps != null && installedApps.isNotEmpty
        ? '\n- 可用应用: $installedApps'
        : '';

    // SOM 模式：截图上有编号标记，用 [N] 引用
    final somSection = somMarkerCount > 0
        ? '''

## SOM 标记模式
截图上有 $somMarkerCount 个红色编号圆圈标记，每个标记对应一个可交互元素。
请用 [N] 格式引用要操作的元素，不要使用坐标。

标记元素列表：
$somMarkerList

### next_goal 的 SOM 要求
- 点击/操作元素时用 [N] 标记号，不要写坐标
- 示例：
  - "点击 [15]" — 点击标记 15 的元素
  - "在 [3] 中输入 'hello world'" — 在标记 3 的输入框中输入
  - "按 cmd+回车" — 快捷键操作无需标记
  - "向下滚动一页" — 滚动操作无需标记'''
        : '';

    return '''你是一个 macOS 桌面操作 Agent 的 Brain（大脑）模块。
你的职责是：分析截图、判断上一步操作是否成功、决定下一步操作目标。

## 环境
- 操作系统: macOS
- 当前任务: $currentTask$appsInfo

## 输入
- 你会收到 1 张截图（带 SOM 标记的当前屏幕截图）
- 你还会收到上一步操作的文字描述（如果是第一步则为空）
$somSection
## 输出规则
你必须严格按以下 JSON 格式输出，不要输出任何其他内容：
{
  "analysis": "当前屏幕状态的详细分析",
  "step_evaluate": "Success 或 Failed（第一步写 N/A）",
  "ask_human": "需要用户确认的内容，或 No",
  "next_goal": "给 Actor 的具体操作指令"
}

## 判断 Success/Failed 的标准
- Success：截图显示的界面符合上一步操作的目标
  - 例如：上一步是"点击登录"，截图显示已登录 → Success
  - 页面正在加载（有加载指示器）→ 暂时标记 Success，但超过 5 步未完成则 Failed
- Failed：截图显示的不是预期结果
  - 例如：上一步是"点击登录"，但截图显示弹出了错误提示 → Failed
  - 上一步是"打开微信"，但截图显示其他应用 → Failed
- N/A：第一步操作，还没有上一步可以评估

## next_goal 的要求（${somMarkerCount > 0 ? 'SOM 模式' : '坐标模式'}）
- 必须是具体、可执行的操作指令（Actor 据此调用 cua 工具）
- 必须包含具体的文字内容（如果要输入文本），不能只写"输入消息"
${somMarkerCount > 0 ? '- 必须包含标记号 [N]（如果要点击元素），不要使用坐标' : '- 必须包含具体的坐标位置（如果要点击），坐标范围 0~1000'}
- 示例：
  ${somMarkerCount > 0 ? '- "点击 [15]"\n  - "在 [3] 中输入 \'hello world\'"\n  - "按 cmd+回车"\n  - "向下滚动一页"' : '- "点击搜索框 (500, 50)"\n  - "在搜索框输入 \'hello world\'"\n  - "按 cmd+回车"\n  - "向下滚动一页"\n  - "点击第一个搜索结果 (600, 200)"'}

## 重要提醒
- 如果需要登录，在 ask_human 中告知用户
- 如果当前页面不是预期的，在 analysis 中说明差异
- next_goal 只描述一个具体操作，不要描述多个操作''';
  }

  /// 构建 Brain 的用户消息（含截图和上一步操作信息）
  ///
  /// [previousAction] 上一步操作的描述（如 "点击了 (500, 300)"）
  /// [previousGoal] 上一步的目标（如 "点击登录按钮"）
  static String buildUserMessage({
    String? previousAction,
    String? previousGoal,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('请分析当前截图，判断操作结果并决定下一步。');

    if (previousAction != null || previousGoal != null) {
      buffer.writeln();
      buffer.writeln('## 上一步操作');
      if (previousGoal != null) buffer.writeln('- 目标: $previousGoal');
      if (previousAction != null) buffer.writeln('- 实际操作: $previousAction');
    }

    buffer.writeln();
    buffer.writeln('请按 JSON 格式输出分析结果。');
    return buffer.toString();
  }

  /// 构建 Brain 的用户消息（含两张截图的前后对比说明）
  static String buildCompareUserMessage({
    String? previousAction,
    String? previousGoal,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('请对比两张截图，判断操作结果并决定下一步。');
    buffer.writeln('（第 1 张 = 操作前，第 2 张 = 操作后）');

    if (previousAction != null || previousGoal != null) {
      buffer.writeln();
      buffer.writeln('## 上一步操作');
      if (previousGoal != null) buffer.writeln('- 目标: $previousGoal');
      if (previousAction != null) buffer.writeln('- 实际操作: $previousAction');
    }

    buffer.writeln();
    buffer.writeln('请按 JSON 格式输出分析结果。');
    return buffer.toString();
  }
}

/// 解析 Brain 的 JSON 输出
///
/// 容错处理：如果 LLM 输出的不是合法 JSON，尝试从文本中提取
CuaBrainResult parseBrainOutput(String rawOutput) {
  // 尝试直接解析 JSON
  try {
    final json = jsonDecode(rawOutput) as Map<String, dynamic>;
    return CuaBrainResult(
      analysis: (json['analysis'] as String?) ?? '',
      stepEvaluate: (json['step_evaluate'] as String?) ?? 'N/A',
      askHuman: (json['ask_human'] as String?) ?? 'No',
      nextGoal: (json['next_goal'] as String?) ?? '',
    );
  } catch (_) {}

  // 尝试提取 JSON 块
  final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(rawOutput);
  if (jsonMatch != null) {
    try {
      final json = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
      return CuaBrainResult(
        analysis: (json['analysis'] as String?) ?? '',
        stepEvaluate: (json['step_evaluate'] as String?) ?? 'N/A',
        askHuman: (json['ask_human'] as String?) ?? 'No',
        nextGoal: (json['next_goal'] as String?) ?? '',
      );
    } catch (_) {}
  }

  // JSON 解析失败：将整个输出作为 analysis，标记为 N/A
  debugPrint('⚠️ CUA Brain 输出解析失败，原文: ${rawOutput.length > 200 ? '${rawOutput.substring(0, 200)}...' : rawOutput}');
  return CuaBrainResult(
    analysis: rawOutput,
    stepEvaluate: 'N/A',
    askHuman: 'No',
    nextGoal: rawOutput,
  );
}

/// 构建 Actor 收到的 Brain 指令消息
///
/// 注入到 Actor 的对话上下文中，让主模型知道 Brain 的判断和目标
String buildActorBrainMessage(CuaBrainResult brain) {
  final buffer = StringBuffer();
  buffer.writeln('🧠 Brain 分析结果:');
  buffer.writeln('状态: ${brain.stepEvaluate}');
  if (brain.analysis.isNotEmpty) {
    buffer.writeln('分析: ${brain.analysis.length > 300 ? '${brain.analysis.substring(0, 300)}...' : brain.analysis}');
  }
  buffer.writeln('下一步目标: ${brain.nextGoal}');
  if (brain.isAskHuman) {
    buffer.writeln('⚠️ Brain 请求用户确认: ${brain.askHuman}');
  }
  return buffer.toString();
}
