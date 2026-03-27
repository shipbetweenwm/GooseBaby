import 'package:flutter/foundation.dart';
import 'skills/skill_manager.dart';
import 'skills/skill_base.dart';
import 'skills/agent_skill.dart';
import 'mcp/mcp.dart';

/// 任务类型枚举
enum TaskType {
  chat,           // 纯聊天
  coding,         // 编码任务
  fileOperation,  // 文件操作
  webSearch,      // 网络搜索
  webInteract,    // 网页交互
  shellCommand,   // 命令执行
  dataAnalysis,   // 数据分析
  officeDoc,      // 办公文档（PPT/Excel/Word）
  schedule,       // 定时任务
  mcpTool,        // MCP 工具
  memory,         // 记忆相关
  unknown,        // 未知
}

/// 任务分析器
/// 根据用户请求分析任务类型，用于选择性注入提示词
class TaskAnalyzer {
  // 编码相关关键词
  static const _codingKeywords = [
    '代码', 'code', '编程', '编程', '写代码', '写个', '实现', '函数', 'function',
    '类', 'class', '方法', 'method', '变量', 'variable', '脚本', 'script',
    'python', 'javascript', 'dart', 'java', 'go', 'rust', 'flutter',
    '调试', 'debug', '修复', 'fix', 'bug', '错误', 'error', '报错',
    '运行', 'run', '执行', 'execute', '编译', 'compile',
  ];
  
  // 文件操作关键词
  static const _fileKeywords = [
    '文件', 'file', '读取', 'read', '写入', 'write', '创建', 'create',
    '删除', 'delete', '移动', 'move', '复制', 'copy', '重命名', 'rename',
    '目录', 'directory', '文件夹', 'folder', '路径', 'path',
    '批量', 'batch', '重命名', 'rename', '整理', 'organize',
  ];
  
  // 网络搜索关键词
  static const _webSearchKeywords = [
    '搜索', 'search', '查', '找', '查找', '查询', '搜索一下',
    'google', '百度', 'bing', '网上', '互联网',
    '最新', '新闻', '资讯', '天气', '股价', '汇率',
  ];
  
  // 网页交互关键词
  static const _webInteractKeywords = [
    '网页', 'website', '网站', '打开', 'open', '访问', 'visit',
    '浏览器', 'browser', '登录', 'login', '填写', 'fill', '表单', 'form',
    '点击', 'click', '截图', 'screenshot', '抓取', 'scrape',
    '自动化', 'automate', '测试', 'test',
  ];
  
  // 命令执行关键词
  static const _shellKeywords = [
    '命令', 'command', 'cmd', '终端', 'terminal', 'shell',
    '执行', 'execute', '运行', 'run', '安装', 'install',
    'pip', 'npm', 'git', 'docker', '编译', 'build',
  ];
  
  // 数据分析关键词
  static const _dataAnalysisKeywords = [
    '数据', 'data', '分析', 'analysis', '统计', 'statistics',
    '图表', 'chart', '可视化', 'visualization', '报表', 'report',
    'csv', 'excel', 'json', 'xml', '解析', 'parse',
    '处理', 'process', '转换', 'transform', '格式', 'format',
  ];
  
  // 办公文档关键词
  static const _officeDocKeywords = [
    'ppt', 'powerpoint', '幻灯片', 'slide', '演示',
    'excel', '表格', 'spreadsheet', 'xlsx',
    'word', '文档', 'document', 'docx',
    'pdf', '报告', 'report', '文档',
  ];
  
  // 定时任务关键词
  static const _scheduleKeywords = [
    '定时', 'schedule', '提醒', 'remind', '闹钟', 'alarm',
    '每天', 'daily', '每周', 'weekly', '每月', 'monthly',
    '提醒我', '提醒一下', '到时候', '时间到',
  ];
  
  // MCP 工具关键词
  static const _mcpKeywords = [
    'mcp', '外部工具', 'extension', '插件', 'plugin',
    'filesystem', 'database', 'api', '连接', 'connect',
  ];
  
  // 记忆相关关键词
  static const _memoryKeywords = [
    '记住', 'remember', '记得', '记忆', 'memory',
    '别忘了', '不要忘记', '以后', '下次',
    '我的名字', '我喜欢', '我的偏好',
  ];
  
  /// 分析用户请求的任务类型
  static List<TaskType> analyze(String userRequest) {
    final lowerRequest = userRequest.toLowerCase();
    final types = <TaskType>[];
    
    // 编码任务
    if (_codingKeywords.any((k) => lowerRequest.contains(k))) {
      types.add(TaskType.coding);
    }
    
    // 文件操作
    if (_fileKeywords.any((k) => lowerRequest.contains(k))) {
      types.add(TaskType.fileOperation);
    }
    
    // 网络搜索
    if (_webSearchKeywords.any((k) => lowerRequest.contains(k))) {
      types.add(TaskType.webSearch);
    }
    
    // 网页交互
    if (_webInteractKeywords.any((k) => lowerRequest.contains(k))) {
      types.add(TaskType.webInteract);
    }
    
    // 命令执行
    if (_shellKeywords.any((k) => lowerRequest.contains(k))) {
      types.add(TaskType.shellCommand);
    }
    
    // 数据分析
    if (_dataAnalysisKeywords.any((k) => lowerRequest.contains(k))) {
      types.add(TaskType.dataAnalysis);
    }
    
    // 办公文档
    if (_officeDocKeywords.any((k) => lowerRequest.contains(k))) {
      types.add(TaskType.officeDoc);
    }
    
    // 定时任务
    if (_scheduleKeywords.any((k) => lowerRequest.contains(k))) {
      types.add(TaskType.schedule);
    }
    
    // MCP 工具
    if (_mcpKeywords.any((k) => lowerRequest.contains(k))) {
      types.add(TaskType.mcpTool);
    }
    
    // 记忆相关
    if (_memoryKeywords.any((k) => lowerRequest.contains(k))) {
      types.add(TaskType.memory);
    }
    
    // 如果没有匹配任何类型，默认为聊天
    if (types.isEmpty) {
      types.add(TaskType.chat);
    }
    
    return types;
  }
  
  /// 判断是否需要注入特定技能
  static bool shouldInjectSkill(TaskType taskType, String skillId) {
    switch (taskType) {
      case TaskType.coding:
        return ['shell_exec', 'write_file', 'read_file', 'think'].contains(skillId);
      case TaskType.fileOperation:
        return ['read_file', 'write_file', 'batch_file'].contains(skillId);
      case TaskType.webSearch:
        return ['web_search'].contains(skillId);
      case TaskType.webInteract:
        return ['web_interact', 'web_fetch', 'browser_automation'].contains(skillId);
      case TaskType.shellCommand:
        return ['shell_exec'].contains(skillId);
      case TaskType.dataAnalysis:
        return ['shell_exec', 'write_file', 'read_file'].contains(skillId);
      case TaskType.officeDoc:
        return ['shell_exec', 'write_file'].contains(skillId);
      case TaskType.schedule:
        return ['schedule_task'].contains(skillId);
      case TaskType.mcpTool:
        return skillId.startsWith('mcp__');
      case TaskType.memory:
        return ['save_memory'].contains(skillId);
      case TaskType.chat:
      case TaskType.unknown:
        return false;
    }
  }
}

/// 任务感知提示词注入器
/// 根据任务类型选择性注入相关的技能提示词
class TaskAwarePromptInjector {
  final SkillManager _skillManager;
  
  TaskAwarePromptInjector(this._skillManager);
  
  /// 根据用户请求生成任务感知的工具提示
  /// [userRequest] 用户请求
  /// [allTools] 是否注入所有工具（默认根据任务类型选择性注入）
  String generateToolPrompt(String userRequest, {bool allTools = false}) {
    final taskTypes = allTools ? TaskType.values.toList() : TaskAnalyzer.analyze(userRequest);
    
    debugPrint('🎯 任务分析: $taskTypes');
    
    final buffer = StringBuffer();
    
    // 1. 始终注入 think 和 save_memory（核心工具）
    buffer.writeln('\n### 核心工具');
    buffer.writeln('1. **think**（thought）→ 复杂任务时调用，记录推理过程');
    buffer.writeln('2. **save_memory**（content）→ 需要跨会话记住信息时调用');
    
    // 2. 根据任务类型注入相关工具
    final injectedTools = <String>{'think', 'save_memory'};
    
    for (final taskType in taskTypes) {
      switch (taskType) {
        case TaskType.coding:
          if (!injectedTools.contains('shell_exec')) {
            buffer.writeln('3. **shell_exec**（command）→ 执行命令/脚本');
            injectedTools.add('shell_exec');
          }
          if (!injectedTools.contains('write_file')) {
            buffer.writeln('4. **write_file**（path, content）→ 写入文件');
            injectedTools.add('write_file');
          }
          if (!injectedTools.contains('read_file')) {
            buffer.writeln('5. **read_file**（path）→ 读取文件');
            injectedTools.add('read_file');
          }
          break;
          
        case TaskType.fileOperation:
          if (!injectedTools.contains('read_file')) {
            buffer.writeln('3. **read_file**（path）→ 读取文件');
            injectedTools.add('read_file');
          }
          if (!injectedTools.contains('write_file')) {
            buffer.writeln('4. **write_file**（path, content）→ 写入文件');
            injectedTools.add('write_file');
          }
          if (!injectedTools.contains('batch_file')) {
            buffer.writeln('5. **batch_file**（action, paths）→ 批量文件操作');
            injectedTools.add('batch_file');
          }
          break;
          
        case TaskType.webSearch:
          if (!injectedTools.contains('web_search')) {
            buffer.writeln('3. **web_search**（query）→ 网络搜索');
            injectedTools.add('web_search');
          }
          break;
          
        case TaskType.webInteract:
          if (!injectedTools.contains('web_interact')) {
            buffer.writeln('3. **web_interact**（action, url, ...）→ 网页交互');
            injectedTools.add('web_interact');
          }
          if (!injectedTools.contains('browser_automation')) {
            buffer.writeln('4. **browser_automation**（action, ...）→ 浏览器自动化');
            injectedTools.add('browser_automation');
          }
          break;
          
        case TaskType.shellCommand:
          if (!injectedTools.contains('shell_exec')) {
            buffer.writeln('3. **shell_exec**（command）→ 执行命令');
            injectedTools.add('shell_exec');
          }
          break;
          
        case TaskType.dataAnalysis:
        case TaskType.officeDoc:
          if (!injectedTools.contains('shell_exec')) {
            buffer.writeln('3. **shell_exec**（command）→ 执行 Python 脚本');
            injectedTools.add('shell_exec');
          }
          if (!injectedTools.contains('write_file')) {
            buffer.writeln('4. **write_file**（path, content）→ 写入脚本/文件');
            injectedTools.add('write_file');
          }
          break;
          
        case TaskType.schedule:
          if (!injectedTools.contains('schedule_task')) {
            buffer.writeln('3. **schedule_task**（action, title, prompt, ...）→ 定时任务');
            injectedTools.add('schedule_task');
          }
          break;
          
        case TaskType.memory:
          // save_memory 已在核心工具中注入
          break;
          
        case TaskType.mcpTool:
          // 注入 MCP 工具说明
          if (McpService.instance.hasServers) {
            buffer.writeln('\n### MCP 工具');
            buffer.writeln('工具命名: `mcp__{服务器名}__{工具名}`');
            for (final entry in McpService.instance.servers.entries) {
              final serverName = entry.key;
              final client = entry.value;
              buffer.writeln('\n**$serverName** (${client.tools.length} 个工具):');
              for (final tool in client.tools.take(5)) {
                buffer.writeln('- `mcp__${serverName}__${tool.name}`: ${tool.description ?? ''}');
              }
            }
          }
          break;
          
        case TaskType.chat:
        case TaskType.unknown:
          // 纯聊天不需要额外工具
          break;
      }
    }
    
    // 3. 如果有 Agent 技能且任务相关，注入技能列表
    final agentSkills = _skillManager.enabledAgentSkills;
    if (agentSkills.isNotEmpty && _shouldInjectAgentSkills(taskTypes, userRequest)) {
      buffer.writeln('\n### 专业技能');
      buffer.writeln('调用 `activate_skill` 加载完整说明：');
      for (final skill in agentSkills) {
        buffer.writeln('- **${skill.name}**: ${skill.description}');
      }
    }
    
    return buffer.toString();
  }
  
  /// 判断是否需要注入 Agent 技能列表
  bool _shouldInjectAgentSkills(List<TaskType> taskTypes, String userRequest) {
    // 如果任务涉及编码、数据分析、办公文档，注入技能列表
    return taskTypes.any((t) => [
      TaskType.coding,
      TaskType.dataAnalysis,
      TaskType.officeDoc,
    ].contains(t));
  }
  
  /// 获取任务类型对应的核心工具列表
  List<String> getCoreToolsForTask(List<TaskType> taskTypes) {
    final tools = <String>{'think', 'save_memory'};
    
    for (final taskType in taskTypes) {
      switch (taskType) {
        case TaskType.coding:
        case TaskType.shellCommand:
        case TaskType.dataAnalysis:
        case TaskType.officeDoc:
          tools.addAll(['shell_exec', 'write_file', 'read_file']);
          break;
        case TaskType.fileOperation:
          tools.addAll(['read_file', 'write_file', 'batch_file']);
          break;
        case TaskType.webSearch:
          tools.add('web_search');
          break;
        case TaskType.webInteract:
          tools.addAll(['web_interact', 'browser_automation']);
          break;
        case TaskType.schedule:
          tools.add('schedule_task');
          break;
        case TaskType.mcpTool:
          // MCP 工具是动态的，不需要预定义
          break;
        case TaskType.memory:
        case TaskType.chat:
        case TaskType.unknown:
          break;
      }
    }
    
    return tools.toList();
  }
}
