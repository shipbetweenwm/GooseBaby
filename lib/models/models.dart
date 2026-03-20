/// 宠物状态模型
class PetState {
  final double mood;       // 心情值 0-100
  final double hunger;     // 饱食度 0-100
  final double energy;     // 精力值 0-100
  final double clean;      // 清洁度 0-100
  final int level;         // 等级
  final int exp;           // 经验值
  final int companionDays; // 陪伴天数
  final String currentAction; // 当前动作
  final String emotion;    // 当前情绪
  final double x;          // 位置 X
  final double y;          // 位置 Y
  final bool facingRight;  // 朝向

  const PetState({
    this.mood = 80,
    this.hunger = 70,
    this.energy = 90,
    this.clean = 85,
    this.level = 1,
    this.exp = 0,
    this.companionDays = 1,
    this.currentAction = 'idle',
    this.emotion = 'normal',
    this.x = 0,
    this.y = 0,
    this.facingRight = true,
  });

  PetState copyWith({
    double? mood,
    double? hunger,
    double? energy,
    double? clean,
    int? level,
    int? exp,
    int? companionDays,
    String? currentAction,
    String? emotion,
    double? x,
    double? y,
    bool? facingRight,
  }) {
    return PetState(
      mood: mood ?? this.mood,
      hunger: hunger ?? this.hunger,
      energy: energy ?? this.energy,
      clean: clean ?? this.clean,
      level: level ?? this.level,
      exp: exp ?? this.exp,
      companionDays: companionDays ?? this.companionDays,
      currentAction: currentAction ?? this.currentAction,
      emotion: emotion ?? this.emotion,
      x: x ?? this.x,
      y: y ?? this.y,
      facingRight: facingRight ?? this.facingRight,
    );
  }

  /// 整体健康度
  double get overallHealth => (mood + hunger + energy + clean) / 4;

  /// 升级所需经验
  int get expToNextLevel => level * 100;

  Map<String, dynamic> toJson() => {
    'mood': mood,
    'hunger': hunger,
    'energy': energy,
    'clean': clean,
    'level': level,
    'exp': exp,
    'companionDays': companionDays,
    'emotion': emotion,
  };

  factory PetState.fromJson(Map<String, dynamic> json) => PetState(
    mood: (json['mood'] as num?)?.toDouble() ?? 80,
    hunger: (json['hunger'] as num?)?.toDouble() ?? 70,
    energy: (json['energy'] as num?)?.toDouble() ?? 90,
    clean: (json['clean'] as num?)?.toDouble() ?? 85,
    level: json['level'] as int? ?? 1,
    exp: json['exp'] as int? ?? 0,
    companionDays: json['companionDays'] as int? ?? 1,
    emotion: json['emotion'] as String? ?? 'normal',
  );
}

/// 聊天消息模型
class ChatMessage {
  final String id;
  final String role;     // 'user' | 'assistant' | 'system'
  final String content;
  final DateTime timestamp;
  final String? emotion; // 鹅宝的情绪标签
  final String? skillResult; // 技能执行结果
  final bool isStreaming;

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.emotion,
    this.skillResult,
    this.isStreaming = false,
  }) : timestamp = timestamp ?? DateTime.now();

  ChatMessage copyWith({
    String? content,
    String? emotion,
    String? skillResult,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      timestamp: timestamp,
      emotion: emotion ?? this.emotion,
      skillResult: skillResult ?? this.skillResult,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }

  Map<String, dynamic> toApiMessage() => {
    'role': role,
    'content': content,
  };
}

/// LLM 配置模型
class LLMConfig {
  final String provider;   // 'qwen' | 'hunyuan' | 'openai' | 'claude' | 'ollama'
  final String model;      // 模型名称
  final String apiKey;
  final String? baseUrl;
  final String? secretKey;  // 混元需要
  final double temperature;
  final int maxTokens;

  const LLMConfig({
    required this.provider,
    required this.model,
    this.apiKey = '',
    this.baseUrl,
    this.secretKey,
    this.temperature = 0.8,
    this.maxTokens = 2048,
  });

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'model': model,
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'secretKey': secretKey,
    'temperature': temperature,
    'maxTokens': maxTokens,
  };

  factory LLMConfig.fromJson(Map<String, dynamic> json) => LLMConfig(
    provider: json['provider'] as String? ?? 'qwen',
    model: json['model'] as String? ?? 'qwen-turbo',
    apiKey: json['apiKey'] as String? ?? '',
    baseUrl: json['baseUrl'] as String?,
    secretKey: json['secretKey'] as String?,
    temperature: (json['temperature'] as num?)?.toDouble() ?? 0.8,
    maxTokens: json['maxTokens'] as int? ?? 2048,
  );
}
