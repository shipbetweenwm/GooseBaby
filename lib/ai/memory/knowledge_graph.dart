/// 记忆系统升级 — 知识图谱 + RAG 混合检索（模块 6）
///
/// 1. KnowledgeGraph: 轻量级知识图谱，建立记忆间的关联关系
/// 2. HybridMemorySearch: 混合检索（BM25 稀疏 + 向量稠密 + RRF 融合）
/// 3. MemoryEnhancer: 将知识图谱与向量记忆组合的入口
///
/// 与现有 VectorMemoryStore 的关系：
/// - VectorMemoryStore 保持不变（向后兼容）
/// - HybridMemorySearch 在其基础上增加 BM25 稀疏检索 + RRF 融合
/// - KnowledgeGraph 提供记忆间的关联关系图遍历
library;
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../config/agent_config.dart';
import 'vector_memory.dart';

// ═══════════════════════════════════════════
// 知识图谱 — 三元组存储
// ═══════════════════════════════════════════

/// 知识三元组（主语-谓语-宾语）
class Triple {
  final String subject;
  final String predicate;
  final String object;
  final DateTime timestamp;
  final double confidence;

  const Triple({
    required this.subject,
    required this.predicate,
    required this.object,
    required this.timestamp,
    this.confidence = 1.0,
  });

  factory Triple.fromJson(Map<String, dynamic> json) {
    return Triple(
      subject: json['s'] as String? ?? json['subject'] as String? ?? '',
      predicate: json['p'] as String? ?? json['predicate'] as String? ?? '',
      object: json['o'] as String? ?? json['object'] as String? ?? '',
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() => {
        's': subject,
        'p': predicate,
        'o': object,
        'timestamp': timestamp.toIso8601String(),
        'confidence': confidence,
      };

  @override
  String toString() => '($subject) -[$predicate]-> ($object)';

  @override
  bool operator ==(Object other) =>
      other is Triple &&
      subject == other.subject &&
      predicate == other.predicate &&
      object == other.object;

  @override
  int get hashCode => Object.hash(subject, predicate, object);
}

/// 知识图谱节点
class KGNode {
  final String id;
  final String label;
  final Map<String, dynamic> properties;
  final DateTime createdAt;
  int referenceCount;

  KGNode({
    required this.id,
    this.label = '',
    this.properties = const {},
    DateTime? createdAt,
    this.referenceCount = 0,
  }) : createdAt = createdAt ?? DateTime.now();

  @override
  String toString() => 'KGNode($id${label.isNotEmpty ? ": $label" : ""})';
}

/// 知识图谱边
class KGEdge {
  final String from;
  final String relation;
  final String to;
  final double weight;
  final DateTime createdAt;

  const KGEdge({
    required this.from,
    required this.relation,
    required this.to,
    this.weight = 1.0,
    required this.createdAt,
  });
}

/// 轻量级知识图谱
///
/// 用于建立记忆之间的关联关系，支持图遍历式检索。
/// 存储结构：
///   - _nodes: 实体节点 (id → KGNode)
///   - _edges: 关系边列表
///   - _adjacency: 邻接表 (nodeId → [edges])
class KnowledgeGraph {
  final Map<String, KGNode> _nodes = {};
  final List<KGEdge> _edges = [];
  final Map<String, List<KGEdge>> _adjacency = {}; // 邻接表
  final Map<String, List<KGEdge>> _reverseAdjacency = {}; // 反向邻接表

  /// 节点数量
  int get nodeCount => _nodes.length;

  /// 边数量
  int get edgeCount => _edges.length;

  /// 添加知识三元组
  void addTriple(String subject, String predicate, String object) {
    // 确保节点存在
    _nodes.putIfAbsent(subject, () => KGNode(id: subject, label: subject));
    _nodes.putIfAbsent(object, () => KGNode(id: object, label: object));

    // 增加引用计数
    _nodes[subject]!.referenceCount++;
    _nodes[object]!.referenceCount++;

    // 检查是否已存在相同的边
    final exists = _edges.any(
        (e) => e.from == subject && e.relation == predicate && e.to == object);
    if (exists) return;

    // 添加边
    final edge = KGEdge(
      from: subject,
      relation: predicate,
      to: object,
      createdAt: DateTime.now(),
    );
    _edges.add(edge);
    _adjacency.putIfAbsent(subject, () => []).add(edge);
    _reverseAdjacency.putIfAbsent(object, () => []).add(edge);

    debugPrint('🧠 [KG] 添加三元组: $subject -[$predicate]-> $object');
  }

  /// 批量添加三元组
  void addTriples(List<Triple> triples) {
    for (final t in triples) {
      addTriple(t.subject, t.predicate, t.object);
    }
  }

  /// 从对话文本中提取知识三元组（需要 LLM，这里提供解析逻辑）
  ///
  /// 返回值为 LLM 提取的 prompt（由调用方负责发送给 LLM）
  String buildExtractionPrompt(String conversationText) {
    return '''
从以下对话中提取知识三元组（主语-谓语-宾语），仅提取事实性知识。

对话内容：
$conversationText

请输出 JSON 数组格式：
[{"s": "主语", "p": "谓语", "o": "宾语"}]

提取规则：
1. 只提取事实性知识，不提取情感或意见
2. 实体名称尽量简短（如"用户偏好"而不是"用户似乎喜欢的东西"）
3. 关系用动词或介词短语表示（如"使用"、"依赖"、"位于"）
4. 最多提取 10 个三元组

只输出 JSON 数组，不要其他内容。''';
  }

  /// 解析 LLM 返回的三元组
  List<Triple> parseExtractionResult(String llmOutput) {
    try {
      final jsonMatch = RegExp(r'\[[\s\S]*\]').firstMatch(llmOutput);
      if (jsonMatch == null) return [];

      final array = jsonDecode(jsonMatch.group(0)!) as List;
      return array
          .map((item) => Triple.fromJson(item as Map<String, dynamic>))
          .where((t) =>
              t.subject.isNotEmpty &&
              t.predicate.isNotEmpty &&
              t.object.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('⚠️ [KG] 解析三元组失败: $e');
      return [];
    }
  }

  /// 图遍历搜索 — 找到与查询相关的知识子图（BFS）
  List<KGNode> traverseFrom(String entityId, {int maxDepth = 2}) {
    if (!_nodes.containsKey(entityId)) return [];

    final visited = <String>{};
    final result = <KGNode>[];
    final queue = <_BfsItem>[_BfsItem(entityId, 0)];

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      if (visited.contains(current.id) || current.depth > maxDepth) continue;

      visited.add(current.id);
      final node = _nodes[current.id];
      if (node != null) result.add(node);

      // 扩展正向邻居
      for (final edge in _adjacency[current.id] ?? []) {
        if (!visited.contains(edge.to)) {
          queue.add(_BfsItem(edge.to, current.depth + 1));
        }
      }

      // 扩展反向邻居
      for (final edge in _reverseAdjacency[current.id] ?? []) {
        if (!visited.contains(edge.from)) {
          queue.add(_BfsItem(edge.from, current.depth + 1));
        }
      }
    }

    return result;
  }

  /// 查找与给定实体相关的所有三元组
  List<Triple> findRelated(String entity) {
    final triples = <Triple>[];

    for (final edge in _adjacency[entity] ?? []) {
      triples.add(Triple(
        subject: edge.from,
        predicate: edge.relation,
        object: edge.to,
        timestamp: edge.createdAt,
      ));
    }

    for (final edge in _reverseAdjacency[entity] ?? []) {
      triples.add(Triple(
        subject: edge.from,
        predicate: edge.relation,
        object: edge.to,
        timestamp: edge.createdAt,
      ));
    }

    return triples;
  }

  /// 模糊搜索节点（按名称匹配）
  List<KGNode> searchNodes(String query) {
    final lowerQuery = query.toLowerCase();
    return _nodes.values
        .where((node) =>
            node.id.toLowerCase().contains(lowerQuery) ||
            node.label.toLowerCase().contains(lowerQuery))
        .toList()
      ..sort((a, b) => b.referenceCount.compareTo(a.referenceCount));
  }

  /// 获取知识图谱摘要（用于注入 System Prompt）
  String getSummary({int maxTriples = 20}) {
    if (_edges.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('【知识图谱上下文】');
    buffer.writeln('实体: ${_nodes.length} 个，关系: ${_edges.length} 条');
    buffer.writeln('关键事实:');

    // 按引用次数排序的高频实体
    final topNodes = _nodes.values.toList()
      ..sort((a, b) => b.referenceCount.compareTo(a.referenceCount));
    final topEntityIds = topNodes.take(10).map((n) => n.id).toSet();

    // 输出与高频实体相关的三元组
    var count = 0;
    for (final edge in _edges) {
      if (count >= maxTriples) break;
      if (topEntityIds.contains(edge.from) ||
          topEntityIds.contains(edge.to)) {
        buffer.writeln('  - ${edge.from} ${edge.relation} ${edge.to}');
        count++;
      }
    }

    return buffer.toString();
  }

  /// 清空图谱
  void clear() {
    _nodes.clear();
    _edges.clear();
    _adjacency.clear();
    _reverseAdjacency.clear();
  }

  /// 导出为 JSON
  Map<String, dynamic> toJson() => {
        'nodes': _nodes.keys.toList(),
        'edges': _edges
            .map((e) => {
                  'from': e.from,
                  'relation': e.relation,
                  'to': e.to,
                  'weight': e.weight,
                  'createdAt': e.createdAt.toIso8601String(),
                })
            .toList(),
      };

  /// 从 JSON 导入
  void loadFromJson(Map<String, dynamic> json) {
    clear();
    final edges = json['edges'] as List? ?? [];
    for (final e in edges) {
      final edgeMap = e as Map<String, dynamic>;
      addTriple(
        edgeMap['from'] as String? ?? '',
        edgeMap['relation'] as String? ?? '',
        edgeMap['to'] as String? ?? '',
      );
    }
  }
}

/// BFS 辅助类
class _BfsItem {
  final String id;
  final int depth;
  _BfsItem(this.id, this.depth);
}

// ═══════════════════════════════════════════
// BM25 稀疏检索
// ═══════════════════════════════════════════

/// BM25 稀疏检索器
///
/// 用于关键词级别的精确召回，与向量稠密检索互补。
class BM25Retriever {
  /// BM25 参数
  final double k1;
  final double b;

  /// 文档集合
  final List<_BM25Document> _documents = [];
  double _avgDocLength = 0;

  /// 逆文档频率缓存
  final Map<String, double> _idfCache = {};

  BM25Retriever({this.k1 = 1.5, this.b = 0.75});

  /// 索引文档
  void indexDocuments(List<String> documents, List<String> ids) {
    _documents.clear();
    _idfCache.clear();

    for (var i = 0; i < documents.length; i++) {
      final tokens = _tokenize(documents[i]);
      final tf = <String, int>{};
      for (final token in tokens) {
        tf[token] = (tf[token] ?? 0) + 1;
      }
      _documents.add(_BM25Document(
        id: i < ids.length ? ids[i] : i.toString(),
        tokens: tokens,
        termFrequency: tf,
        length: tokens.length,
      ));
    }

    _avgDocLength = _documents.isEmpty
        ? 0
        : _documents.map((d) => d.length).reduce((a, b) => a + b) /
            _documents.length;

    _buildIdfCache();
  }

  /// 搜索
  List<BM25Result> search(String query, {int topK = 10}) {
    if (_documents.isEmpty) return [];

    final queryTokens = _tokenize(query);
    final scores = <String, double>{};

    for (final doc in _documents) {
      double score = 0;
      for (final term in queryTokens) {
        final tf = doc.termFrequency[term] ?? 0;
        if (tf == 0) continue;

        final idf = _idfCache[term] ?? 0;
        final numerator = tf * (k1 + 1);
        final denominator =
            tf + k1 * (1 - b + b * doc.length / _avgDocLength);
        score += idf * numerator / denominator;
      }
      if (score > 0) {
        scores[doc.id] = score;
      }
    }

    // 排序
    final sortedEntries = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return sortedEntries
        .take(topK)
        .map((e) => BM25Result(id: e.key, score: e.value))
        .toList();
  }

  /// 构建 IDF 缓存
  void _buildIdfCache() {
    final docCount = _documents.length;
    final termDocCount = <String, int>{};

    for (final doc in _documents) {
      for (final term in doc.termFrequency.keys) {
        termDocCount[term] = (termDocCount[term] ?? 0) + 1;
      }
    }

    for (final entry in termDocCount.entries) {
      _idfCache[entry.key] =
          math.log((docCount - entry.value + 0.5) / (entry.value + 0.5) + 1);
    }
  }

  /// 分词（中英文混合）
  List<String> _tokenize(String text) {
    final tokens = <String>[];
    final englishWords = RegExp(r'[a-zA-Z_]\w*');
    final chineseChars = RegExp(r'[\u4e00-\u9fff]+');

    for (final match in englishWords.allMatches(text.toLowerCase())) {
      tokens.add(match.group(0)!);
    }
    for (final match in chineseChars.allMatches(text)) {
      // 中文按 bigram 分词
      final chars = match.group(0)!;
      for (var i = 0; i < chars.length; i++) {
        tokens.add(chars[i]);
        if (i < chars.length - 1) {
          tokens.add(chars.substring(i, i + 2));
        }
      }
    }
    return tokens;
  }
}

/// BM25 文档
class _BM25Document {
  final String id;
  final List<String> tokens;
  final Map<String, int> termFrequency;
  final int length;

  const _BM25Document({
    required this.id,
    required this.tokens,
    required this.termFrequency,
    required this.length,
  });
}

/// BM25 搜索结果
class BM25Result {
  final String id;
  final double score;

  const BM25Result({required this.id, required this.score});
}

// ═══════════════════════════════════════════
// 混合检索 — RRF 融合
// ═══════════════════════════════════════════

/// 混合检索引擎
///
/// 组合 BM25 稀疏检索 + 向量稠密检索，
/// 使用 Reciprocal Rank Fusion (RRF) 进行排序融合。
class HybridMemorySearch {
  final VectorMemoryStore _vectorStore;
  final BM25Retriever _bm25 = BM25Retriever();
  final KnowledgeGraph _knowledgeGraph;
  bool _bm25Indexed = false;

  HybridMemorySearch({
    required VectorMemoryStore vectorStore,
    KnowledgeGraph? knowledgeGraph,
  })  : _vectorStore = vectorStore,
        _knowledgeGraph = knowledgeGraph ?? KnowledgeGraph();

  /// 获取知识图谱引用
  KnowledgeGraph get knowledgeGraph => _knowledgeGraph;

  /// 确保 BM25 索引已构建
  void _ensureBM25Indexed() {
    if (_bm25Indexed) return;

    final contents = _vectorStore.getAllContents();
    final ids =
        List.generate(contents.length, (i) => i.toString());
    _bm25.indexDocuments(contents, ids);
    _bm25Indexed = true;
  }

  /// 通知索引需要更新（当新记忆添加后调用）
  void invalidateIndex() {
    _bm25Indexed = false;
  }

  /// 混合搜索
  ///
  /// 1. BM25 稀疏检索（关键词精确召回）
  /// 2. 向量稠密检索（语义理解）
  /// 3. RRF 融合排序
  /// 4. 知识图谱扩展（可选）
  Future<List<HybridSearchResult>> search(
    String query, {
    int topK = 5,
    bool useKnowledgeGraph = true,
    double sparseWeight = 0.4,
    double denseWeight = 0.6,
  }) async {
    final config = AgentConfig();
    final effectiveTopK = topK > 0 ? topK : config.memorySearchTopK;

    // 1. BM25 稀疏检索
    _ensureBM25Indexed();
    final sparseResults = _bm25.search(query, topK: effectiveTopK * 3);

    // 2. 向量稠密检索
    final denseResults =
        await _vectorStore.search(query, limit: effectiveTopK * 3);

    // 3. RRF 融合
    final fusedScores = <int, double>{}; // index → score
    final allContents = _vectorStore.getAllContents();

    // BM25 结果加入 RRF
    for (var rank = 0; rank < sparseResults.length; rank++) {
      final idx = int.tryParse(sparseResults[rank].id) ?? -1;
      if (idx < 0 || idx >= allContents.length) continue;
      fusedScores[idx] =
          (fusedScores[idx] ?? 0) + sparseWeight / (60 + rank + 1);
    }

    // 稠密结果加入 RRF（通过内容匹配找到索引）
    for (var rank = 0; rank < denseResults.length; rank++) {
      final content = denseResults[rank].content;
      final idx = allContents.indexOf(content);
      if (idx < 0) continue;
      fusedScores[idx] =
          (fusedScores[idx] ?? 0) + denseWeight / (60 + rank + 1);
    }

    // 4. 排序
    final sortedEntries = fusedScores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    var results = sortedEntries
        .take(effectiveTopK)
        .map((e) => HybridSearchResult(
              content: allContents[e.key],
              score: e.value,
              source: 'hybrid',
            ))
        .toList();

    // 5. 知识图谱扩展（为搜索结果补充关联知识）
    if (useKnowledgeGraph && _knowledgeGraph.nodeCount > 0) {
      results = _enrichWithKnowledgeGraph(query, results);
    }

    return results;
  }

  /// 用知识图谱丰富搜索结果
  List<HybridSearchResult> _enrichWithKnowledgeGraph(
    String query,
    List<HybridSearchResult> results,
  ) {
    // 在知识图谱中搜索与 query 相关的节点
    final relatedNodes = _knowledgeGraph.searchNodes(query);

    if (relatedNodes.isEmpty) return results;

    // 对每个匹配节点，找到关联的三元组作为补充信息
    final kgContextParts = <String>[];
    for (final node in relatedNodes.take(3)) {
      final triples = _knowledgeGraph.findRelated(node.id);
      for (final triple in triples.take(5)) {
        kgContextParts.add(triple.toString());
      }
    }

    if (kgContextParts.isNotEmpty) {
      results.add(HybridSearchResult(
        content: '【关联知识】${kgContextParts.join("; ")}',
        score: 0.5, // 中等优先级
        source: 'knowledge_graph',
      ));
    }

    return results;
  }
}

/// 混合搜索结果
class HybridSearchResult {
  final String content;
  final double score;
  final String source; // 'sparse', 'dense', 'hybrid', 'knowledge_graph'

  const HybridSearchResult({
    required this.content,
    required this.score,
    this.source = 'hybrid',
  });

  @override
  String toString() =>
      'HybridResult(score: ${score.toStringAsFixed(4)}, '
      'source: $source, content: ${content.substring(0, math.min(40, content.length))}...)';
}

// ═══════════════════════════════════════════
// 记忆增强器 — 统一入口
// ═══════════════════════════════════════════

/// 记忆增强器
///
/// 统一管理 VectorMemoryStore + KnowledgeGraph + HybridSearch 的入口。
/// 负责：
/// 1. 添加记忆时同时更新向量存储和知识图谱
/// 2. 搜索时使用混合检索策略
/// 3. 生成记忆上下文（用于 System Prompt 注入）
class MemoryEnhancer {
  final VectorMemoryStore vectorStore;
  final KnowledgeGraph knowledgeGraph;
  final HybridMemorySearch hybridSearch;

  MemoryEnhancer({
    required this.vectorStore,
    KnowledgeGraph? knowledgeGraph,
  })  : knowledgeGraph = knowledgeGraph ?? KnowledgeGraph(),
        hybridSearch = HybridMemorySearch(
          vectorStore: vectorStore,
          knowledgeGraph: knowledgeGraph,
        );

  /// 添加记忆（同时更新向量存储）
  Future<void> addMemory(String content,
      {Map<String, dynamic>? metadata}) async {
    await vectorStore.add(content, metadata: metadata);
    hybridSearch.invalidateIndex(); // 标记需要重建 BM25 索引
  }

  /// 添加知识三元组
  void addKnowledge(List<Triple> triples) {
    knowledgeGraph.addTriples(triples);
  }

  /// 混合搜索记忆
  Future<List<HybridSearchResult>> search(String query,
      {int topK = 5}) async {
    return hybridSearch.search(query, topK: topK);
  }

  /// 生成记忆上下文（注入 System Prompt）
  Future<String> buildMemoryContext(String userQuery, {int maxTokens = 2000}) async {
    final buffer = StringBuffer();

    // 1. 混合检索相关记忆
    final memories = await search(userQuery, topK: 5);
    if (memories.isNotEmpty) {
      buffer.writeln('【相关记忆】');
      for (final mem in memories) {
        if (mem.source != 'knowledge_graph') {
          buffer.writeln('- ${mem.content}');
        }
      }
    }

    // 2. 知识图谱上下文
    final kgSummary = knowledgeGraph.getSummary(maxTriples: 10);
    if (kgSummary.isNotEmpty) {
      buffer.writeln(kgSummary);
    }

    // 3. 截断（粗略 token 估算：中文 1 字 ≈ 2 token，英文 1 词 ≈ 1 token）
    final result = buffer.toString();
    if (result.length > maxTokens ~/ 2) {
      return result.substring(0, maxTokens ~/ 2);
    }
    return result;
  }

  /// 获取统计信息
  Map<String, dynamic> getStats() => {
        'vectorMemoryCount': vectorStore.count,
        'knowledgeGraphNodes': knowledgeGraph.nodeCount,
        'knowledgeGraphEdges': knowledgeGraph.edgeCount,
      };
}
