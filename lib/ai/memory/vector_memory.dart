import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../providers/llm_provider.dart';

/// 向量嵌入服务接口
/// 用于将文本转换为向量表示
abstract class EmbeddingService {
  /// 获取文本的向量嵌入
  Future<List<double>> embed(String text);
  
  /// 获取向量维度
  int get dimension;
  
  /// 计算两个向量的余弦相似度
  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0;
    
    double dotProduct = 0;
    double normA = 0;
    double normB = 0;
    
    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    
    if (normA == 0 || normB == 0) return 0;
    return dotProduct / (math.sqrt(normA) * math.sqrt(normB));
  }
}

/// 简单的本地嵌入服务（使用 TF-IDF 或简单的词向量）
/// 注意：这是简化实现，生产环境应使用真正的嵌入模型
class LocalEmbeddingService implements EmbeddingService {
  final int _dimension = 256;
  
  @override
  int get dimension => _dimension;
  
  @override
  Future<List<double>> embed(String text) async {
    // 简单的词袋模型 + 位置编码
    final tokens = _tokenize(text);
    final vector = List<double>.filled(_dimension, 0.0);
    
    for (int i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      // 使用 hash 将 token 映射到向量位置
      final hash = token.hashCode.abs() % (_dimension ~/ 2);
      vector[hash] += 1.0;
      
      // 位置编码
      if (i < _dimension ~/ 2) {
        vector[_dimension ~/ 2 + i] = 1.0 / (i + 1);
      }
    }
    
    // L2 归一化
    double norm = 0;
    for (final v in vector) {
      norm += v * v;
    }
    norm = math.sqrt(norm);
    if (norm > 0) {
      for (int i = 0; i < vector.length; i++) {
        vector[i] /= norm;
      }
    }
    
    return vector;
  }
  
  List<String> _tokenize(String text) {
    // 简单分词：中文按字，英文按词
    final tokens = <String>[];
    final englishWords = RegExp(r'[a-zA-Z]+');
    final chineseChars = RegExp(r'[\u4e00-\u9fff]');
    
    // 提取英文单词
    for (final match in englishWords.allMatches(text.toLowerCase())) {
      tokens.add(match.group(0)!);
    }
    
    // 提取中文字符
    for (final match in chineseChars.allMatches(text)) {
      tokens.add(match.group(0)!);
    }
    
    return tokens;
  }
}

/// 记忆向量存储
/// 将记忆转换为向量并支持语义搜索
class VectorMemoryStore extends ChangeNotifier {
  final EmbeddingService _embeddingService;
  final List<_MemoryVector> _vectors = [];
  Box? _box;
  
  VectorMemoryStore({EmbeddingService? embeddingService})
      : _embeddingService = embeddingService ?? LocalEmbeddingService();
  
  /// 初始化存储
  Future<void> init() async {
    try {
      _box = await Hive.openBox('vector_memory');
      await _loadFromStorage();
    } catch (e) {
      debugPrint('📊 向量存储初始化失败: $e');
    }
  }
  
  /// 从存储加载向量
  Future<void> _loadFromStorage() async {
    if (_box == null) return;
    
    final data = _box!.get('vectors', defaultValue: <dynamic>[]);
    if (data is List) {
      for (final item in data) {
        if (item is Map) {
          final vector = (item['vector'] as List?)?.cast<double>();
          if (vector != null && vector.isNotEmpty) {
            _vectors.add(_MemoryVector(
              id: item['id'] as String? ?? '',
              content: item['content'] as String? ?? '',
              vector: vector,
              timestamp: DateTime.tryParse(item['timestamp'] as String? ?? '') ?? DateTime.now(),
              metadata: Map<String, dynamic>.from(item['metadata'] as Map? ?? {}),
            ));
          }
        }
      }
    }
    
    debugPrint('📊 加载了 ${_vectors.length} 条向量记忆');
  }
  
  /// 保存向量到存储
  Future<void> _saveToStorage() async {
    if (_box == null) return;
    
    final data = _vectors.map((v) => {
      'id': v.id,
      'content': v.content,
      'vector': v.vector,
      'timestamp': v.timestamp.toIso8601String(),
      'metadata': v.metadata,
    }).toList();
    
    await _box!.put('vectors', data);
  }
  
  /// 添加记忆向量
  Future<void> add(String content, {Map<String, dynamic>? metadata}) async {
    if (content.trim().isEmpty) return;
    
    // 检查是否已存在相似内容
    final existing = await search(content, limit: 1);
    if (existing.isNotEmpty && existing.first.score > 0.95) {
      // 已存在高度相似的记忆，跳过
      return;
    }
    
    final vector = await _embeddingService.embed(content);
    final memoryVector = _MemoryVector(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      content: content,
      vector: vector,
      timestamp: DateTime.now(),
      metadata: metadata ?? {},
    );
    
    _vectors.add(memoryVector);
    
    // 限制最大数量
    if (_vectors.length > 1000) {
      _vectors.removeAt(0);
    }
    
    await _saveToStorage();
    notifyListeners();
    
    debugPrint('📊 添加向量记忆: ${content.substring(0, math.min(50, content.length))}...');
  }
  
  /// 语义搜索
  Future<List<SearchResult>> search(String query, {int limit = 5}) async {
    if (query.isEmpty || _vectors.isEmpty) return [];
    
    final queryVector = await _embeddingService.embed(query);
    final results = <SearchResult>[];
    
    for (final mv in _vectors) {
      final score = EmbeddingService.cosineSimilarity(queryVector, mv.vector);
      if (score > 0.1) { // 相似度阈值
        results.add(SearchResult(
          content: mv.content,
          score: score,
          timestamp: mv.timestamp,
          metadata: mv.metadata,
        ));
      }
    }
    
    // 按相似度排序
    results.sort((a, b) => b.score.compareTo(a.score));
    
    return results.take(limit).toList();
  }
  
  /// 删除记忆
  Future<void> delete(String id) async {
    _vectors.removeWhere((v) => v.id == id);
    await _saveToStorage();
    notifyListeners();
  }
  
  /// 清空所有向量
  Future<void> clear() async {
    _vectors.clear();
    await _saveToStorage();
    notifyListeners();
  }
  
  /// 获取所有记忆内容
  List<String> getAllContents() {
    return _vectors.map((v) => v.content).toList();
  }
  
  /// 获取向量数量
  int get count => _vectors.length;
}

/// 记忆向量
class _MemoryVector {
  final String id;
  final String content;
  final List<double> vector;
  final DateTime timestamp;
  final Map<String, dynamic> metadata;
  
  _MemoryVector({
    required this.id,
    required this.content,
    required this.vector,
    required this.timestamp,
    required this.metadata,
  });
}

/// 搜索结果
class SearchResult {
  final String content;
  final double score;
  final DateTime timestamp;
  final Map<String, dynamic> metadata;
  
  SearchResult({
    required this.content,
    required this.score,
    required this.timestamp,
    required this.metadata,
  });
  
  @override
  String toString() => 'SearchResult(score: ${score.toStringAsFixed(3)}, content: ${content.substring(0, math.min(30, content.length))}...)';
}

/// 自动摘要服务
/// 用于压缩长对话历史
class SummarizationService {
  final LLMProvider? _provider;
  
  SummarizationService({LLMProvider? provider}) : _provider = provider;
  
  /// 生成对话摘要
  Future<String> summarize(List<Map<String, dynamic>> messages, {
    int maxTokens = 500,
    String? focus,
  }) async {
    if (_provider == null) {
      return _simpleSummarize(messages);
    }
    
    // 构建 prompt
    final buffer = StringBuffer();
    buffer.writeln('请将以下对话压缩为简洁的摘要，保留关键信息和决策。');
    if (focus != null) {
      buffer.writeln('重点关注: $focus');
    }
    buffer.writeln('摘要控制在 $maxTokens token 以内。');
    buffer.writeln();
    buffer.writeln('对话内容:');
    
    for (final msg in messages) {
      final role = msg['role'] as String? ?? 'unknown';
      final content = msg['content'] as String? ?? '';
      if (content.length > 200) {
        buffer.writeln('$role: ${content.substring(0, 200)}...');
      } else {
        buffer.writeln('$role: $content');
      }
    }
    
    buffer.writeln();
    buffer.writeln('摘要:');
    
    // 调用 LLM 生成摘要
    // 这里简化实现，返回简单摘要
    return _simpleSummarize(messages);
  }
  
  /// 简单摘要（不调用 LLM）
  String _simpleSummarize(List<Map<String, dynamic>> messages) {
    if (messages.isEmpty) return '';
    
    final buffer = StringBuffer();
    buffer.writeln('【对话摘要】');
    
    String? lastUserMsg;
    String? lastAssistantMsg;
    final toolsUsed = <String>{};
    
    for (final msg in messages) {
      final role = msg['role'] as String?;
      if (role == 'user') {
        lastUserMsg = msg['content'] as String?;
      } else if (role == 'assistant') {
        lastAssistantMsg = msg['content'] as String?;
      } else if (role == 'tool') {
        // 提取工具名
        final toolCallId = msg['tool_call_id'] as String?;
        if (toolCallId != null) {
          // 尝试从之前的消息中找到对应的工具调用
        }
      }
      
      // 从 assistant 消息中提取工具调用
      if (role == 'assistant' && msg['tool_calls'] is List) {
        for (final tc in msg['tool_calls'] as List) {
          if (tc is Map && tc['function'] is Map) {
            final name = (tc['function'] as Map)['name'] as String?;
            if (name != null) toolsUsed.add(name);
          }
        }
      }
    }
    
    if (lastUserMsg != null) {
      buffer.writeln('最后用户消息: ${lastUserMsg.length > 100 ? '${lastUserMsg.substring(0, 100)}...' : lastUserMsg}');
    }
    
    if (toolsUsed.isNotEmpty) {
      buffer.writeln('使用的工具: ${toolsUsed.join(', ')}');
    }
    
    if (lastAssistantMsg != null && lastAssistantMsg.isNotEmpty) {
      buffer.writeln('最后回复: ${lastAssistantMsg.length > 100 ? '${lastAssistantMsg.substring(0, 100)}...' : lastAssistantMsg}');
    }
    
    return buffer.toString();
  }
}
