import 'package:flutter/foundation.dart';
import 'skill_base.dart';
import '../ai/mcp/mcp.dart';
import '../ai/agent/agent_types.dart';

/// MCP 工具调用技能
/// 
/// 这个技能是特殊的"元技能"，它不处理固定工具，
/// 而是动态注入所有已连接 MCP 服务器的工具。
/// 
/// 工具命名规则：`mcp__{server}__{tool}`
/// 例如：`mcp__filesystem__read_file`
class McpToolSkill extends GooseSkill {
  @override
  String get id => 'mcp_tools';
  
  @override
  String get name => 'MCP 工具';
  
  @override
  String get description => '通过 MCP 协议连接的外部工具';
  
  @override
  String get icon => '🔌';
  
  @override
  String get category => '系统';
  
  @override
  List<SkillParam> get params => [];

  /// 是否应该处理该工具名
  bool shouldHandleTool(String toolName) {
    // 处理所有 mcp__ 前缀的工具
    return toolName.startsWith('mcp__');
  }

  /// 获取动态工具定义
  List<Map<String, dynamic>> getToolDefinitions() {
    // 动态获取所有 MCP 工具，并添加 mcp__ 前缀
    final mcpTools = McpService.instance.allTools;
    final definitions = <Map<String, dynamic>>[];
    
    // 按服务器分组，生成带前缀的工具定义
    for (final entry in McpService.instance.servers.entries) {
      final serverName = entry.key;
      final client = entry.value;
      
      for (final tool in client.tools) {
        // 工具名格式：mcp__{server}__{tool}
        final prefixedName = 'mcp__${serverName}__${tool.name}';
        
        definitions.add({
          'type': 'function',
          'function': {
            'name': prefixedName,
            'description': '[${serverName}] ${tool.description ?? tool.name}',
            'parameters': tool.inputSchema ?? {'type': 'object', 'properties': {}},
          },
        });
      }
    }
    
    return definitions;
  }

  /// 执行 MCP 工具
  Future<ToolResult> executeMcpTool(
    String toolName,
    Map<String, dynamic> arguments, {
    void Function(String line)? onOutput,
  }) async {
    if (!toolName.startsWith('mcp__')) {
      return ToolResult(
        toolCallId: '',
        content: '不是 MCP 工具: $toolName',
        isError: true,
      );
    }
    
    // 解析工具名：mcp__{server}__{tool}
    final parts = toolName.split('__');
    if (parts.length < 3) {
      return ToolResult(
        toolCallId: '',
        content: '无效的 MCP 工具名格式: $toolName',
        isError: true,
      );
    }
    
    final serverName = parts[1];
    final actualToolName = parts.sublist(2).join('__');
    
    debugPrint('🔌 MCP 工具调用: server=$serverName, tool=$actualToolName');
    
    // 检查服务器是否存在
    final client = McpService.instance.servers[serverName];
    if (client == null) {
      return ToolResult(
        toolCallId: '',
        content: 'MCP 服务器未连接: $serverName',
        isError: true,
      );
    }
    
    // 检查工具是否存在
    final toolExists = client.tools.any((t) => t.name == actualToolName);
    if (!toolExists) {
      return ToolResult(
        toolCallId: '',
        content: 'MCP 工具不存在: $actualToolName (服务器: $serverName)',
        isError: true,
      );
    }
    
    try {
      // 调用 MCP 工具
      final result = await McpService.instance.callTool(actualToolName, arguments);
      
      // 提取文本内容
      final textContent = result.textContent;
      
      return ToolResult(
        toolCallId: '',
        content: textContent,
        isError: result.isError == true,
      );
    } catch (e) {
      debugPrint('🔌 MCP 工具调用失败: $e');
      return ToolResult(
        toolCallId: '',
        content: 'MCP 工具调用失败: $e',
        isError: true,
      );
    }
  }

  @override
  Future<SkillResult> execute(Map<String, dynamic> args, {void Function(String line)? onOutput}) async {
    // MCP 工具通过 executeMcpTool 方法执行，不通过这里
    return SkillResult.fail('MCP 工具请使用 executeMcpTool 方法');
  }

  /// 获取使用指南
  String getUsageGuide() {
    final buffer = StringBuffer();
    buffer.writeln('## MCP 工具');
    buffer.writeln();
    buffer.writeln('MCP (Model Context Protocol) 让鹅宝可以使用外部工具。');
    buffer.writeln('工具命名规则: `mcp__{服务器名}__{工具名}`');
    buffer.writeln();
    
    // 列出所有已连接的服务器和工具
    if (McpService.instance.hasServers) {
      buffer.writeln('### 已连接的服务器');
      for (final entry in McpService.instance.servers.entries) {
        final serverName = entry.key;
        final client = entry.value;
        buffer.writeln('- **$serverName**: ${client.tools.length} 个工具');
        for (final tool in client.tools.take(5)) {
          buffer.writeln('  - `mcp__${serverName}__${tool.name}`: ${tool.description ?? ''}');
        }
        if (client.tools.length > 5) {
          buffer.writeln('  - ... 还有 ${client.tools.length - 5} 个工具');
        }
      }
    } else {
      buffer.writeln('当前没有已连接的 MCP 服务器。');
      buffer.writeln('请在设置中添加 MCP 服务器。');
    }
    
    return buffer.toString();
  }
}
