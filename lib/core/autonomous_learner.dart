import 'dart:collection';
import 'dart:convert';
import '../models/models.dart';
import 'emotion_analyzer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 自主学习引擎
/// 负责学习用户的行为模式、偏好，并提供主动提醒
class AutonomousLearner {
  static const String _storageKey = 'autonomous_learner_data';
  
  /// 行为模式学习者
  final BehaviorPatternLearner behaviorLearner;
  
  /// 偏好学习者
  final PreferenceLearner preferenceLearner;
  
  /// 知识更新器
  final KnowledgeUpdater knowledgeUpdater;
  
  /// 主动提醒管理器
  final ProactiveReminder reminderManager;
  
  AutonomousLearner._({
    required this.behaviorLearner,
    required this.preferenceLearner,
    required this.knowledgeUpdater,
    required this.reminderManager,
  });
  
  /// 创建自主学习引擎实例
  static Future<AutonomousLearner> create() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_storageKey);
    
    AutonomousLearnerData data;
    if (jsonString != null) {
      try {
        data = AutonomousLearnerData.fromJson(json.decode(jsonString));
      } catch (e) {
        data = AutonomousLearnerData();
      }
    } else {
      data = AutonomousLearnerData();
    }
    
    return AutonomousLearner._(
      behaviorLearner: BehaviorPatternLearner(data.behaviorPatterns),
      preferenceLearner: PreferenceLearner(data.preferences),
      knowledgeUpdater: KnowledgeUpdater(data.knowledge),
      reminderManager: ProactiveReminder(data.reminders),
    );
  }
  
  /// 保存学习数据
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    final data = AutonomousLearnerData(
      behaviorPatterns: behaviorLearner.patterns,
      preferences: preferenceLearner.preferences,
      knowledge: knowledgeUpdater.knowledge,
      reminders: reminderManager.reminders,
    );
    await prefs.setString(_storageKey, json.encode(data.toJson()));
  }
  
  /// 记录用户活动（用于学习）
  Future<void> recordActivity({
    required String activityType,
    required DateTime timestamp,
    String? content,
    EmotionResult? emotion,
    int? duration,
    Map<String, dynamic>? metadata,
  }) async {
    // 1. 学习行为模式
    behaviorLearner.learn(activityType, timestamp, metadata: metadata);
    
    // 2. 学习偏好
    if (content != null && emotion != null) {
      preferenceLearner.learn(content, emotion, timestamp);
    }
    
    // 3. 更新知识库
    knowledgeUpdater.update(activityType, timestamp, metadata: metadata);
    
    await save();
  }
  
  /// 生成主动提醒
  List<Reminder> generateReminders({
    required PetState petState,
    required DateTime currentTime,
  }) {
    return reminderManager.generateReminders(
      petState: petState,
      currentTime: currentTime,
      behaviorPatterns: behaviorLearner.patterns,
      preferences: preferenceLearner.preferences,
    );
  }
  
  /// 获取用户行为洞察
  UserInsights getInsights() {
    return UserInsights(
      activeHours: behaviorLearner.getActiveHours(),
      preferredTone: preferenceLearner.getPreferredTone(),
      emotionalPatterns: behaviorLearner.getEmotionalPatterns(),
      interests: knowledgeUpdater.getTopInterests(),
      relationshipHealth: _calculateRelationshipHealth(),
    );
  }
  
  /// 计算关系健康度
  double _calculateRelationshipHealth() {
    // 基于互动频率、情感多样性、依赖度等指标计算
    final engagement = behaviorLearner.getEngagementScore();
    final emotionalDiversity = preferenceLearner.getEmotionalDiversity();
    final dependency = behaviorLearner.getDependencyScore();
    
    // 理想状态：高参与度、中等情感多样性、低依赖度
    final healthScore = (engagement * 0.4 + emotionalDiversity * 0.4 + (1 - dependency) * 0.2);
    return healthScore.clamp(0.0, 1.0);
  }
  
  /// 检测不健康模式
  List<HealthAlert> detectUnhealthyPatterns() {
    final alerts = <HealthAlert>[];
    
    // 检测过度依赖
    final dependency = behaviorLearner.getDependencyScore();
    if (dependency > 0.8) {
      alerts.add(HealthAlert(
        type: HealthAlertType.overDependency,
        severity: AlertSeverity.high,
        message: '检测到过度依赖倾向，建议引导用户拓展现实社交',
        recommendation: '可以建议用户："要不要和朋友出去走走呢？"或者分享社交活动建议',
      ));
    }
    
    // 检测情绪持续低落
    final recentEmotions = preferenceLearner.getRecentEmotions(days: 7);
    if (recentEmotions.isNotEmpty) {
      final negativeRatio = recentEmotions.where((e) => 
        e.emotion == EmotionAnalyzer.sad || 
        e.emotion == EmotionAnalyzer.anxious ||
        e.emotion == EmotionAnalyzer.frustrated
      ).length / recentEmotions.length;
      
      if (negativeRatio > 0.6) {
        alerts.add(HealthAlert(
          type: HealthAlertType.prolongedNegativeMood,
          severity: AlertSeverity.medium,
          message: '用户近期情绪持续低落（${(negativeRatio * 100).toInt()}%负面情绪）',
          recommendation: '可以主动关心："最近是不是遇到什么困难了？要不要聊聊？"或建议专业帮助',
        ));
      }
    }
    
    // 检测作息不规律
    final activeHours = behaviorLearner.getActiveHours();
    if (activeHours.nightActivityRatio > 0.4) {
      alerts.add(HealthAlert(
        type: HealthAlertType.irregularSchedule,
        severity: AlertSeverity.low,
        message: '检测到夜间活动频繁（${(activeHours.nightActivityRatio * 100).toInt()}%在夜间）',
        recommendation: '可以温馨提醒："早点休息对身体好哦~"',
      ));
    }
    
    return alerts;
  }
}

/// 行为模式学习器
class BehaviorPatternLearner {
  final Map<String, BehaviorPattern> patterns;
  
  BehaviorPatternLearner(Map<String, BehaviorPattern>? patterns) 
    : patterns = patterns ?? {};
  
  /// 学习行为模式
  void learn(String activityType, DateTime timestamp, {Map<String, dynamic>? metadata}) {
    final hour = timestamp.hour;
    final weekday = timestamp.weekday;
    
    // 更新时间分布模式
    final key = '${activityType}_time';
    patterns[key] = patterns[key]?.recordOccurrence(hour, weekday, metadata: metadata) 
      ?? BehaviorPattern(hour: hour, weekday: weekday, metadata: metadata);
    
    // 更新活动频率
    final freqKey = '${activityType}_frequency';
    patterns[freqKey] = patterns[freqKey]?.increment() 
      ?? BehaviorPattern(count: 1);
  }
  
  /// 获取活跃时间段
  ActiveHours getActiveHours() {
    final hourCounts = List.filled(24, 0);
    int totalCount = 0;
    
    patterns.forEach((key, pattern) {
      if (key.endsWith('_time')) {
        final hour = pattern.hour;
        if (hour != null) {
          hourCounts[hour]++;
          totalCount++;
        }
      }
    });
    
    if (totalCount == 0) {
      return ActiveHours(peakHours: [], nightActivityRatio: 0);
    }
    
    // 找出活跃高峰（超过平均值的时段）
    final avg = totalCount / 24;
    final peakHours = <int>[];
    for (int i = 0; i < 24; i++) {
      if (hourCounts[i] > avg) {
        peakHours.add(i);
      }
    }
    
    // 计算夜间活动比例（22:00-6:00）
    final nightCount = hourCounts.sublist(22, 24).reduce((a, b) => a + b) +
                       hourCounts.sublist(0, 6).reduce((a, b) => a + b);
    final nightRatio = nightCount / totalCount;
    
    return ActiveHours(
      peakHours: peakHours,
      nightActivityRatio: nightRatio,
      hourDistribution: hourCounts,
    );
  }
  
  /// 获取情绪模式
  List<EmotionPattern> getEmotionalPatterns() {
    final emotionPatterns = <String, List<int>>{};
    
    patterns.forEach((key, pattern) {
      if (key.contains('emotion') && pattern.hour != null) {
        final emotion = key.split('_')[0];
        emotionPatterns[emotion] = emotionPatterns[emotion] ?? [];
        emotionPatterns[emotion]!.add(pattern.hour!);
      }
    });
    
    return emotionPatterns.entries.map((e) => EmotionPattern(
      emotion: e.key,
      typicalHours: e.value,
    )).toList();
  }
  
  /// 获取参与度评分
  double getEngagementScore() {
    int totalInteractions = 0;
    patterns.forEach((key, pattern) {
      if (key.endsWith('_frequency')) {
        totalInteractions += pattern.count;
      }
    });
    
    // 归一化到 0-1（假设每天20次互动为满分）
    return (totalInteractions / 600).clamp(0.0, 1.0);
  }
  
  /// 获取依赖度评分
  double getDependencyScore() {
    // 基于互动频率、时长、主动搭话等指标计算
    final engagement = getEngagementScore();
    final activeHours = getActiveHours();
    
    // 活跃时段越多，依赖度可能越高
    final timeSpread = activeHours.peakHours.length / 24;
    
    return (engagement * 0.6 + timeSpread * 0.4).clamp(0.0, 1.0);
  }
}

/// 偏好学习器
class PreferenceLearner {
  final Map<String, UserPreference> preferences;
  final Queue<EmotionRecord> recentEmotions;
  
  PreferenceLearner(Map<String, UserPreference>? preferences)
    : preferences = preferences ?? {},
      recentEmotions = Queue();
  
  /// 学习用户偏好
  void learn(String content, EmotionResult emotion, DateTime timestamp) {
    // 记录最近情绪
    recentEmotions.add(EmotionRecord(
      emotion: emotion.emotion,
      intensity: emotion.intensity,
      timestamp: timestamp,
    ));
    
    // 保持最近30天的记录
    final cutoff = timestamp.subtract(const Duration(days: 30));
    while (recentEmotions.isNotEmpty && recentEmotions.first.timestamp.isBefore(cutoff)) {
      recentEmotions.removeFirst();
    }
    
    // 学习消息长度偏好
    final lengthPref = _getOrCreatePreference('message_length');
    final length = content.length;
    if (length < 20) {
      lengthPref.updatePreference('short');
    } else if (length > 100) {
      lengthPref.updatePreference('long');
    } else {
      lengthPref.updatePreference('medium');
    }
    
    // 学习语气词使用偏好
    final emojiCount = EmotionAnalyzer.countEmojis(content);
    final emojiPref = _getOrCreatePreference('emoji_usage');
    if (emojiCount > 3) {
      emojiPref.updatePreference('frequent');
    } else if (emojiCount > 0) {
      emojiPref.updatePreference('moderate');
    } else {
      emojiPref.updatePreference('rare');
    }
    
    // 学习情绪偏好
    final emotionPref = _getOrCreatePreference('dominant_emotion');
    emotionPref.updatePreference(emotion.emotion);
  }
  
  UserPreference _getOrCreatePreference(String key) {
    return preferences[key] ??= UserPreference(key: key);
  }
  
  /// 获取偏好的语气
  String getPreferredTone() {
    final lengthPref = preferences['message_length'];
    final emojiPref = preferences['emoji_usage'];
    
    if (lengthPref == null || emojiPref == null) {
      return 'balanced'; // 默认平衡语气
    }
    
    final lengthFav = lengthPref.favorite;
    final emojiFav = emojiPref.favorite;
    
    // 简短 + 少表情 → 简洁克制
    if (lengthFav == 'short' && emojiFav == 'rare') {
      return 'concise';
    }
    
    // 长 + 多表情 → 温柔详细
    if (lengthFav == 'long' && emojiFav == 'frequent') {
      return 'warm_detailed';
    }
    
    // 多表情 → 活泼可爱
    if (emojiFav == 'frequent') {
      return 'playful';
    }
    
    return 'balanced';
  }
  
  /// 获取情绪多样性
  double getEmotionalDiversity() {
    if (recentEmotions.isEmpty) return 0.5;
    
    // 统计各情绪的比例
    final counts = <String, int>{};
    for (final record in recentEmotions) {
      counts[record.emotion] = (counts[record.emotion] ?? 0) + 1;
    }
    
    // 计算香农熵
    final total = recentEmotions.length.toDouble();
    double entropy = 0;
    counts.forEach((emotion, count) {
      final p = count / total;
      entropy -= p * (p == 0 ? 0 : (p.toDouble() * _log2(p)));
    });
    
    // 归一化到 0-1（假设最高熵为 log2(9) ≈ 3.17，因为有9种情绪）
    return (entropy / 3.17).clamp(0.0, 1.0);
  }
  
  double _log2(double x) => x <= 0 ? 0 : (x == 1 ? 0 : (x * 0.6931471805599453)); // ln(2)
  
  /// 获取最近情绪记录
  List<EmotionRecord> getRecentEmotions({int days = 7}) {
    final cutoff = DateTime.now().subtract(Duration(days: days));
    return recentEmotions.where((r) => r.timestamp.isAfter(cutoff)).toList();
  }
}

/// 知识更新器
class KnowledgeUpdater {
  final Map<String, Knowledge> knowledge;
  
  KnowledgeUpdater(Map<String, Knowledge>? knowledge)
    : knowledge = knowledge ?? {};
  
  /// 更新知识库
  void update(String activityType, DateTime timestamp, {Map<String, dynamic>? metadata}) {
    // 记录活动知识
    final key = 'activity_$activityType';
    knowledge[key] = knowledge[key]?.record(timestamp, metadata: metadata)
      ?? Knowledge(type: 'activity', lastUpdated: timestamp, metadata: metadata);
    
    // 定期清理过时知识（保留最近90天）
    final cutoff = timestamp.subtract(const Duration(days: 90));
    knowledge.removeWhere((key, value) => value.lastUpdated.isBefore(cutoff));
  }
  
  /// 获取用户兴趣（高频活动）
  List<String> getTopInterests({int limit = 5}) {
    final activities = <String, int>{};
    
    knowledge.forEach((key, value) {
      if (key.startsWith('activity_')) {
        final activity = key.substring(9);
        activities[activity] = (activities[activity] ?? 0) + value.frequency;
      }
    });
    
    final sorted = activities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    return sorted.take(limit).map((e) => e.key).toList();
  }
}

/// 主动提醒管理器
class ProactiveReminder {
  final List<Reminder> reminders;
  
  ProactiveReminder(List<Reminder>? reminders)
    : reminders = reminders ?? [];
  
  /// 生成提醒
  List<Reminder> generateReminders({
    required PetState petState,
    required DateTime currentTime,
    required Map<String, BehaviorPattern> behaviorPatterns,
    required Map<String, UserPreference> preferences,
  }) {
    final generated = <Reminder>[];
    
    // 1. 检查是否在习惯活动时间
    final activeHours = _extractActiveHours(behaviorPatterns);
    if (activeHours.contains(currentTime.hour)) {
      // 生成问候提醒
      generated.add(Reminder(
        type: ReminderType.greeting,
        message: _generateGreeting(currentTime, petState),
        priority: ReminderPriority.normal,
        scheduledTime: currentTime,
      ));
    }
    
    // 2. 检查是否需要情感关怀
    final emotionPref = preferences['dominant_emotion'];
    if (emotionPref != null && emotionPref.favorite == EmotionAnalyzer.sad) {
      // 用户经常悲伤，主动关心
      generated.add(Reminder(
        type: ReminderType.emotionalCare,
        message: '最近是不是压力有点大？要不要聊聊？',
        priority: ReminderPriority.high,
        scheduledTime: currentTime,
      ));
    }
    
    // 3. 检查互动间隔
    final lastInteraction = _getLastInteractionTime(behaviorPatterns);
    if (lastInteraction != null) {
      final interval = currentTime.difference(lastInteraction);
      if (interval.inHours >= 4) {
        // 超过4小时没互动，主动搭话
        generated.add(Reminder(
          type: ReminderType.checkIn,
          message: _generateCheckIn(currentTime, petState),
          priority: ReminderPriority.low,
          scheduledTime: currentTime,
        ));
      }
    }
    
    return generated;
  }
  
  List<int> _extractActiveHours(Map<String, BehaviorPattern> patterns) {
    final hours = <int>{};
    patterns.forEach((key, pattern) {
      if (key.endsWith('_time') && pattern.hour != null) {
        hours.add(pattern.hour!);
      }
    });
    return hours.toList()..sort();
  }
  
  String _generateGreeting(DateTime time, PetState petState) {
    final hour = time.hour;
    
    if (hour >= 6 && hour < 9) {
      final greetings = [
        '早上好~今天也要元气满满哦！',
        '早安！昨晚睡得好吗？',
        '早上好呀~新的一天开始了！',
      ];
      return greetings[hour % greetings.length];
    } else if (hour >= 12 && hour < 14) {
      return '中午啦~记得吃饭哦！';
    } else if (hour >= 18 && hour < 20) {
      return '晚上好~今天过得怎么样？';
    } else if (hour >= 22 || hour < 6) {
      return '这么晚还在呀~早点休息哦！';
    }
    
    return '嗨~在忙什么呢？';
  }
  
  String _generateCheckIn(DateTime time, PetState petState) {
    final checkIns = [
      '好久没聊了，最近怎么样？',
      '想你了~在干嘛呢？',
      '突然想到你，来打个招呼~',
    ];
    return checkIns[time.minute % checkIns.length];
  }
  
  DateTime? _getLastInteractionTime(Map<String, BehaviorPattern> patterns) {
    DateTime? lastTime;
    patterns.forEach((key, pattern) {
      if (pattern.lastOccurrence != null) {
        if (lastTime == null || pattern.lastOccurrence!.isAfter(lastTime!)) {
          lastTime = pattern.lastOccurrence;
        }
      }
    });
    return lastTime;
  }
}

// ===== 数据模型 =====

/// 自主学习数据
class AutonomousLearnerData {
  final Map<String, BehaviorPattern> behaviorPatterns;
  final Map<String, UserPreference> preferences;
  final Map<String, Knowledge> knowledge;
  final List<Reminder> reminders;
  
  AutonomousLearnerData({
    Map<String, BehaviorPattern>? behaviorPatterns,
    Map<String, UserPreference>? preferences,
    Map<String, Knowledge>? knowledge,
    List<Reminder>? reminders,
  }) : behaviorPatterns = behaviorPatterns ?? {},
       preferences = preferences ?? {},
       knowledge = knowledge ?? {},
       reminders = reminders ?? [];
  
  Map<String, dynamic> toJson() => {
    'behaviorPatterns': Map.fromEntries(
      behaviorPatterns.entries.map((e) => MapEntry(e.key, e.value.toJson()))
    ),
    'preferences': Map.fromEntries(
      preferences.entries.map((e) => MapEntry(e.key, e.value.toJson()))
    ),
    'knowledge': Map.fromEntries(
      knowledge.entries.map((e) => MapEntry(e.key, e.value.toJson()))
    ),
    'reminders': reminders.map((r) => r.toJson()).toList(),
  };
  
  factory AutonomousLearnerData.fromJson(Map<String, dynamic> json) {
    return AutonomousLearnerData(
      behaviorPatterns: Map.fromEntries(
        (json['behaviorPatterns'] as Map<String, dynamic>?)?.entries.map((e) => 
          MapEntry(e.key, BehaviorPattern.fromJson(e.value as Map<String, dynamic>))
        ) ?? {}
      ),
      preferences: Map.fromEntries(
        (json['preferences'] as Map<String, dynamic>?)?.entries.map((e) => 
          MapEntry(e.key, UserPreference.fromJson(e.value as Map<String, dynamic>))
        ) ?? {}
      ),
      knowledge: Map.fromEntries(
        (json['knowledge'] as Map<String, dynamic>?)?.entries.map((e) => 
          MapEntry(e.key, Knowledge.fromJson(e.value as Map<String, dynamic>))
        ) ?? {}
      ),
      reminders: (json['reminders'] as List?)?.map((r) => 
        Reminder.fromJson(r as Map<String, dynamic>)
      ).toList() ?? [],
    );
  }
}

/// 行为模式
class BehaviorPattern {
  final int? hour;
  final int? weekday;
  final int count;
  final DateTime? lastOccurrence;
  final Map<String, dynamic>? metadata;
  
  BehaviorPattern({
    this.hour,
    this.weekday,
    this.count = 1,
    this.lastOccurrence,
    this.metadata,
  });
  
  BehaviorPattern recordOccurrence(int hour, int weekday, {Map<String, dynamic>? metadata}) {
    return BehaviorPattern(
      hour: hour,
      weekday: weekday,
      count: count + 1,
      lastOccurrence: DateTime.now(),
      metadata: metadata ?? this.metadata,
    );
  }
  
  BehaviorPattern increment() {
    return BehaviorPattern(
      hour: hour,
      weekday: weekday,
      count: count + 1,
      lastOccurrence: DateTime.now(),
      metadata: metadata,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'hour': hour,
    'weekday': weekday,
    'count': count,
    'lastOccurrence': lastOccurrence?.toIso8601String(),
    'metadata': metadata,
  };
  
  factory BehaviorPattern.fromJson(Map<String, dynamic> json) => BehaviorPattern(
    hour: json['hour'] as int?,
    weekday: json['weekday'] as int?,
    count: json['count'] as int? ?? 1,
    lastOccurrence: json['lastOccurrence'] != null 
      ? DateTime.parse(json['lastOccurrence'] as String)
      : null,
    metadata: json['metadata'] as Map<String, dynamic>?,
  );
}

/// 用户偏好
class UserPreference {
  final String key;
  final Map<String, int> options;
  final DateTime lastUpdated;
  
  UserPreference({
    required this.key,
    Map<String, int>? options,
    DateTime? lastUpdated,
  }) : options = options ?? {},
       lastUpdated = lastUpdated ?? DateTime.now();
  
  void updatePreference(String option) {
    options[option] = (options[option] ?? 0) + 1;
  }
  
  String get favorite {
    if (options.isEmpty) return '';
    final sorted = options.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.first.key;
  }
  
  Map<String, dynamic> toJson() => {
    'key': key,
    'options': options,
    'lastUpdated': lastUpdated.toIso8601String(),
  };
  
  factory UserPreference.fromJson(Map<String, dynamic> json) => UserPreference(
    key: json['key'] as String,
    options: Map<String, int>.from(json['options'] as Map? ?? {}),
    lastUpdated: DateTime.parse(json['lastUpdated'] as String),
  );
}

/// 知识记录
class Knowledge {
  final String type;
  final int frequency;
  final DateTime lastUpdated;
  final Map<String, dynamic>? metadata;
  
  Knowledge({
    required this.type,
    this.frequency = 1,
    DateTime? lastUpdated,
    this.metadata,
  }) : lastUpdated = lastUpdated ?? DateTime.now();
  
  Knowledge record(DateTime timestamp, {Map<String, dynamic>? metadata}) {
    return Knowledge(
      type: type,
      frequency: frequency + 1,
      lastUpdated: timestamp,
      metadata: metadata ?? this.metadata,
    );
  }
  
  Map<String, dynamic> toJson() => {
    'type': type,
    'frequency': frequency,
    'lastUpdated': lastUpdated.toIso8601String(),
    'metadata': metadata,
  };
  
  factory Knowledge.fromJson(Map<String, dynamic> json) => Knowledge(
    type: json['type'] as String,
    frequency: json['frequency'] as int? ?? 1,
    lastUpdated: DateTime.parse(json['lastUpdated'] as String),
    metadata: json['metadata'] as Map<String, dynamic>?,
  );
}

/// 提醒
class Reminder {
  final ReminderType type;
  final String message;
  final ReminderPriority priority;
  final DateTime scheduledTime;
  final bool isDelivered;
  
  Reminder({
    required this.type,
    required this.message,
    required this.priority,
    required this.scheduledTime,
    this.isDelivered = false,
  });
  
  Map<String, dynamic> toJson() => {
    'type': type.name,
    'message': message,
    'priority': priority.name,
    'scheduledTime': scheduledTime.toIso8601String(),
    'isDelivered': isDelivered,
  };
  
  factory Reminder.fromJson(Map<String, dynamic> json) => Reminder(
    type: ReminderType.values.firstWhere((e) => e.name == json['type']),
    message: json['message'] as String,
    priority: ReminderPriority.values.firstWhere((e) => e.name == json['priority']),
    scheduledTime: DateTime.parse(json['scheduledTime'] as String),
    isDelivered: json['isDelivered'] as bool? ?? false,
  );
}

enum ReminderType {
  greeting,        // 问候
  checkIn,         // 打招呼
  emotionalCare,   // 情感关怀
  schedule,        // 日程提醒
  health,          // 健康提醒
}

enum ReminderPriority {
  low,
  normal,
  high,
}

/// 活跃时间段
class ActiveHours {
  final List<int> peakHours;
  final double nightActivityRatio;
  final List<int>? hourDistribution;
  
  ActiveHours({
    required this.peakHours,
    required this.nightActivityRatio,
    this.hourDistribution,
  });
}

/// 情绪模式
class EmotionPattern {
  final String emotion;
  final List<int> typicalHours;
  
  EmotionPattern({
    required this.emotion,
    required this.typicalHours,
  });
}

/// 情绪记录
class EmotionRecord {
  final String emotion;
  final double intensity;
  final DateTime timestamp;
  
  EmotionRecord({
    required this.emotion,
    required this.intensity,
    required this.timestamp,
  });
}

/// 用户洞察
class UserInsights {
  final ActiveHours activeHours;
  final String preferredTone;
  final List<EmotionPattern> emotionalPatterns;
  final List<String> interests;
  final double relationshipHealth;
  
  UserInsights({
    required this.activeHours,
    required this.preferredTone,
    required this.emotionalPatterns,
    required this.interests,
    required this.relationshipHealth,
  });
}

/// 健康警告
class HealthAlert {
  final HealthAlertType type;
  final AlertSeverity severity;
  final String message;
  final String recommendation;
  
  HealthAlert({
    required this.type,
    required this.severity,
    required this.message,
    required this.recommendation,
  });
}

enum HealthAlertType {
  overDependency,          // 过度依赖
  prolongedNegativeMood,   // 持续负面情绪
  irregularSchedule,       // 作息不规律
  socialIsolation,         // 社交孤立
}

enum AlertSeverity {
  low,
  medium,
  high,
}
