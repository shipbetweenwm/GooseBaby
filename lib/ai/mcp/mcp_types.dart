/// MCP (Model Context Protocol) 类型定义
/// 参考: https://spec.modelcontextprotocol.io/

import 'dart:convert';

/// MCP 版本
const String mcpVersion = '2024-11-05';

// ─────────────────────────────────────────────────────────
// 基础类型
// ─────────────────────────────────────────────────────────

/// JSON-RPC 请求
class JsonRpcRequest {
  final String jsonrpc = '2.0';
  final String? id;
  final String method;
  final Map<String, dynamic>? params;
  
  JsonRpcRequest({
    this.id,
    required this.method,
    this.params,
  });
  
  Map<String, dynamic> toJson() => {
    'jsonrpc': jsonrpc,
    if (id != null) 'id': id,
    'method': method,
    if (params != null) 'params': params,
  };
  
  String toJsonString() => jsonEncode(toJson());
}

/// JSON-RPC 响应
class JsonRpcResponse {
  final String jsonrpc = '2.0';
  final String? id;
  final dynamic result;
  final JsonRpcError? error;
  
  JsonRpcResponse({
    this.id,
    this.result,
    this.error,
  });
  
  factory JsonRpcResponse.fromJson(Map<String, dynamic> json) {
    return JsonRpcResponse(
      id: json['id']?.toString(),
      result: json['result'],
      error: json['error'] != null 
          ? JsonRpcError.fromJson(json['error'] as Map<String, dynamic>)
          : null,
    );
  }
  
  bool get isSuccess => error == null;
}

/// JSON-RPC 错误
class JsonRpcError {
  final int code;
  final String message;
  final dynamic data;
  
  JsonRpcError({
    required this.code,
    required this.message,
    this.data,
  });
  
  factory JsonRpcError.fromJson(Map<String, dynamic> json) {
    return JsonRpcError(
      code: json['code'] as int,
      message: json['message'] as String,
      data: json['data'],
    );
  }
  
  // 标准错误码
  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;
}

// ─────────────────────────────────────────────────────────
// MCP 能力
// ─────────────────────────────────────────────────────────

/// 服务器能力
class ServerCapabilities {
  final bool? experimental;
  final ToolCapabilities? tools;
  final ResourceCapabilities? resources;
  final PromptCapabilities? prompts;
  
  const ServerCapabilities({
    this.experimental,
    this.tools,
    this.resources,
    this.prompts,
  });
  
  factory ServerCapabilities.fromJson(Map<String, dynamic> json) {
    return ServerCapabilities(
      experimental: json['experimental'] as bool?,
      tools: json['tools'] != null 
          ? ToolCapabilities.fromJson(json['tools'] as Map<String, dynamic>)
          : null,
      resources: json['resources'] != null 
          ? ResourceCapabilities.fromJson(json['resources'] as Map<String, dynamic>)
          : null,
      prompts: json['prompts'] != null 
          ? PromptCapabilities.fromJson(json['prompts'] as Map<String, dynamic>)
          : null,
    );
  }
  
  Map<String, dynamic> toJson() => {
    if (experimental != null) 'experimental': experimental,
    if (tools != null) 'tools': tools!.toJson(),
    if (resources != null) 'resources': resources!.toJson(),
    if (prompts != null) 'prompts': prompts!.toJson(),
  };
}

/// 工具能力
class ToolCapabilities {
  final bool listChanged;
  
  const ToolCapabilities({this.listChanged = false});
  
  factory ToolCapabilities.fromJson(Map<String, dynamic> json) {
    return ToolCapabilities(
      listChanged: json['listChanged'] as bool? ?? false,
    );
  }
  
  Map<String, dynamic> toJson() => {'listChanged': listChanged};
}

/// 资源能力
class ResourceCapabilities {
  final bool subscribe;
  final bool listChanged;
  
  const ResourceCapabilities({this.subscribe = false, this.listChanged = false});
  
  factory ResourceCapabilities.fromJson(Map<String, dynamic> json) {
    return ResourceCapabilities(
      subscribe: json['subscribe'] as bool? ?? false,
      listChanged: json['listChanged'] as bool? ?? false,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'subscribe': subscribe,
    'listChanged': listChanged,
  };
}

/// 提示词能力
class PromptCapabilities {
  final bool listChanged;
  
  const PromptCapabilities({this.listChanged = false});
  
  factory PromptCapabilities.fromJson(Map<String, dynamic> json) {
    return PromptCapabilities(
      listChanged: json['listChanged'] as bool? ?? false,
    );
  }
  
  Map<String, dynamic> toJson() => {'listChanged': listChanged};
}

/// 客户端能力
class ClientCapabilities {
  final bool? experimental;
  final ToolCapabilities? roots;
  final SamplingCapabilities? sampling;
  
  const ClientCapabilities({
    this.experimental,
    this.roots,
    this.sampling,
  });
  
  Map<String, dynamic> toJson() => {
    if (experimental != null) 'experimental': experimental,
    if (roots != null) 'roots': roots!.toJson(),
    if (sampling != null) 'sampling': sampling!.toJson(),
  };
}

/// 采样能力
class SamplingCapabilities {
  const SamplingCapabilities();
  
  Map<String, dynamic> toJson() => {};
}

// ─────────────────────────────────────────────────────────
// 工具定义
// ─────────────────────────────────────────────────────────

/// MCP 工具定义
class McpTool {
  final String name;
  final String? description;
  final Map<String, dynamic>? inputSchema;
  
  const McpTool({
    required this.name,
    this.description,
    this.inputSchema,
  });
  
  factory McpTool.fromJson(Map<String, dynamic> json) {
    return McpTool(
      name: json['name'] as String,
      description: json['description'] as String?,
      inputSchema: json['inputSchema'] as Map<String, dynamic>?,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'name': name,
    if (description != null) 'description': description,
    if (inputSchema != null) 'inputSchema': inputSchema,
  };
  
  /// 转换为 OpenAI 格式的工具定义
  Map<String, dynamic> toOpenAiFormat() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description ?? '',
      'parameters': inputSchema ?? {},
    },
  };
}

/// 工具调用请求
class ToolCallRequest {
  final String name;
  final Map<String, dynamic> arguments;
  
  const ToolCallRequest({
    required this.name,
    required this.arguments,
  });
  
  factory ToolCallRequest.fromJson(Map<String, dynamic> json) {
    return ToolCallRequest(
      name: json['name'] as String,
      arguments: json['arguments'] as Map<String, dynamic>? ?? {},
    );
  }
  
  Map<String, dynamic> toJson() => {
    'name': name,
    'arguments': arguments,
  };
}

/// 工具调用结果
class ToolCallResult {
  final List<ContentBlock> content;
  final bool? isError;
  
  const ToolCallResult({
    required this.content,
    this.isError,
  });
  
  factory ToolCallResult.fromJson(Map<String, dynamic> json) {
    final contentList = json['content'] as List? ?? [];
    return ToolCallResult(
      content: contentList
          .map((c) => ContentBlock.fromJson(c as Map<String, dynamic>))
          .toList(),
      isError: json['isError'] as bool?,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'content': content.map((c) => c.toJson()).toList(),
    if (isError != null) 'isError': isError,
  };
  
  /// 从简单文本创建结果
  factory ToolCallResult.text(String text, {bool isError = false}) {
    return ToolCallResult(
      content: [TextContentBlock(text: text)],
      isError: isError,
    );
  }
  
  /// 获取文本内容
  String get textContent {
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is TextContentBlock) {
        buffer.write(block.text);
      }
    }
    return buffer.toString();
  }
}

// ─────────────────────────────────────────────────────────
// 内容块
// ─────────────────────────────────────────────────────────

/// 内容块基类
abstract class ContentBlock {
  final String type;
  
  const ContentBlock({required this.type});
  
  Map<String, dynamic> toJson();
  
  factory ContentBlock.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    switch (type) {
      case 'text':
        return TextContentBlock.fromJson(json);
      case 'image':
        return ImageContentBlock.fromJson(json);
      case 'resource':
        return ResourceContentBlock.fromJson(json);
      default:
        return TextContentBlock(text: json['text']?.toString() ?? '');
    }
  }
}

/// 文本内容块
class TextContentBlock extends ContentBlock {
  final String text;
  
  const TextContentBlock({required this.text}) : super(type: 'text');
  
  factory TextContentBlock.fromJson(Map<String, dynamic> json) {
    return TextContentBlock(text: json['text'] as String? ?? '');
  }
  
  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'text': text,
  };
}

/// 图像内容块
class ImageContentBlock extends ContentBlock {
  final String data;
  final String mimeType;
  
  const ImageContentBlock({
    required this.data,
    required this.mimeType,
  }) : super(type: 'image');
  
  factory ImageContentBlock.fromJson(Map<String, dynamic> json) {
    return ImageContentBlock(
      data: json['data'] as String,
      mimeType: json['mimeType'] as String,
    );
  }
  
  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'data': data,
    'mimeType': mimeType,
  };
}

/// 资源内容块
class ResourceContentBlock extends ContentBlock {
  final Resource resource;
  
  const ResourceContentBlock({required this.resource}) : super(type: 'resource');
  
  factory ResourceContentBlock.fromJson(Map<String, dynamic> json) {
    return ResourceContentBlock(
      resource: Resource.fromJson(json['resource'] as Map<String, dynamic>),
    );
  }
  
  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'resource': resource.toJson(),
  };
}

// ─────────────────────────────────────────────────────────
// 资源定义
// ─────────────────────────────────────────────────────────

/// 资源
class Resource {
  final String uri;
  final String? name;
  final String? description;
  final String? mimeType;
  
  const Resource({
    required this.uri,
    this.name,
    this.description,
    this.mimeType,
  });
  
  factory Resource.fromJson(Map<String, dynamic> json) {
    return Resource(
      uri: json['uri'] as String,
      name: json['name'] as String?,
      description: json['description'] as String?,
      mimeType: json['mimeType'] as String?,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'uri': uri,
    if (name != null) 'name': name,
    if (description != null) 'description': description,
    if (mimeType != null) 'mimeType': mimeType,
  };
}

/// 资源内容
class ResourceContents {
  final String uri;
  final String? mimeType;
  
  const ResourceContents({
    required this.uri,
    this.mimeType,
  });
  
  Map<String, dynamic> toJson() => {
    'uri': uri,
    if (mimeType != null) 'mimeType': mimeType,
  };
}

/// 文本资源内容
class TextResourceContents extends ResourceContents {
  final String text;
  
  const TextResourceContents({
    required super.uri,
    super.mimeType,
    required this.text,
  });
  
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'text': text,
  };
}

/// 二进制资源内容
class BlobResourceContents extends ResourceContents {
  final String blob;
  
  const BlobResourceContents({
    required super.uri,
    super.mimeType,
    required this.blob,
  });
  
  @override
  Map<String, dynamic> toJson() => {
    ...super.toJson(),
    'blob': blob,
  };
}

// ─────────────────────────────────────────────────────────
// 提示词定义
// ─────────────────────────────────────────────────────────

/// 提示词
class Prompt {
  final String name;
  final String? description;
  final List<PromptArgument>? arguments;
  
  const Prompt({
    required this.name,
    this.description,
    this.arguments,
  });
  
  factory Prompt.fromJson(Map<String, dynamic> json) {
    final argsList = json['arguments'] as List?;
    return Prompt(
      name: json['name'] as String,
      description: json['description'] as String?,
      arguments: argsList
          ?.map((a) => PromptArgument.fromJson(a as Map<String, dynamic>))
          .toList(),
    );
  }
  
  Map<String, dynamic> toJson() => {
    'name': name,
    if (description != null) 'description': description,
    if (arguments != null) 'arguments': arguments!.map((a) => a.toJson()).toList(),
  };
}

/// 提示词参数
class PromptArgument {
  final String name;
  final String? description;
  final bool required;
  
  const PromptArgument({
    required this.name,
    this.description,
    this.required = false,
  });
  
  factory PromptArgument.fromJson(Map<String, dynamic> json) {
    return PromptArgument(
      name: json['name'] as String,
      description: json['description'] as String?,
      required: json['required'] as bool? ?? false,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'name': name,
    if (description != null) 'description': description,
    'required': required,
  };
}

/// 提示词消息
class PromptMessage {
  final String role;
  final ContentBlock content;
  
  const PromptMessage({
    required this.role,
    required this.content,
  });
  
  factory PromptMessage.fromJson(Map<String, dynamic> json) {
    return PromptMessage(
      role: json['role'] as String,
      content: ContentBlock.fromJson(json['content'] as Map<String, dynamic>),
    );
  }
  
  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content.toJson(),
  };
}

// ─────────────────────────────────────────────────────────
// 实现信息
// ─────────────────────────────────────────────────────────

/// 实现信息
class Implementation {
  final String name;
  final String version;
  
  const Implementation({
    required this.name,
    required this.version,
  });
  
  Map<String, dynamic> toJson() => {
    'name': name,
    'version': version,
  };
  
  factory Implementation.fromJson(Map<String, dynamic> json) {
    return Implementation(
      name: json['name'] as String,
      version: json['version'] as String,
    );
  }
}
