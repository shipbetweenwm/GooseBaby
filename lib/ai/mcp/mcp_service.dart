import 'dart:async';
import 'package:flutter/foundation.dart';
import 'mcp_client.dart';
import 'mcp_types.dart';
import '../../utils/storage.dart';

/// MCP 服务器配置
class McpServerConfig {
  final String command;
  final List<String> args;
  final Map<String, String>? env;
  final bool enabled;

  McpServerConfig({
    required this.command,
    this.args = const [],
    this.env,
    this.enabled = true,
  });

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    return McpServerConfig(
      command: json['command'] as String? ?? '',
      args: (json['args'] as List?)?.map((e) => e.toString()).toList() ?? [],
      env: json['env'] != null
          ? Map<String, String>.from(json['env'] as Map)
          : null,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'command': command,
      'args': args,
      if (env != null) 'env': env,
      'enabled': enabled,
    };
  }
}

/// MCP 服务 - 全局单例
/// 负责启动时连接已配置的 MCP 服务器，管理工具注入
class McpService extends ChangeNotifier {
  static final McpService _instance = McpService._internal();
  static McpService get instance => _instance;
  
  McpService._internal();
  
  final McpServerManager _manager = McpServerManager();
  
  /// 是否已初始化
  bool _initialized = false;
  
  /// 正在连接的服务器数
  int _connectingCount = 0;
  
  /// 连接状态：服务器名 -> 状态
  final Map<String, McpConnectionState> _connectionStates = {};
  
  /// 初始化状态
  bool get initialized => _initialized;
  
  /// 服务器管理器
  McpServerManager get manager => _manager;
  
  /// 已连接的服务器
  Map<String, McpClient> get servers => _manager.servers;
  
  /// 所有 MCP 工具（合并所有服务器）
  List<McpTool> get allTools => _manager.getAllTools();
  
  /// 是否有任何已连接的服务器
  bool get hasServers => _manager.hasServers;
  
  /// 连接状态
  Map<String, McpConnectionState> get connectionStates => Map.unmodifiable(_connectionStates);
  
  /// 初始化服务 - 应用启动时调用
  Future<void> initialize() async {
    if (_initialized) return;
    
    debugPrint('🔌 MCP 服务初始化...');
    
    // 加载已保存的服务器配置
    final saved = StorageManager.getSetting<Map<dynamic, dynamic>>('mcp_servers', defaultValue: {});
    if (saved == null || saved.isEmpty) {
      debugPrint('🔌 MCP: 无已配置的服务器');
      _initialized = true;
      notifyListeners();
      return;
    }
    
    // 收集需要连接的服务器
    final serversToConnect = <String, McpServerConfig>{};
    saved.forEach((key, value) {
      if (value is Map) {
        final config = McpServerConfig.fromJson(Map<String, dynamic>.from(value));
        if (config.enabled) {
          serversToConnect[key.toString()] = config;
        }
      }
    });
    
    if (serversToConnect.isEmpty) {
      debugPrint('🔌 MCP: 无已启用的服务器');
      _initialized = true;
      notifyListeners();
      return;
    }
    
    // 并行连接所有服务器
    _connectingCount = serversToConnect.length;
    
    final futures = <Future<void>>[];
    for (final entry in serversToConnect.entries) {
      futures.add(_connectServer(entry.key, entry.value));
    }
    
    await Future.wait(futures);
    
    _initialized = true;
    _connectingCount = 0;
    notifyListeners();
    
    debugPrint('🔌 MCP 服务初始化完成，已连接 ${_manager.servers.length} 个服务器，${allTools.length} 个工具');
  }
  
  /// 连接单个服务器
  Future<void> _connectServer(String name, McpServerConfig config) async {
    _connectionStates[name] = McpConnectionState.connecting;
    notifyListeners();
    
    try {
      debugPrint('🔌 MCP: 连接服务器 $name: ${config.command} ${config.args.join(' ')}');
      
      await _manager.connect(name, config.command, config.args);
      
      _connectionStates[name] = McpConnectionState.connected;
      debugPrint('🔌 MCP: $name 连接成功，${_manager.getServer(name)?.tools.length ?? 0} 个工具');
    } catch (e) {
      _connectionStates[name] = McpConnectionState.failed;
      debugPrint('🔌 MCP: $name 连接失败: $e');
    }
  }
  
  /// 添加并连接服务器
  Future<bool> addServer(String name, McpServerConfig config) async {
    if (_manager.servers.containsKey(name)) {
      debugPrint('🔌 MCP: 服务器 $name 已存在');
      return false;
    }
    
    await _connectServer(name, config);
    
    // 保存配置
    _saveServerConfig(name, config);
    
    return _connectionStates[name] == McpConnectionState.connected;
  }
  
  /// 移除服务器
  Future<void> removeServer(String name) async {
    await _manager.disconnect(name);
    _connectionStates.remove(name);
    
    // 从保存的配置中移除
    final saved = StorageManager.getSetting<Map<dynamic, dynamic>>('mcp_servers', defaultValue: {}) ?? {};
    saved.remove(name);
    StorageManager.setSetting('mcp_servers', Map<String, dynamic>.from(saved));
    
    notifyListeners();
  }
  
  /// 重新连接服务器
  Future<void> reconnectServer(String name) async {
    final saved = StorageManager.getSetting<Map<dynamic, dynamic>>('mcp_servers', defaultValue: {});
    final configMap = saved?[name];
    if (configMap == null || configMap is! Map) return;
    
    final config = McpServerConfig.fromJson(Map<String, dynamic>.from(configMap));
    
    // 先断开
    await _manager.disconnect(name);
    _connectionStates.remove(name);
    
    // 重新连接
    await _connectServer(name, config);
    notifyListeners();
  }
  
  /// 调用 MCP 工具
  Future<ToolCallResult> callTool(String toolName, Map<String, dynamic> arguments) async {
    return await _manager.callTool(toolName, arguments);
  }
  
  /// 获取所有工具的 OpenAI 格式定义
  List<Map<String, dynamic>> getOpenAiTools() {
    return _manager.getAllOpenAiTools();
  }
  
  /// 保存服务器配置
  void _saveServerConfig(String name, McpServerConfig config) {
    final saved = StorageManager.getSetting<Map<dynamic, dynamic>>('mcp_servers', defaultValue: {}) ?? {};
    saved[name] = config.toJson();
    StorageManager.setSetting('mcp_servers', Map<String, dynamic>.from(saved));
  }
  
  /// 关闭所有连接
  @override
  Future<void> dispose() async {
    await _manager.disconnectAll();
    _connectionStates.clear();
    _initialized = false;
    super.dispose();
  }
}

/// MCP 连接状态
enum McpConnectionState {
  connecting,
  connected,
  failed,
  disconnected,
}
