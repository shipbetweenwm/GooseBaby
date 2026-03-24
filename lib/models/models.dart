/// 宠物状态模型
class PetState {
  final double mood;       // 心情值 0-100
  final double hunger;     // 饱食度 0-100
  final double energy;     // 精力值 0-100
  final double clean;      // 清洁度 0-100
  final double health;     // 健康度 0-100
  final int level;         // 等级
  final int exp;           // 经验值
  final int coins;         // 金币
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
    this.health = 90,
    this.level = 1,
    this.exp = 0,
    this.coins = 100,
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
    double? health,
    int? level,
    int? exp,
    int? coins,
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
      health: health ?? this.health,
      level: level ?? this.level,
      exp: exp ?? this.exp,
      coins: coins ?? this.coins,
      companionDays: companionDays ?? this.companionDays,
      currentAction: currentAction ?? this.currentAction,
      emotion: emotion ?? this.emotion,
      x: x ?? this.x,
      y: y ?? this.y,
      facingRight: facingRight ?? this.facingRight,
    );
  }

  /// 整体健康度
  double get overallHealth => (mood + hunger + energy + clean + health) / 5;

  /// 升级所需经验
  int get expToNextLevel => level * 100;

  Map<String, dynamic> toJson() => {
    'mood': mood,
    'hunger': hunger,
    'energy': energy,
    'clean': clean,
    'health': health,
    'level': level,
    'exp': exp,
    'coins': coins,
    'companionDays': companionDays,
    'emotion': emotion,
  };

  factory PetState.fromJson(Map<String, dynamic> json) => PetState(
    mood: (json['mood'] as num?)?.toDouble() ?? 80,
    hunger: (json['hunger'] as num?)?.toDouble() ?? 70,
    energy: (json['energy'] as num?)?.toDouble() ?? 90,
    clean: (json['clean'] as num?)?.toDouble() ?? 85,
    health: (json['health'] as num?)?.toDouble() ?? 90,
    level: json['level'] as int? ?? 1,
    exp: json['exp'] as int? ?? 0,
    coins: json['coins'] as int? ?? 100,
    companionDays: json['companionDays'] as int? ?? 1,
    emotion: json['emotion'] as String? ?? 'normal',
  );
}

/// 商店物品类型
enum ShopItemType { food, toy, medicine, cleaning }

/// 商店物品定义
class ShopItem {
  final String id;
  final String name;
  final String icon;
  final String description;
  final int price;
  final ShopItemType type;
  final double hungerBoost;   // 饱食度提升
  final double moodBoost;     // 心情提升
  final double healthBoost;   // 健康度提升
  final double energyBoost;   // 精力提升
  final double cleanBoost;    // 清洁度提升
  final int expBoost;         // 经验提升

  const ShopItem({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
    required this.price,
    required this.type,
    this.hungerBoost = 0,
    this.moodBoost = 0,
    this.healthBoost = 0,
    this.energyBoost = 0,
    this.cleanBoost = 0,
    this.expBoost = 0,
  });
}

/// 商店物品列表
class ShopData {
  static const List<ShopItem> items = [
    // 食物
    ShopItem(
      id: 'bread', name: '面包', icon: '🍞',
      description: '普通面包，能填饱肚子',
      price: 10, type: ShopItemType.food,
      hungerBoost: 15, moodBoost: 3, expBoost: 3,
    ),
    ShopItem(
      id: 'fish', name: '烤鱼', icon: '🐟',
      description: '鹅宝最爱的烤鱼！',
      price: 25, type: ShopItemType.food,
      hungerBoost: 30, moodBoost: 10, expBoost: 5,
    ),
    ShopItem(
      id: 'cake', name: '蛋糕', icon: '🎂',
      description: '甜甜的蛋糕，心情大好',
      price: 35, type: ShopItemType.food,
      hungerBoost: 10, moodBoost: 25, expBoost: 8,
    ),
    ShopItem(
      id: 'salad', name: '蔬菜沙拉', icon: '🥗',
      description: '健康饮食，均衡营养',
      price: 20, type: ShopItemType.food,
      hungerBoost: 20, moodBoost: 5, healthBoost: 10, expBoost: 4,
    ),
    ShopItem(
      id: 'icecream', name: '冰淇淋', icon: '🍦',
      description: '冰冰凉凉，夏日最爱',
      price: 15, type: ShopItemType.food,
      hungerBoost: 5, moodBoost: 20, expBoost: 3,
    ),
    // 玩具
    ShopItem(
      id: 'ball', name: '小皮球', icon: '⚽',
      description: '和鹅宝一起玩球！',
      price: 30, type: ShopItemType.toy,
      moodBoost: 20, energyBoost: -10, expBoost: 8,
    ),
    ShopItem(
      id: 'music_box', name: '音乐盒', icon: '🎵',
      description: '动听的旋律让鹅宝开心',
      price: 50, type: ShopItemType.toy,
      moodBoost: 30, energyBoost: 10, expBoost: 10,
    ),
    ShopItem(
      id: 'crown', name: '小皇冠', icon: '👑',
      description: '戴上皇冠的鹅宝超级自信！',
      price: 80, type: ShopItemType.toy,
      moodBoost: 40, expBoost: 15,
    ),
    // 药物
    ShopItem(
      id: 'vitamin', name: '维生素', icon: '💊',
      description: '补充营养，增强体质',
      price: 20, type: ShopItemType.medicine,
      healthBoost: 20, expBoost: 3,
    ),
    ShopItem(
      id: 'potion', name: '元气药水', icon: '🧪',
      description: '恢复精力的神奇药水',
      price: 30, type: ShopItemType.medicine,
      energyBoost: 30, healthBoost: 10, expBoost: 5,
    ),
    ShopItem(
      id: 'elixir', name: '万能药剂', icon: '✨',
      description: '全面恢复的高级药剂',
      price: 100, type: ShopItemType.medicine,
      hungerBoost: 15, moodBoost: 15, healthBoost: 30, energyBoost: 20, expBoost: 12,
    ),
    // 清洁
    ShopItem(
      id: 'soap', name: '香皂', icon: '🧼',
      description: '基础清洁，让鹅宝干干净净',
      price: 15, type: ShopItemType.cleaning,
      cleanBoost: 30, moodBoost: 5, expBoost: 3,
    ),
    ShopItem(
      id: 'shampoo', name: '泡泡浴', icon: '🛁',
      description: '鹅宝最爱的泡泡浴时光',
      price: 30, type: ShopItemType.cleaning,
      cleanBoost: 60, moodBoost: 15, expBoost: 6,
    ),
    ShopItem(
      id: 'spa', name: 'SPA套餐', icon: '💎',
      description: '顶级SPA，全面焕新',
      price: 60, type: ShopItemType.cleaning,
      cleanBoost: 100, moodBoost: 25, healthBoost: 10, expBoost: 10,
    ),
  ];

  static List<ShopItem> getByType(ShopItemType type) =>
      items.where((i) => i.type == type).toList();
}

/// 消息附件类型
enum AttachmentType { image, file, code }

/// 消息附件（图片/文件/代码块）
class MessageAttachment {
  final AttachmentType type;
  final String? filePath;     // 本地文件路径
  final String? fileName;     // 文件名
  final int? fileSize;        // 文件大小（字节）
  final String? mimeType;     // MIME 类型
  final String? code;         // 代码内容（type=code 时）
  final String? language;     // 代码语言（type=code 时）

  const MessageAttachment({
    required this.type,
    this.filePath,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.code,
    this.language,
  });

  /// 是否是图片文件
  bool get isImage => type == AttachmentType.image;

  /// 格式化文件大小
  String get formattedSize {
    if (fileSize == null) return '';
    if (fileSize! < 1024) return '${fileSize}B';
    if (fileSize! < 1024 * 1024) return '${(fileSize! / 1024).toStringAsFixed(1)}KB';
    return '${(fileSize! / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'filePath': filePath,
    'fileName': fileName,
    'fileSize': fileSize,
    'mimeType': mimeType,
    'code': code,
    'language': language,
  };

  factory MessageAttachment.fromJson(Map<String, dynamic> json) {
    return MessageAttachment(
      type: AttachmentType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => AttachmentType.file,
      ),
      filePath: json['filePath'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: json['fileSize'] as int?,
      mimeType: json['mimeType'] as String?,
      code: json['code'] as String?,
      language: json['language'] as String?,
    );
  }
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
  final List<MessageAttachment> attachments; // 附件列表

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.emotion,
    this.skillResult,
    this.isStreaming = false,
    List<MessageAttachment>? attachments,
  }) : timestamp = timestamp ?? DateTime.now(),
       attachments = attachments ?? const [];

  ChatMessage copyWith({
    String? content,
    String? emotion,
    String? skillResult,
    bool? isStreaming,
    List<MessageAttachment>? attachments,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      timestamp: timestamp,
      emotion: emotion ?? this.emotion,
      skillResult: skillResult ?? this.skillResult,
      isStreaming: isStreaming ?? this.isStreaming,
      attachments: attachments ?? this.attachments,
    );
  }

  Map<String, dynamic> toApiMessage() => {
    'role': role,
    'content': content,
  };

  bool get hasAttachments => attachments.isNotEmpty;
  bool get hasImages => attachments.any((a) => a.isImage);
  bool get hasFiles => attachments.any((a) => a.type == AttachmentType.file);
  bool get hasCode => attachments.any((a) => a.type == AttachmentType.code);
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

  /// 是否启用联网搜索（各厂商 API 参数不同，由 provider 自行适配）
  final bool enableWebSearch;

  /// 是否启用深度思考/推理增强（各厂商参数不同，由 provider 自行适配）
  final bool enableDeepThink;

  const LLMConfig({
    required this.provider,
    required this.model,
    this.apiKey = '',
    this.baseUrl,
    this.secretKey,
    this.temperature = 0.8,
    this.maxTokens = 81920,
    this.enableWebSearch = false,
    this.enableDeepThink = false,
  });

  /// 复制并修改部分字段
  LLMConfig copyWith({
    String? provider,
    String? model,
    String? apiKey,
    String? baseUrl,
    String? secretKey,
    double? temperature,
    int? maxTokens,
    bool? enableWebSearch,
    bool? enableDeepThink,
  }) {
    return LLMConfig(
      provider: provider ?? this.provider,
      model: model ?? this.model,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      secretKey: secretKey ?? this.secretKey,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      enableWebSearch: enableWebSearch ?? this.enableWebSearch,
      enableDeepThink: enableDeepThink ?? this.enableDeepThink,
    );
  }

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'model': model,
    'apiKey': apiKey,
    'baseUrl': baseUrl,
    'secretKey': secretKey,
    'temperature': temperature,
    'maxTokens': maxTokens,
    'enableWebSearch': enableWebSearch,
    'enableDeepThink': enableDeepThink,
  };

  factory LLMConfig.fromJson(Map<String, dynamic> json) => LLMConfig(
    provider: json['provider'] as String? ?? 'qwen',
    model: json['model'] as String? ?? 'qwen-turbo',
    apiKey: json['apiKey'] as String? ?? '',
    baseUrl: json['baseUrl'] as String?,
    secretKey: json['secretKey'] as String?,
    temperature: (json['temperature'] as num?)?.toDouble() ?? 0.8,
    maxTokens: json['maxTokens'] as int? ?? 81920,
    enableWebSearch: json['enableWebSearch'] as bool? ?? false,
    enableDeepThink: json['enableDeepThink'] as bool? ?? false,
  );
}

/// 宠物日记条目
class DiaryEntry {
  final String id;
  final DateTime date;
  final String content;           // 日记内容（鹅宝口吻）
  final String mood;              // 当日心情 (happy/normal/sad/excited)
  final int interactionCount;     // 当日互动次数
  final int messageCount;         // 当日对话消息数
  final List<String> highlights;  // 当日高光时刻
  final double? avgHappiness;     // 当日平均心情值
  final String? weather;          // 当日天气
  final String? specialEvent;     // 特殊事件（节日、里程碑等）

  const DiaryEntry({
    required this.id,
    required this.date,
    required this.content,
    this.mood = 'normal',
    this.interactionCount = 0,
    this.messageCount = 0,
    this.highlights = const [],
    this.avgHappiness,
    this.weather,
    this.specialEvent,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'date': date.toIso8601String(),
    'content': content,
    'mood': mood,
    'interactionCount': interactionCount,
    'messageCount': messageCount,
    'highlights': highlights,
    'avgHappiness': avgHappiness,
    'weather': weather,
    'specialEvent': specialEvent,
  };

  factory DiaryEntry.fromJson(Map<String, dynamic> json) => DiaryEntry(
    id: json['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
    date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
    content: json['content'] as String? ?? '',
    mood: json['mood'] as String? ?? 'normal',
    interactionCount: json['interactionCount'] as int? ?? 0,
    messageCount: json['messageCount'] as int? ?? 0,
    highlights: (json['highlights'] as List?)?.map((e) => e as String).toList() ?? [],
    avgHappiness: (json['avgHappiness'] as num?)?.toDouble(),
    weather: json['weather'] as String?,
    specialEvent: json['specialEvent'] as String?,
  );

  /// 格式化日期显示
  String get formattedDate {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final entryDay = DateTime(date.year, date.month, date.day);
    
    if (entryDay == today) return '今天';
    if (entryDay == today.subtract(const Duration(days: 1))) return '昨天';
    
    return '${date.month}月${date.day}日';
  }

  /// 星期几
  String get weekdayName {
    const names = ['一', '二', '三', '四', '五', '六', '日'];
    return '周${names[date.weekday - 1]}';
  }
}
