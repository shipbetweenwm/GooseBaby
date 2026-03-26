import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'skill_base.dart';
import 'script_skill.dart';
import 'agent_skill.dart';
import 'shell_skill.dart';
import 'file_skill.dart';
import 'think_skill.dart';
import 'memory_skill.dart';
import 'schedule_task_skill.dart';
import 'scheduled_task.dart';
import 'web_skill.dart';
import 'batch_file_skill.dart';
import 'web_search_skill.dart';
import '../ai/agent/sub_agent_skill.dart';
import '../ai/agent/sub_agent_types.dart';
import '../ai/agent/agent_types.dart';
import '../ai/agent/agent_hooks.dart';
import '../ai/providers/llm_provider.dart';

/// 技能管理器
/// 负责管理和调度所有技能，内置技能从 skills/ 目录加载（OpenClaw 标准格式）
/// 支持从 ZIP 文件、文件夹动态导入技能
class SkillManager extends ChangeNotifier {
  final Map<String, GooseSkill> _skills = {};
  final Set<String> _disabledSkills = {};
  final Set<String> _externalSkillIds = {}; // 用户手动导入的外部技能 ID
  final Set<String> _builtinSkillIds = {};  // 内置技能 ID（从 skills/ 目录自动加载的）
  
  /// Sub-Agent 技能实例（需要运行时注入回调）
  SubAgentSkill? _subAgentSkill;
  
  /// Agent Teams 技能实例（需要运行时注入回调）
  AgentTeamsSkill? _agentTeamsSkill;
  
  /// Web 搜索技能实例（需要运行时注入 API Key）
  WebSearchSkill? _webSearchSkill;

  /// 内置技能目录路径（exe 同级的 skills/ 目录）
  String? _skillDir;

  /// 是否正在初始化（防止重入）
  bool _isInitializing = false;

  /// 是否已完成首次初始化
  bool _initialized = false;

  /// 初始化是否完成（UI 可据此显示加载状态）
  bool get isInitialized => _initialized;

  Map<String, GooseSkill> get skills => Map.unmodifiable(_skills);
  List<GooseSkill> get enabledSkills =>
      _skills.values.where((s) => !_disabledSkills.contains(s.id)).toList();

  /// 获取技能目录路径
  String get skillDir => _skillDir ?? '';

  /// 外部技能数量（用户手动导入的，不含内置）
  int get externalSkillCount => _externalSkillIds.length;

  SkillManager() {
    // 注册内置技能（代码级，不依赖外部文件）
    _registerBuiltinSkills();
    // 异步加载 skills/ 目录中的外部技能包
    _initSkillDir();
  }

  /// 注册代码级内置技能
  void _registerBuiltinSkills() {
    register(ThinkSkill());
    register(SaveMemorySkill());
    register(ShellExecSkill());
    register(WriteFileSkill());
    register(ReadFileSkill());
    register(ScheduleTaskSkill());
    register(WebInteractSkill()); // Web 浏览器交互技能
    register(BatchFileSkill());   // 批量文件操作技能
    
    // 注册 Web 搜索技能（需要运行时注入 API Key）
    _webSearchSkill = WebSearchSkill();
    register(_webSearchSkill!);
    
    // 注册 Sub-Agent 技能（需要在运行时注入回调）
    _subAgentSkill = SubAgentSkill();
    register(_subAgentSkill!);
    
    // 注册 Agent Teams 技能（需要在运行时注入回调）
    _agentTeamsSkill = AgentTeamsSkill(_subAgentSkill!);
    register(_agentTeamsSkill!);
    
    debugPrint('🦢 已注册内置技能: think, save_memory, shell_exec, write_file, read_file, schedule_task, web_interact, batch_file, web_search, spawn_sub_agent, spawn_agent_team');
  }
  
  /// 配置 Sub-Agent 技能的回调
  void configureSubAgentSkill({
    LLMProvider Function()? providerFactory,
    Future<ToolResult> Function(ToolCall)? executeToolCallback,
    List<Map<String, dynamic>> Function()? getToolsCallback,
    HookManager? hookManager,
  }) {
    _subAgentSkill?.providerFactory = providerFactory;
    _subAgentSkill?.executeToolCallback = executeToolCallback;
    _subAgentSkill?.getToolsCallback = getToolsCallback;
    _subAgentSkill?.hookManager = hookManager;
  }
  
  /// 配置 Agent Teams 技能的消息回调
  void configureAgentTeamsSkill({
    void Function(TeamMessage message)? onMessage,
  }) {
    _agentTeamsSkill?.onMessage = onMessage;
  }
  
  /// 配置 Web 搜索技能的 API Key
  void configureWebSearchSkill(String apiKey) {
    _webSearchSkill?.apiKey = apiKey;
  }

  /// 获取 SaveMemorySkill 实例（用于外部注入 MemoryManager）
  SaveMemorySkill? get saveMemorySkill {
    final skill = _skills['save_memory'];
    return skill is SaveMemorySkill ? skill : null;
  }

  /// 获取 ScheduleTaskSkill 实例（用于外部注入 ScheduledTaskManager）
  ScheduleTaskSkill? get scheduleTaskSkill {
    final skill = _skills['schedule_task'];
    return skill is ScheduleTaskSkill ? skill : null;
  }

  /// 注入 ScheduledTaskManager 到 ScheduleTaskSkill
  void setTaskManager(ScheduledTaskManager taskManager) {
    scheduleTaskSkill?.taskManager = taskManager;
  }

  /// 初始化技能目录并加载内置技能
  Future<void> _initSkillDir() async {
    if (_isInitializing) return;
    _isInitializing = true;

    try {
      final exePath = Platform.resolvedExecutable;
      final exeDir = p.dirname(exePath);
      _skillDir = p.join(exeDir, 'skills');
      debugPrint('🦢 内置技能目录: $_skillDir');

      final dir = Directory(_skillDir!);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        debugPrint('🦢 已创建技能目录: $_skillDir');
      }

      await loadSkillsFromDir();
    } catch (e, st) {
      debugPrint('🦢 初始化技能目录失败: $e\n$st');
    } finally {
      _isInitializing = false;
      _initialized = true;
      notifyListeners();
    }
  }

  /// 是否正在加载（防止 loadSkillsFromDir 重入）
  bool _isLoadingSkills = false;

  /// 从技能目录加载所有技能（ZIP + 目录）
  Future<int> loadSkillsFromDir() async {
    if (_skillDir == null) return 0;
    // 防止重入：如果正在加载，直接返回当前数量
    if (_isLoadingSkills) return _skills.length;
    _isLoadingSkills = true;

    try {
      final dir = Directory(_skillDir!);
      if (!await dir.exists()) return 0;

      final newSkills = <GooseSkill>[];

      await for (final entity in dir.list()) {
        try {
          if (entity is File && entity.path.toLowerCase().endsWith('.zip')) {
            final skills = await SkillLoader.loadFromZip(entity.path);
            newSkills.addAll(skills);
          } else if (entity is Directory) {
            final skills = await SkillLoader.loadFromPack(entity.path);
            newSkills.addAll(skills);
          }
        } catch (e) {
          debugPrint('🦢 加载技能条目失败: ${entity.path} - $e');
        }
      }

      // 原子替换，避免 UI 并发迭代时出问题
      // 注意：只重置内置技能，保留外部导入的技能
      _skills.removeWhere((id, _) => _builtinSkillIds.contains(id));
      _builtinSkillIds.clear();
      for (final s in newSkills) {
        _skills[s.id] = s;
        _builtinSkillIds.add(s.id);
      }

      debugPrint('🦢 已加载 ${_skills.length} 个技能（内置 ${_builtinSkillIds.length}，外部 ${_externalSkillIds.length}）');
      notifyListeners();
      return _skills.length;
    } catch (e, st) {
      debugPrint('🦢 加载技能目录失败: $e\n$st');
      return 0;
    } finally {
      _isLoadingSkills = false;
    }
  }

  /// 从 ZIP 文件导入技能到 skills 目录
  /// 将 ZIP 复制到 skills/ 目录，然后加载
  Future<int> importFromZip(String zipPath) async {
    try {
      if (_skillDir == null) return 0;

      final zipFile = File(zipPath);
      if (!await zipFile.exists()) return 0;

      // 复制 ZIP 到技能目录
      final destPath = p.join(_skillDir!, p.basename(zipPath));
      await zipFile.copy(destPath);
      debugPrint('🦢 已复制技能包: ${p.basename(zipPath)}');

      // 加载该 ZIP（追加到现有技能列表）
      try {
        final skills = await SkillLoader.loadFromZip(destPath);
        for (final s in skills) {
          _skills[s.id] = s;
          _externalSkillIds.add(s.id);
        }

        if (skills.isNotEmpty) {
          debugPrint('🦢 从 ZIP 导入 ${skills.length} 个技能');
          // 删除已解压的 ZIP 文件，避免下次启动时重复加载
          try {
            await File(destPath).delete();
            debugPrint('🦢 已删除已解压的 ZIP: ${p.basename(zipPath)}');
          } catch (e) {
            debugPrint('🦢 删除 ZIP 文件失败: $e');
          }
          notifyListeners();
          return skills.length;
        }
      } catch (e) {
        debugPrint('🦢 加载导入的 ZIP 失败: $e');
      }

      return 0;
    } catch (e) {
      debugPrint('🦢 从 ZIP 导入技能失败: $e');
      return 0;
    }
  }

  /// 从文件夹导入技能到 skills 目录
  /// 将文件夹复制到 skills/ 目录，然后加载
  Future<int> importFromFolder(String folderPath) async {
    try {
      if (_skillDir == null) {
        debugPrint('🦢 导入失败: 技能目录未初始化');
        return 0;
      }

      final srcDir = Directory(folderPath);
      if (!await srcDir.exists()) {
        debugPrint('🦢 导入失败: 源目录不存在: $folderPath');
        return 0;
      }

      // 快速检查：源目录中是否有 SKILL.md 或 manifest.json
      final skillMd = File('$folderPath/SKILL.md');
      final manifest = File('$folderPath/manifest.json');
      final hasSkillMd = await skillMd.exists();
      final hasManifest = await manifest.exists();
      if (!hasSkillMd && !hasManifest) {
        // 没有标识文件，可能是用户选错了目录，快速退出
        debugPrint('🦢 导入失败: 文件夹中未找到 SKILL.md 或 manifest.json');
        return 0;
      }

      // 重置复制计数器
      _copyFileCount = 0;
      _copyTotalSize = 0;

      final folderName = p.basename(folderPath);
      final destPath = p.join(_skillDir!, folderName);
      final destDir = Directory(destPath);

      if (await destDir.exists()) {
        // 目标已存在，删除后重新复制（确保内容是最新的）
        debugPrint('🦢 技能目录已存在，删除后重新导入: $folderName');
        await destDir.delete(recursive: true);
      }
      debugPrint('🦢 开始复制目录: $folderPath → $destPath');
      await _copyDirectory(srcDir, destDir);
      debugPrint('🦢 已复制技能目录: $folderName (${_copyFileCount} 文件 / ${(_copyTotalSize / 1024).toStringAsFixed(0)} KB)');

      // 从目标目录加载（追加到现有技能列表）
      try {
        final skills = await SkillLoader.loadFromPack(destPath);
        for (final s in skills) {
          _skills[s.id] = s;
          _externalSkillIds.add(s.id);
        }

        if (skills.isNotEmpty) {
          debugPrint('🦢 从文件夹导入 ${skills.length} 个技能');
          notifyListeners();
          return skills.length;
        }
      } catch (e, st) {
        debugPrint('🦢 加载导入的目录技能失败: $e\n$st');
      }

      return 0;
    } catch (e, st) {
      debugPrint('🦢 从文件夹导入技能失败: $e\n$st');
      return 0;
    }
  }

  /// 递归复制目录（跳过 symlink，防止循环引用导致 Stack Overflow 闪退）
  /// [maxFiles] 最大文件数量限制，防止 OOM
  /// [maxTotalSize] 最大总字节数限制
  Future<void> _copyDirectory(Directory source, Directory destination, {
    int depth = 0,
    int maxFiles = 2000,
    int maxTotalSize = 100 * 1024 * 1024,
  }) async {
    // 防御：限制递归深度，防止意外的深层目录或 junction 循环
    if (depth > 20) {
      debugPrint('🦢 跳过过深层目录: ${source.path} (depth=$depth)');
      return;
    }
    if (_copyFileCount >= maxFiles || _copyTotalSize >= maxTotalSize) {
      debugPrint('🦢 复制限制已达 (${_copyFileCount} 文件 / ${(_copyTotalSize / 1024 / 1024).toStringAsFixed(1)} MB)，跳过: ${source.path}');
      return;
    }

    await destination.create(recursive: true);
    // followLinks: false 防止 Windows junction/symlink 循环引用
    await for (final entity in source.list(recursive: false, followLinks: false)) {
      try {
        if (_copyFileCount >= maxFiles || _copyTotalSize >= maxTotalSize) break;

        if (entity is File) {
          final destFile = File(p.join(destination.path, p.basename(entity.path)));
          final fileSize = await entity.length();
          if (_copyTotalSize + fileSize > maxTotalSize) {
            debugPrint('🦢 跳过大文件: ${entity.path} (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');
            continue;
          }
          await entity.copy(destFile.path);
          _copyFileCount++;
          _copyTotalSize += fileSize;
        } else if (entity is Directory) {
          final destSubDir = Directory(p.join(destination.path, p.basename(entity.path)));
          await _copyDirectory(entity, destSubDir, depth: depth + 1, maxFiles: maxFiles, maxTotalSize: maxTotalSize);
        }
      } catch (e) {
        debugPrint('🦢 复制文件失败: ${entity.path} - $e');
      }
    }
  }

  /// 复制过程中的文件计数器和大小累加器（importFromFolder 入口重置）
  int _copyFileCount = 0;
  int _copyTotalSize = 0;

  /// 热重载所有技能
  Future<int> reloadSkills() async {
    debugPrint('🦢 热重载技能...');
    return await loadSkillsFromDir();
  }

  /// 从 JSON 字符串动态注册一个技能
  bool registerFromJson(String jsonString) {
    final skill = SkillLoader.loadFromString(jsonString);
    if (skill == null) return false;

    _skills[skill.id] = skill;
    _externalSkillIds.add(skill.id);
    notifyListeners();
    debugPrint('🦢 动态注册技能: ${skill.name} (${skill.id})');
    return true;
  }

  /// 注册一个技能
  void register(GooseSkill skill) {
    _skills[skill.id] = skill;
    notifyListeners();
  }

  /// 注销一个技能（仅从内存中移除，重启后会重新加载）
  void unregister(String skillId) {
    _skills.remove(skillId);
    _disabledSkills.remove(skillId);
    _externalSkillIds.remove(skillId);
    _builtinSkillIds.remove(skillId);
    notifyListeners();
  }

  /// 永久删除一个技能（删除源文件 + 从内存中移除）
  /// [skillId] 技能 ID
  /// 返回是否成功删除（源文件是否被删除）
  Future<bool> deleteSkill(String skillId) async {
    final skill = _skills[skillId];
    if (skill == null) return false;

    bool filesDeleted = false;

    // 尝试删除技能源文件目录
    try {
      String? sourceDir = _findSkillSourceDir(skill);
      if (sourceDir != null) {
        final dir = Directory(sourceDir);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
          debugPrint('🦢 已删除技能目录: $sourceDir');
          filesDeleted = true;
        }
      }
    } catch (e, st) {
      debugPrint('🦢 删除技能文件失败: $skillId - $e\n$st');
    }

    // 从内存中移除
    unregister(skillId);

    return filesDeleted;
  }

  /// 根据技能对象查找其源文件目录
  /// AgentSkill 有 sourcePath 字段；ScriptSkill 有 sourcePath 和 packName
  String? _findSkillSourceDir(GooseSkill skill) {
    if (skill is AgentSkill && skill.sourcePath != null) {
      return skill.sourcePath;
    }
    if (skill is ScriptSkill && skill.sourcePath != null) {
      return skill.sourcePath;
    }
    return null;
  }

  /// 判断是否为外部导入技能
  bool isExternalSkill(String skillId) => _externalSkillIds.contains(skillId);

  /// 获取所有已启用的 Agent 技能
  List<AgentSkill> get enabledAgentSkills => enabledSkills
      .whereType<AgentSkill>()
      .toList();

  /// Agent 技能数量
  int get agentSkillCount => _skills.values.whereType<AgentSkill>().length;

  /// 获取所有已启用 Agent 技能的 prompt 注入文本（OpenClaw Level 1 渐进式披露）
  /// 仅列出 name + description，让 LLM 判断是否需要 activate
  String getAgentSkillsPrompt() {
    final agentSkills = enabledAgentSkills;
    if (agentSkills.isEmpty) return '';

    final sb = StringBuffer();
    sb.writeln('\n# 可用专业技能');
    sb.writeln('当主人的任务匹配以下技能时，先调用 `activate_skill` 加载完整说明，再按说明用工具实际执行。');

    for (final skill in agentSkills) {
      sb.write(skill.getPromptInjection());
      sb.writeln();
    }

    return sb.toString();
  }

  /// 启用/禁用技能
  void setEnabled(String skillId, bool enabled) {
    if (enabled) {
      _disabledSkills.remove(skillId);
    } else {
      _disabledSkills.add(skillId);
    }
    notifyListeners();
  }

  /// 获取技能
  GooseSkill? getSkill(String skillId) => _skills[skillId];

  /// 执行技能
  /// [onOutput] 可选的流式输出回调，用于实时推送命令执行过程中的输出
  Future<SkillResult> execute(String skillId, Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    final skill = _skills[skillId];
    if (skill == null) {
      return SkillResult.fail('未找到技能: $skillId');
    }
    if (_disabledSkills.contains(skillId)) {
      return SkillResult.fail('技能 ${skill.name} 已被禁用');
    }

    try {
      debugPrint('🦢 执行技能: ${skill.name} ($skillId) 参数: $args');
      final result = await skill.execute(args, onOutput: onOutput);
      debugPrint('🦢 技能执行完成: ${result.success ? "✅" : "❌"} ${result.message}');
      return result;
    } catch (e) {
      debugPrint('🦢 技能执行异常: $e');
      return SkillResult.fail('技能执行出错: $e');
    }
  }

  /// 生成所有已启用技能的 Function Calling tools 列表
  /// AgentSkill 不注册为 function tool（遵循 OpenClaw 规范），仅注册可执行类技能
  List<Map<String, dynamic>> toFunctionTools() {
    final tools = <Map<String, dynamic>>[];

    // 注册可执行类技能（ScriptSkill、ShellExecSkill 等）
    for (final s in enabledSkills) {
      if (s is! AgentSkill) {
        tools.add(s.toFunctionTool());
      }
    }

    // 如果有已启用的 Agent 技能，注册 activate_skill 专用工具
    if (enabledAgentSkills.isNotEmpty) {
      tools.add(_buildActivateSkillTool());
    }

    return tools;
  }

  /// 构建 activate_skill 专用工具定义（遵循 OpenClaw 规范的专用工具激活模式）
  Map<String, dynamic> _buildActivateSkillTool() {
    final agentSkills = enabledAgentSkills;
    final skillNames = agentSkills.map((s) => s.name).toList();
    // 构建枚举列表，限制 LLM 只能选择有效的技能名
    final enumValues = skillNames.length <= 50 ? skillNames : null;

    return {
      'type': 'function',
      'function': {
        'name': 'activate_skill',
        'description': '加载专业技能的完整使用说明。'
            '当用户任务匹配某个技能时调用，系统返回 <skill_content> 包含使用说明和可用脚本。'
            '加载后你必须用 write_file + shell_exec 实际执行，不能假装执行。'
            '如果说明中有 scripts/ 脚本，可直接用 shell_exec command 模式调用。',
        'parameters': {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': '要激活的技能名称',
              if (enumValues != null) 'enum': enumValues,
            },
          },
          'required': ['name'],
        },
      },
    };
  }

  /// 激活一个 Agent 技能，返回其 Level 2 完整说明内容
  /// 返回 SkillResult，message 中包含 SKILL.md 正文 + 脚本列表 + 资源列表
  Future<SkillResult> activateSkill(String skillName) async {
    AgentSkill? skill;
    for (final s in enabledAgentSkills) {
      if (s.name == skillName) {
        skill = s;
        break;
      }
    }

    if (skill == null) {
      return SkillResult.fail('未找到技能: $skillName。可用技能: ${enabledAgentSkills.map((s) => s.name).join(", ")}');
    }

    // Level 2: 完整使用说明
    final level2 = skill.getLevel2Prompt();
    if (level2.isEmpty) {
      return SkillResult.fail('技能 $skillName 没有使用说明内容');
    }

    // 用 XML 标签包裹（OpenClaw 推荐的结构化包装格式）
    final wrapped = '<skill_content name="${skill.name}">\n$level2\n</skill_content>';

    return SkillResult.ok(wrapped, data: {
      'skillName': skill.name,
      'skillId': skill.id,
      'sourcePath': skill.sourcePath,
    });
  }

  /// 判断 skillId 是否为 activate_skill（特殊工具，不走 execute 流程）
  bool isActivateSkillTool(String skillId) => skillId == 'activate_skill';

  /// 根据分类获取技能（返回快照，防止并发修改）
  Map<String, List<GooseSkill>> getSkillsByCategory() {
    final map = <String, List<GooseSkill>>{};
    // 使用 List.from 创建快照，防止遍历期间 _skills 被修改
    final snapshot = _skills.values.toList();
    for (final skill in snapshot) {
      map.putIfAbsent(skill.category, () => []).add(skill);
    }
    return map;
  }
}
