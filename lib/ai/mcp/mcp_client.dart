import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../utils/type_utils.dart';
import 'mcp_types.dart';

/// MCP 客户端
/// 连接到 MCP 服务器并管理通信
class McpClient {
  final String name;
  final String version;
  
  Process? _process;
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;
  
  final Map<String, Completer<JsonRpcResponse>> _pendingRequests = {};
  final StreamController<JsonRpcResponse> _notifications = StreamController.broadcast();
  
  ServerCapabilities? _serverCapabilities;
  Implementation? _serverInfo;
  
  final List<McpTool> _tools = [];
  final List<Resource> _resources = [];
  final List<Prompt> _prompts = [];
  
  bool _isConnected = false;
  int _requestId = 0;
  
  McpClient({
    this.name = 'GooseBaby',
    this.version = '1.0.0',
  });
  
  /// 是否已连接
  bool get isConnected => _isConnected;
  
  /// 服务器能力
  ServerCapabilities? get serverCapabilities => _serverCapabilities;
  
  /// 服务器信息
  Implementation? get serverInfo => _serverInfo;
  
  /// 可用工具列表
  List<McpTool> get tools => List.unmodifiable(_tools);
  
  /// 可用资源列表
  List<Resource> get resources => List.unmodifiable(_resources);
  
  /// 可用提示词列表
  List<Prompt> get prompts => List.unmodifiable(_prompts);
  
  /// 通知流
  Stream<JsonRpcResponse> get notifications => _notifications.stream;
  
  /// 启动并连接到 MCP 服务器（通过 stdio）
  Future<void> connectStdio(String command, List<String> args, {String? workingDirectory}) async {
    if (_isConnected) {
      throw StateError('Already connected');
    }
    
    debugPrint('🔌 MCP: 启动服务器: $command ${args.join(' ')}');
    
    _process = await Process.start(
      command,
      args,
      workingDirectory: workingDirectory,
      environment: {
        'MCP_VERSION': mcpVersion,
      },
    );
    
    // 监听 stdout
    _stdoutSubscription = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleMessage);
    
    // 监听 stderr（日志）
    _stderrSubscription = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          debugPrint('🔌 MCP stderr: $line');
        });
    
    // 初始化连接
    await _initialize();
    
    _isConnected = true;
    debugPrint('🔌 MCP: 已连接到 $_serverInfo');
  }
  
  /// 初始化连接
  Future<void> _initialize() async {
    // 发送初始化请求
    final response = await sendRequest('initialize', {
      'protocolVersion': mcpVersion,
      'capabilities': ClientCapabilities(
        experimental: true,
        roots: const ToolCapabilities(listChanged: true),
      ).toJson(),
      'clientInfo': Implementation(name: name, version: version).toJson(),
    });
    
    if (!response.isSuccess) {
      throw Exception('Initialize failed: ${response.error?.message}');
    }
    
    final result = safeMap(response.result);
    _serverCapabilities = ServerCapabilities.fromJson(
      safeMap(result['capabilities'] ?? {}),
    );
    _serverInfo = result['serverInfo'] != null
        ? Implementation.fromJson(safeMap(result['serverInfo']))
        : null;
    
    // 发送 initialized 通知
    sendNotification('notifications/initialized', {});
    
    // 获取工具列表
    if (_serverCapabilities?.tools != null) {
      await _loadTools();
    }
    
    // 获取资源列表
    if (_serverCapabilities?.resources != null) {
      await _loadResources();
    }
    
    // 获取提示词列表
    if (_serverCapabilities?.prompts != null) {
      await _loadPrompts();
    }
  }
  
  /// 加载工具列表
  Future<void> _loadTools() async {
    final response = await sendRequest('tools/list', {});
    if (response.isSuccess && response.result is Map) {
      final tools = (response.result as Map)['tools'] as List?;
      if (tools != null) {
        _tools.clear();
        for (final t in tools) {
          _tools.add(McpTool.fromJson(safeMap(t)));
        }
      }
    }
    debugPrint('🔌 MCP: 加载了 ${_tools.length} 个工具');
  }
  
  /// 加载资源列表
  Future<void> _loadResources() async {
    final response = await sendRequest('resources/list', {});
    if (response.isSuccess && response.result is Map) {
      final resources = (response.result as Map)['resources'] as List?;
      if (resources != null) {
        _resources.clear();
        for (final r in resources) {
          _resources.add(Resource.fromJson(safeMap(r)));
        }
      }
    }
    debugPrint('🔌 MCP: 加载了 ${_resources.length} 个资源');
  }
  
  /// 加载提示词列表
  Future<void> _loadPrompts() async {
    final response = await sendRequest('prompts/list', {});
    if (response.isSuccess && response.result is Map) {
      final prompts = (response.result as Map)['prompts'] as List?;
      if (prompts != null) {
        _prompts.clear();
        for (final p in prompts) {
          _prompts.add(Prompt.fromJson(safeMap(p)));
        }
      }
    }
    debugPrint('🔌 MCP: 加载了 ${_prompts.length} 个提示词');
  }
  
  /// 发送请求
  Future<JsonRpcResponse> sendRequest(String method, Map<String, dynamic> params) async {
    final id = (_requestId++).toString();
    final request = JsonRpcRequest(id: id, method: method, params: params);
    
    final completer = Completer<JsonRpcResponse>();
    _pendingRequests[id] = completer;
    
    _sendMessage(request.toJsonString());
    
    // 超时处理
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pendingRequests.remove(id);
        throw TimeoutException('Request $method timed out');
      },
    );
  }
  
  /// 发送通知（无需响应）
  void sendNotification(String method, Map<String, dynamic> params) {
    final request = JsonRpcRequest(method: method, params: params);
    _sendMessage(request.toJsonString());
  }
  
  /// 发送消息
  void _sendMessage(String message) {
    if (_process == null) return;
    
    // MCP stdio 格式: Content-Length: xxx\r\n\r\n{json}
    final bytes = utf8.encode(message);
    final header = 'Content-Length: ${bytes.length}\r\n\r\n';
    
    _process!.stdin.write(header);
    _process!.stdin.add(bytes);
    _process!.stdin.flush();
    
    debugPrint('🔌 MCP → $message');
  }
  
  /// 处理接收到的消息
  void _handleMessage(String line) {
    if (line.isEmpty) return;
    
    // 解析 Content-Length 头
    if (line.startsWith('Content-Length:')) {
      return; // 等待空行后的内容
    }
    
    // 解析 JSON
    if (line.startsWith('{')) {
      try {
        final json = safeMap(jsonDecode(line));
        final response = JsonRpcResponse.fromJson(json);
        
        debugPrint('🔌 MCP ← ${response.isSuccess ? 'response' : 'error'}');
        
        // 检查是否是响应
        if (response.id != null && _pendingRequests.containsKey(response.id)) {
          _pendingRequests.remove(response.id!)!.complete(response);
        } else if (response.id == null) {
          // 通知
          _notifications.add(response);
        }
      } catch (e) {
        debugPrint('🔌 MCP: 解析消息失败: $e');
      }
    }
  }
  
  /// 调用工具
  Future<ToolCallResult> callTool(String name, Map<String, dynamic> arguments) async {
    final response = await sendRequest('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    
    if (!response.isSuccess) {
      return ToolCallResult.text(
        'Error: ${response.error?.message ?? 'Unknown error'}',
        isError: true,
      );
    }
    
    return ToolCallResult.fromJson(safeMap(response.result));
  }
  
  /// 读取资源
  Future<ResourceContents> readResource(String uri) async {
    final response = await sendRequest('resources/read', {'uri': uri});
    
    if (!response.isSuccess) {
      throw Exception('Failed to read resource: ${response.error?.message}');
    }
    
    final contents = (response.result as Map)['contents'] as List?;
    if (contents == null || contents.isEmpty) {
      throw Exception('Resource not found: $uri');
    }
    
    final content = safeMap(contents.first);
    if (content.containsKey('text')) {
      return TextResourceContents(
        uri: uri,
        mimeType: content['mimeType'] as String?,
        text: content['text'] as String,
      );
    } else {
      return BlobResourceContents(
        uri: uri,
        mimeType: content['mimeType'] as String?,
        blob: content['blob'] as String,
      );
    }
  }
  
  /// 获取提示词
  Future<List<PromptMessage>> getPrompt(String name, {Map<String, dynamic>? arguments}) async {
    final response = await sendRequest('prompts/get', {
      'name': name,
      if (arguments != null) 'arguments': arguments,
    });
    
    if (!response.isSuccess) {
      throw Exception('Failed to get prompt: ${response.error?.message}');
    }
    
    final messages = (response.result as Map)['messages'] as List?;
    if (messages == null) return [];
    
    return messages
        .map((m) => PromptMessage.fromJson(safeMap(m)))
        .toList();
  }
  
  /// 获取转换为 OpenAI 格式的工具列表
  List<Map<String, dynamic>> getOpenAiTools() {
    return _tools.map((t) => t.toOpenAiFormat()).toList();
  }
  
  /// 关闭连接
  Future<void> close() async {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    _process?.kill();
    _process = null;
    _isConnected = false;
    _pendingRequests.clear();
    
    debugPrint('🔌 MCP: 已断开连接');
  }
}

/// MCP 服务器管理器
/// 管理多个 MCP 服务器连接
class McpServerManager extends ChangeNotifier {
  final Map<String, McpClient> _servers = {};
  
  /// 已连接的服务器
  Map<String, McpClient> get servers => Map.unmodifiable(_servers);
  
  /// 连接到 MCP 服务器
  Future<McpClient> connect(String id, String command, List<String> args, {String? workingDirectory}) async {
    if (_servers.containsKey(id)) {
      throw StateError('Server $id already exists');
    }
    
    final client = McpClient();
    await client.connectStdio(command, args, workingDirectory: workingDirectory);
    
    _servers[id] = client;
    notifyListeners();
    
    return client;
  }
  
  /// 断开服务器连接
  Future<void> disconnect(String id) async {
    final client = _servers.remove(id);
    if (client != null) {
      await client.close();
      notifyListeners();
    }
  }
  
  /// 断开所有服务器
  Future<void> disconnectAll() async {
    for (final client in _servers.values) {
      await client.close();
    }
    _servers.clear();
    notifyListeners();
  }
  
  /// 获取所有工具（合并所有服务器）
  List<McpTool> getAllTools() {
    final tools = <McpTool>[];
    for (final client in _servers.values) {
      tools.addAll(client.tools);
    }
    return tools;
  }
  
  /// 获取所有资源
  List<Resource> getAllResources() {
    final resources = <Resource>[];
    for (final client in _servers.values) {
      resources.addAll(client.resources);
    }
    return resources;
  }
  
  /// 获取所有提示词
  List<Prompt> getAllPrompts() {
    final prompts = <Prompt>[];
    for (final client in _servers.values) {
      prompts.addAll(client.prompts);
    }
    return prompts;
  }
  
  /// 获取所有工具的 OpenAI 格式定义
  List<Map<String, dynamic>> getAllOpenAiTools() {
    return getAllTools().map((t) => t.toOpenAiFormat()).toList();
  }
  
  /// 调用工具（自动找到对应的服务器）
  Future<ToolCallResult> callTool(String toolName, Map<String, dynamic> arguments) async {
    for (final entry in _servers.entries) {
      final client = entry.value;
      if (client.tools.any((t) => t.name == toolName)) {
        return client.callTool(toolName, arguments);
      }
    }
    
    return ToolCallResult.text('Tool not found: $toolName', isError: true);
  }
  
  /// 按名称获取服务器
  McpClient? getServer(String id) => _servers[id];
  
  /// 是否有连接的服务器
  bool get hasServers => _servers.isNotEmpty;
}
