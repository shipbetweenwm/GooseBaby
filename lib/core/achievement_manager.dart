import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import '../models/models.dart';

/// 成就稀有度
enum AchievementRarity {
  common,     // 普通 - 灰色
  rare,       // 稀有 - 蓝色
  epic,       // 史诗 - 紫色
  legendary,  // 传说 - 金色
}

/// 成就类别
enum AchievementCategory {
  companion,   // 🤝 陪伴成就
  growth,      // 📈 成长成就
  wealth,      // 💰 财富成就
  care,        // 💕 关爱成就
  explore,     // 🔍 探索成就
  special,     // ✨ 特殊成就
}

/// 成就定义
class Achievement {
  final String id;
  final String name;
  final String description;
  final String icon;
  final AchievementCategory category;
  final AchievementRarity rarity;
  final int rewardCoins;      // 达成奖励金币
  final int rewardExp;        // 达成奖励经验

  /// 达成条件检查函数 —— 传入当前统计数据，返回是否达成
  final bool Function(AchievementStats stats) checkCondition;

  /// 进度获取函数 —— 返回 (当前, 目标)，用于显示进度条
  final (int current, int target) Function(AchievementStats stats) getProgress;

  const Achievement({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.category,
    required this.rarity,
    this.rewardCoins = 0,
    this.rewardExp = 0,
    required this.checkCondition,
    required this.getProgress,
  });
}

/// 成就统计数据（聚合各种可追踪的数据指标）
class AchievementStats {
  final int companionDays;     // 陪伴天数
  final int level;             // 等级
  final int totalExp;          // 累计经验
  final int coins;             // 当前金币
  final int totalCoinsEarned;  // 累计获得金币
  final int totalFeedings;     // 累计喂食次数
  final int totalPats;         // 累计摸头次数
  final int totalBaths;        // 累计洗澡次数
  final int totalPurchases;    // 累计商店购买次数
  final int totalChats;        // 累计对话次数
  final int totalItemsUsed;    // 累计使用物品次数
  final int maxMoodStreak;     // 最长连续心情>80天数
  final int loginDays;         // 累计登录天数
  final double currentMood;    // 当前心情
  final double currentHealth;  // 当前健康度

  const AchievementStats({
    this.companionDays = 0,
    this.level = 1,
    this.totalExp = 0,
    this.coins = 0,
    this.totalCoinsEarned = 0,
    this.totalFeedings = 0,
    this.totalPats = 0,
    this.totalBaths = 0,
    this.totalPurchases = 0,
    this.totalChats = 0,
    this.totalItemsUsed = 0,
    this.maxMoodStreak = 0,
    this.loginDays = 0,
    this.currentMood = 80,
    this.currentHealth = 90,
  });

  Map<String, dynamic> toJson() => {
    'companionDays': companionDays,
    'level': level,
    'totalExp': totalExp,
    'coins': coins,
    'totalCoinsEarned': totalCoinsEarned,
    'totalFeedings': totalFeedings,
    'totalPats': totalPats,
    'totalBaths': totalBaths,
    'totalPurchases': totalPurchases,
    'totalChats': totalChats,
    'totalItemsUsed': totalItemsUsed,
    'maxMoodStreak': maxMoodStreak,
    'loginDays': loginDays,
    'currentMood': currentMood,
    'currentHealth': currentHealth,
  };

  factory AchievementStats.fromJson(Map<String, dynamic> json) => AchievementStats(
    companionDays: json['companionDays'] as int? ?? 0,
    level: json['level'] as int? ?? 1,
    totalExp: json['totalExp'] as int? ?? 0,
    coins: json['coins'] as int? ?? 0,
    totalCoinsEarned: json['totalCoinsEarned'] as int? ?? 0,
    totalFeedings: json['totalFeedings'] as int? ?? 0,
    totalPats: json['totalPats'] as int? ?? 0,
    totalBaths: json['totalBaths'] as int? ?? 0,
    totalPurchases: json['totalPurchases'] as int? ?? 0,
    totalChats: json['totalChats'] as int? ?? 0,
    totalItemsUsed: json['totalItemsUsed'] as int? ?? 0,
    maxMoodStreak: json['maxMoodStreak'] as int? ?? 0,
    loginDays: json['loginDays'] as int? ?? 0,
    currentMood: (json['currentMood'] as num?)?.toDouble() ?? 80,
    currentHealth: (json['currentHealth'] as num?)?.toDouble() ?? 90,
  );

  AchievementStats copyWith({
    int? companionDays,
    int? level,
    int? totalExp,
    int? coins,
    int? totalCoinsEarned,
    int? totalFeedings,
    int? totalPats,
    int? totalBaths,
    int? totalPurchases,
    int? totalChats,
    int? totalItemsUsed,
    int? maxMoodStreak,
    int? loginDays,
    double? currentMood,
    double? currentHealth,
  }) {
    return AchievementStats(
      companionDays: companionDays ?? this.companionDays,
      level: level ?? this.level,
      totalExp: totalExp ?? this.totalExp,
      coins: coins ?? this.coins,
      totalCoinsEarned: totalCoinsEarned ?? this.totalCoinsEarned,
      totalFeedings: totalFeedings ?? this.totalFeedings,
      totalPats: totalPats ?? this.totalPats,
      totalBaths: totalBaths ?? this.totalBaths,
      totalPurchases: totalPurchases ?? this.totalPurchases,
      totalChats: totalChats ?? this.totalChats,
      totalItemsUsed: totalItemsUsed ?? this.totalItemsUsed,
      maxMoodStreak: maxMoodStreak ?? this.maxMoodStreak,
      loginDays: loginDays ?? this.loginDays,
      currentMood: currentMood ?? this.currentMood,
      currentHealth: currentHealth ?? this.currentHealth,
    );
  }
}

/// 已解锁的成就记录
class UnlockedAchievement {
  final String achievementId;
  final DateTime unlockedAt;

  const UnlockedAchievement({
    required this.achievementId,
    required this.unlockedAt,
  });

  Map<String, dynamic> toJson() => {
    'achievementId': achievementId,
    'unlockedAt': unlockedAt.toIso8601String(),
  };

  factory UnlockedAchievement.fromJson(Map<String, dynamic> json) => UnlockedAchievement(
    achievementId: json['achievementId'] as String,
    unlockedAt: DateTime.parse(json['unlockedAt'] as String),
  );
}

/// 成就管理器
class AchievementManager extends ChangeNotifier {
  AchievementStats _stats = const AchievementStats();
  final Map<String, UnlockedAchievement> _unlocked = {};

  /// 新成就解锁回调（由 PetWindow 设置，用于播放烟花动画）
  void Function(Achievement achievement)? onAchievementUnlocked;

  AchievementStats get stats => _stats;
  Map<String, UnlockedAchievement> get unlocked => _unlocked;

  /// 所有成就定义
  static final List<Achievement> allAchievements = _defineAchievements();

  /// 已解锁数量
  int get unlockedCount => _unlocked.length;

  /// 总成就数
  int get totalCount => allAchievements.length;

  /// 完成百分比
  double get completionPercent =>
      totalCount > 0 ? unlockedCount / totalCount : 0;

  AchievementManager() {
    _loadData();
  }

  /// 加载持久化数据
  void _loadData() {
    try {
      final box = Hive.box('pet_state');

      // 加载统计数据
      final statsData = box.get('achievement_stats');
      if (statsData != null && statsData is Map) {
        _stats = AchievementStats.fromJson(Map<String, dynamic>.from(statsData));
      }

      // 加载已解锁成就
      final unlockedData = box.get('unlocked_achievements');
      if (unlockedData != null && unlockedData is List) {
        for (final item in unlockedData) {
          if (item is Map) {
            final record = UnlockedAchievement.fromJson(Map<String, dynamic>.from(item));
            _unlocked[record.achievementId] = record;
          }
        }
      }

      debugPrint('🏆 成就系统加载完成: ${_unlocked.length}/${allAchievements.length} 已解锁');
    } catch (e) {
      debugPrint('🏆 成就数据加载失败: $e');
    }
  }

  /// 保存持久化数据
  void _saveData() {
    try {
      final box = Hive.box('pet_state');
      box.put('achievement_stats', _stats.toJson());
      box.put('unlocked_achievements',
          _unlocked.values.map((e) => e.toJson()).toList());
    } catch (e) {
      debugPrint('🏆 成就数据保存失败: $e');
    }
  }

  /// 从 PetState 同步基础数据
  void syncFromPetState(PetState petState) {
    _stats = _stats.copyWith(
      companionDays: petState.companionDays,
      level: petState.level,
      totalExp: _stats.totalExp, // 保持累计值
      coins: petState.coins,
      currentMood: petState.mood,
      currentHealth: petState.health,
    );
    _checkAllAchievements();
  }

  /// 记录喂食事件
  void recordFeeding() {
    _stats = _stats.copyWith(totalFeedings: _stats.totalFeedings + 1);
    _checkAllAchievements();
  }

  /// 记录摸头事件
  void recordPat() {
    _stats = _stats.copyWith(totalPats: _stats.totalPats + 1);
    _checkAllAchievements();
  }

  /// 记录洗澡事件
  void recordBath() {
    _stats = _stats.copyWith(totalBaths: _stats.totalBaths + 1);
    _checkAllAchievements();
  }

  /// 记录商店购买事件
  void recordPurchase(int price) {
    _stats = _stats.copyWith(
      totalPurchases: _stats.totalPurchases + 1,
      totalCoinsEarned: _stats.totalCoinsEarned, // 花费不计入累计获得
    );
    _checkAllAchievements();
  }

  /// 记录对话事件
  void recordChat() {
    _stats = _stats.copyWith(totalChats: _stats.totalChats + 1);
    _checkAllAchievements();
  }

  /// 记录使用物品事件
  void recordItemUse() {
    _stats = _stats.copyWith(totalItemsUsed: _stats.totalItemsUsed + 1);
    _checkAllAchievements();
  }

  /// 记录获得金币
  void recordCoinsEarned(int amount) {
    _stats = _stats.copyWith(
      totalCoinsEarned: _stats.totalCoinsEarned + amount,
    );
    // 金币获得不需要每次都检查所有成就，定期检查即可
  }

  /// 记录经验获得
  void recordExpEarned(int amount) {
    _stats = _stats.copyWith(totalExp: _stats.totalExp + amount);
  }

  /// 检查所有成就
  void _checkAllAchievements() {
    bool hasNew = false;

    for (final achievement in allAchievements) {
      if (_unlocked.containsKey(achievement.id)) continue;

      bool achieved = false;

      // 特殊成就：成就猎人
      if (achievement.id == 'achievement_10') {
        achieved = _unlocked.length >= 10;
      }
      // 特殊成就：全成就大师
      else if (achievement.id == 'achievement_all') {
        // 除了自己以外的所有成就都解锁了
        achieved = _unlocked.length >= allAchievements.length - 1;
      }
      // 普通成就
      else {
        achieved = achievement.checkCondition(_stats);
      }

      if (achieved) {
        _unlock(achievement);
        hasNew = true;
      }
    }

    if (hasNew) {
      _saveData();
      notifyListeners();
    } else {
      _saveData();
    }
  }

  /// 手动触发检查（定时调用）
  void periodicCheck() {
    _checkAllAchievements();
  }

  /// 解锁成就
  void _unlock(Achievement achievement) {
    _unlocked[achievement.id] = UnlockedAchievement(
      achievementId: achievement.id,
      unlockedAt: DateTime.now(),
    );
    debugPrint('🏆 成就解锁: ${achievement.name} (${achievement.icon})');

    // 触发回调（播放烟花动画）
    onAchievementUnlocked?.call(achievement);
  }

  /// 某个成就是否已解锁
  bool isUnlocked(String achievementId) => _unlocked.containsKey(achievementId);

  /// 获取某个成就的解锁时间
  DateTime? getUnlockTime(String achievementId) =>
      _unlocked[achievementId]?.unlockedAt;

  /// 按类别获取成就
  List<Achievement> getByCategory(AchievementCategory category) =>
      allAchievements.where((a) => a.category == category).toList();

  /// 获取某类别的完成数量
  int getCategoryUnlockedCount(AchievementCategory category) =>
      allAchievements
          .where((a) => a.category == category && _unlocked.containsKey(a.id))
          .length;

  /// 获取某类别的总数量
  int getCategoryTotalCount(AchievementCategory category) =>
      allAchievements.where((a) => a.category == category).length;

  // ============================================================
  // 成就定义列表
  // ============================================================

  static List<Achievement> _defineAchievements() {
    return [
      // ====== 🤝 陪伴成就 ======
      Achievement(
        id: 'companion_1',
        name: '初次相遇',
        description: '第一次启动鹅宝',
        icon: '🐣',
        category: AchievementCategory.companion,
        rarity: AchievementRarity.common,
        rewardCoins: 10,
        rewardExp: 5,
        checkCondition: (s) => s.companionDays >= 1,
        getProgress: (s) => (s.companionDays.clamp(0, 1), 1),
      ),
      Achievement(
        id: 'companion_3',
        name: '三日之约',
        description: '陪伴鹅宝 3 天',
        icon: '🌱',
        category: AchievementCategory.companion,
        rarity: AchievementRarity.common,
        rewardCoins: 30,
        rewardExp: 10,
        checkCondition: (s) => s.companionDays >= 3,
        getProgress: (s) => (s.companionDays.clamp(0, 3), 3),
      ),
      Achievement(
        id: 'companion_7',
        name: '一周挚友',
        description: '陪伴鹅宝 7 天',
        icon: '🌿',
        category: AchievementCategory.companion,
        rarity: AchievementRarity.rare,
        rewardCoins: 50,
        rewardExp: 20,
        checkCondition: (s) => s.companionDays >= 7,
        getProgress: (s) => (s.companionDays.clamp(0, 7), 7),
      ),
      Achievement(
        id: 'companion_30',
        name: '月光伙伴',
        description: '陪伴鹅宝 30 天',
        icon: '🌙',
        category: AchievementCategory.companion,
        rarity: AchievementRarity.epic,
        rewardCoins: 200,
        rewardExp: 50,
        checkCondition: (s) => s.companionDays >= 30,
        getProgress: (s) => (s.companionDays.clamp(0, 30), 30),
      ),
      Achievement(
        id: 'companion_100',
        name: '百日之约',
        description: '陪伴鹅宝 100 天',
        icon: '🌟',
        category: AchievementCategory.companion,
        rarity: AchievementRarity.legendary,
        rewardCoins: 500,
        rewardExp: 100,
        checkCondition: (s) => s.companionDays >= 100,
        getProgress: (s) => (s.companionDays.clamp(0, 100), 100),
      ),
      Achievement(
        id: 'companion_365',
        name: '一年之恋',
        description: '陪伴鹅宝 365 天',
        icon: '💫',
        category: AchievementCategory.companion,
        rarity: AchievementRarity.legendary,
        rewardCoins: 1000,
        rewardExp: 200,
        checkCondition: (s) => s.companionDays >= 365,
        getProgress: (s) => (s.companionDays.clamp(0, 365), 365),
      ),

      // ====== 📈 成长成就 ======
      Achievement(
        id: 'level_5',
        name: '初出茅庐',
        description: '鹅宝等级达到 5 级',
        icon: '🎓',
        category: AchievementCategory.growth,
        rarity: AchievementRarity.common,
        rewardCoins: 50,
        rewardExp: 15,
        checkCondition: (s) => s.level >= 5,
        getProgress: (s) => (s.level.clamp(0, 5), 5),
      ),
      Achievement(
        id: 'level_10',
        name: '小有成就',
        description: '鹅宝等级达到 10 级',
        icon: '🏅',
        category: AchievementCategory.growth,
        rarity: AchievementRarity.rare,
        rewardCoins: 100,
        rewardExp: 30,
        checkCondition: (s) => s.level >= 10,
        getProgress: (s) => (s.level.clamp(0, 10), 10),
      ),
      Achievement(
        id: 'level_20',
        name: '成长之路',
        description: '鹅宝等级达到 20 级',
        icon: '🎖️',
        category: AchievementCategory.growth,
        rarity: AchievementRarity.epic,
        rewardCoins: 300,
        rewardExp: 80,
        checkCondition: (s) => s.level >= 20,
        getProgress: (s) => (s.level.clamp(0, 20), 20),
      ),
      Achievement(
        id: 'level_50',
        name: '鹅中之王',
        description: '鹅宝等级达到 50 级',
        icon: '👑',
        category: AchievementCategory.growth,
        rarity: AchievementRarity.legendary,
        rewardCoins: 800,
        rewardExp: 200,
        checkCondition: (s) => s.level >= 50,
        getProgress: (s) => (s.level.clamp(0, 50), 50),
      ),

      // ====== 💰 财富成就 ======
      Achievement(
        id: 'coins_100',
        name: '小有积蓄',
        description: '累计获得 100 金币',
        icon: '💰',
        category: AchievementCategory.wealth,
        rarity: AchievementRarity.common,
        rewardCoins: 20,
        rewardExp: 5,
        checkCondition: (s) => s.totalCoinsEarned >= 100 || s.coins >= 100,
        getProgress: (s) {
          final v = s.totalCoinsEarned > s.coins ? s.totalCoinsEarned : s.coins;
          return (v.clamp(0, 100), 100);
        },
      ),
      Achievement(
        id: 'coins_1000',
        name: '鹅宝富翁',
        description: '累计获得 1000 金币',
        icon: '💎',
        category: AchievementCategory.wealth,
        rarity: AchievementRarity.rare,
        rewardCoins: 100,
        rewardExp: 20,
        checkCondition: (s) => s.totalCoinsEarned >= 1000 || s.coins >= 1000,
        getProgress: (s) {
          final v = s.totalCoinsEarned > s.coins ? s.totalCoinsEarned : s.coins;
          return (v.clamp(0, 1000), 1000);
        },
      ),
      Achievement(
        id: 'coins_5000',
        name: '坐拥金山',
        description: '累计获得 5000 金币',
        icon: '🏦',
        category: AchievementCategory.wealth,
        rarity: AchievementRarity.epic,
        rewardCoins: 300,
        rewardExp: 50,
        checkCondition: (s) => s.totalCoinsEarned >= 5000 || s.coins >= 5000,
        getProgress: (s) {
          final v = s.totalCoinsEarned > s.coins ? s.totalCoinsEarned : s.coins;
          return (v.clamp(0, 5000), 5000);
        },
      ),
      Achievement(
        id: 'purchase_10',
        name: '购物达人',
        description: '在商店购买 10 次',
        icon: '🛒',
        category: AchievementCategory.wealth,
        rarity: AchievementRarity.common,
        rewardCoins: 30,
        rewardExp: 10,
        checkCondition: (s) => s.totalPurchases >= 10,
        getProgress: (s) => (s.totalPurchases.clamp(0, 10), 10),
      ),
      Achievement(
        id: 'purchase_50',
        name: '疯狂剁手',
        description: '在商店购买 50 次',
        icon: '🎁',
        category: AchievementCategory.wealth,
        rarity: AchievementRarity.rare,
        rewardCoins: 100,
        rewardExp: 30,
        checkCondition: (s) => s.totalPurchases >= 50,
        getProgress: (s) => (s.totalPurchases.clamp(0, 50), 50),
      ),

      // ====== 💕 关爱成就 ======
      Achievement(
        id: 'pat_10',
        name: '温柔的手',
        description: '摸鹅宝 10 次',
        icon: '🤗',
        category: AchievementCategory.care,
        rarity: AchievementRarity.common,
        rewardCoins: 20,
        rewardExp: 8,
        checkCondition: (s) => s.totalPats >= 10,
        getProgress: (s) => (s.totalPats.clamp(0, 10), 10),
      ),
      Achievement(
        id: 'pat_100',
        name: '撸鹅专家',
        description: '摸鹅宝 100 次',
        icon: '🥰',
        category: AchievementCategory.care,
        rarity: AchievementRarity.rare,
        rewardCoins: 80,
        rewardExp: 25,
        checkCondition: (s) => s.totalPats >= 100,
        getProgress: (s) => (s.totalPats.clamp(0, 100), 100),
      ),
      Achievement(
        id: 'pat_500',
        name: '终极撸鹅王',
        description: '摸鹅宝 500 次',
        icon: '💝',
        category: AchievementCategory.care,
        rarity: AchievementRarity.epic,
        rewardCoins: 200,
        rewardExp: 60,
        checkCondition: (s) => s.totalPats >= 500,
        getProgress: (s) => (s.totalPats.clamp(0, 500), 500),
      ),
      Achievement(
        id: 'feed_10',
        name: '初级饲养员',
        description: '喂鹅宝吃东西 10 次',
        icon: '🍖',
        category: AchievementCategory.care,
        rarity: AchievementRarity.common,
        rewardCoins: 20,
        rewardExp: 8,
        checkCondition: (s) => s.totalFeedings >= 10,
        getProgress: (s) => (s.totalFeedings.clamp(0, 10), 10),
      ),
      Achievement(
        id: 'feed_50',
        name: '美食鉴赏家',
        description: '喂鹅宝吃东西 50 次',
        icon: '🍽️',
        category: AchievementCategory.care,
        rarity: AchievementRarity.rare,
        rewardCoins: 80,
        rewardExp: 25,
        checkCondition: (s) => s.totalFeedings >= 50,
        getProgress: (s) => (s.totalFeedings.clamp(0, 50), 50),
      ),
      Achievement(
        id: 'bath_5',
        name: '爱干净的主人',
        description: '给鹅宝洗澡 5 次',
        icon: '🛁',
        category: AchievementCategory.care,
        rarity: AchievementRarity.common,
        rewardCoins: 20,
        rewardExp: 8,
        checkCondition: (s) => s.totalBaths >= 5,
        getProgress: (s) => (s.totalBaths.clamp(0, 5), 5),
      ),
      Achievement(
        id: 'bath_30',
        name: '洁癖达人',
        description: '给鹅宝洗澡 30 次',
        icon: '🧴',
        category: AchievementCategory.care,
        rarity: AchievementRarity.rare,
        rewardCoins: 80,
        rewardExp: 25,
        checkCondition: (s) => s.totalBaths >= 30,
        getProgress: (s) => (s.totalBaths.clamp(0, 30), 30),
      ),

      // ====== 🔍 探索成就 ======
      Achievement(
        id: 'chat_10',
        name: '话唠初级',
        description: '和鹅宝对话 10 次',
        icon: '💬',
        category: AchievementCategory.explore,
        rarity: AchievementRarity.common,
        rewardCoins: 20,
        rewardExp: 8,
        checkCondition: (s) => s.totalChats >= 10,
        getProgress: (s) => (s.totalChats.clamp(0, 10), 10),
      ),
      Achievement(
        id: 'chat_100',
        name: '知心好友',
        description: '和鹅宝对话 100 次',
        icon: '🗣️',
        category: AchievementCategory.explore,
        rarity: AchievementRarity.rare,
        rewardCoins: 100,
        rewardExp: 30,
        checkCondition: (s) => s.totalChats >= 100,
        getProgress: (s) => (s.totalChats.clamp(0, 100), 100),
      ),
      Achievement(
        id: 'chat_500',
        name: '灵魂伴侣',
        description: '和鹅宝对话 500 次',
        icon: '💞',
        category: AchievementCategory.explore,
        rarity: AchievementRarity.epic,
        rewardCoins: 300,
        rewardExp: 80,
        checkCondition: (s) => s.totalChats >= 500,
        getProgress: (s) => (s.totalChats.clamp(0, 500), 500),
      ),
      Achievement(
        id: 'items_20',
        name: '百宝箱',
        description: '累计使用 20 个物品',
        icon: '📦',
        category: AchievementCategory.explore,
        rarity: AchievementRarity.common,
        rewardCoins: 30,
        rewardExp: 10,
        checkCondition: (s) => s.totalItemsUsed >= 20,
        getProgress: (s) => (s.totalItemsUsed.clamp(0, 20), 20),
      ),

      // ====== ✨ 特殊成就 ======
      Achievement(
        id: 'perfect_health',
        name: '完美状态',
        description: '鹅宝所有属性同时达到 90 以上',
        icon: '🌈',
        category: AchievementCategory.special,
        rarity: AchievementRarity.epic,
        rewardCoins: 200,
        rewardExp: 50,
        checkCondition: (s) => s.currentMood >= 90 && s.currentHealth >= 90,
        getProgress: (s) {
          int count = 0;
          if (s.currentMood >= 90) count++;
          if (s.currentHealth >= 90) count++;
          return (count, 2);
        },
      ),
      Achievement(
        id: 'achievement_10',
        name: '成就猎人',
        description: '解锁 10 个成就',
        icon: '🏆',
        category: AchievementCategory.special,
        rarity: AchievementRarity.rare,
        rewardCoins: 100,
        rewardExp: 30,
        // 特殊：在 _checkAllAchievements 中用解锁数量判断
        checkCondition: (_) => false, // 由下方特殊处理
        getProgress: (_) => (0, 10),
      ),
      Achievement(
        id: 'achievement_all',
        name: '全成就大师',
        description: '解锁所有其他成就',
        icon: '🎇',
        category: AchievementCategory.special,
        rarity: AchievementRarity.legendary,
        rewardCoins: 999,
        rewardExp: 500,
        checkCondition: (_) => false, // 由下方特殊处理
        getProgress: (_) => (0, 1),
      ),
    ];
  }
}
