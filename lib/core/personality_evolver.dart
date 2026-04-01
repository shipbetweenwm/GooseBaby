import 'dart:math';
import '../models/models.dart';
import 'emotion_analyzer.dart';

/// 性格演化系统
/// 根据用户的互动风格，动态调整鹅宝的性格（温柔度/活泼度/傲娇度）
class PersonalityEvolver {
  static final Random _random = Random();
  
  /// 性格演化速率（每次调整的最大幅度）
  static const double evolutionRate = 2.0;
  
  /// 性格演化的最小阈值（避免频繁调整）
  static const int minInteractionsForEvolution = 5;
  
  /// 根据用户互动更新宠物性格
  /// 返回更新后的性格维度
  static PersonalityTraits evolve(
    PetState currentState,
    String userMessage,
    EmotionResult userEmotion,
  ) {
    // 如果互动次数太少，不进行性格演化
    if (currentState.totalInteractions < minInteractionsForEvolution) {
      return PersonalityTraits(
        gentleness: currentState.gentleness,
        liveliness: currentState.liveliness,
        tsundere: currentState.tsundere,
      );
    }
    
    // 计算性格演化方向
    double gentlenessDelta = 0;
    double livelinessDelta = 0;
    double tsundereDelta = 0;
    
    // 1. 根据用户情绪调整性格
    gentlenessDelta += _getGentlenessDeltaFromEmotion(userEmotion);
    livelinessDelta += _getLivelinessDeltaFromEmotion(userEmotion);
    tsundereDelta += _getTsundereDeltaFromEmotion(userEmotion);
    
    // 2. 根据消息长度调整性格
    final messageLength = userMessage.length;
    if (messageLength > 100) {
      // 用户喜欢详细表达 → 鹅宝变得更温柔（愿意倾听）
      gentlenessDelta += evolutionRate * 0.5;
    } else if (messageLength < 10) {
      // 用户喜欢简洁 → 鹅宝变得更活泼（快速回应）
      livelinessDelta += evolutionRate * 0.3;
    }
    
    // 3. 根据表情符号使用调整性格
    final emojiCount = EmotionAnalyzer.countEmojis(userMessage);
    if (emojiCount > 0) {
      // 用户喜欢用表情 → 鹅宝变得更活泼可爱
      livelinessDelta += evolutionRate * 0.3 * (emojiCount / 3.0).clamp(0.5, 1.5);
    }
    
    // 4. 根据历史互动风格调整性格
    final stats = _calculateInteractionStats(currentState);
    
    // 用户经常开心 → 鹅宝变得更活泼
    if (stats.happyRatio > 0.5) {
      livelinessDelta += evolutionRate * 0.5;
    }
    
    // 用户经常悲伤 → 鹅宝变得更温柔体贴
    if (stats.sadRatio > 0.3) {
      gentlenessDelta += evolutionRate * 0.8;
    }
    
    // 用户情绪波动大 → 鹅宝变得稍微傲娇（调皮逗乐）
    if (stats.emotionVolatility > 0.5) {
      tsundereDelta += evolutionRate * 0.3;
    }
    
    // 5. 加入随机扰动（避免性格过于刻板）
    gentlenessDelta += (_random.nextDouble() - 0.5) * evolutionRate * 0.2;
    livelinessDelta += (_random.nextDouble() - 0.5) * evolutionRate * 0.2;
    tsundereDelta += (_random.nextDouble() - 0.5) * evolutionRate * 0.2;
    
    // 应用演化（限制在 0-100 范围内）
    final newGentleness = (currentState.gentleness + gentlenessDelta).clamp(0.0, 100.0);
    final newLiveliness = (currentState.liveliness + livelinessDelta).clamp(0.0, 100.0);
    final newTsundere = (currentState.tsundere + tsundereDelta).clamp(0.0, 100.0);
    
    return PersonalityTraits(
      gentleness: newGentleness,
      liveliness: newLiveliness,
      tsundere: newTsundere,
    );
  }
  
  /// 根据用户情绪获取温柔度变化
  static double _getGentlenessDeltaFromEmotion(EmotionResult emotion) {
    switch (emotion.emotion) {
      case EmotionAnalyzer.sad:
      case EmotionAnalyzer.anxious:
      case EmotionAnalyzer.frustrated:
        // 用户负面情绪 → 鹅宝变得更温柔体贴
        return evolutionRate * emotion.intensity * 0.8;
      case EmotionAnalyzer.happy:
      case EmotionAnalyzer.excited:
        // 用户正面情绪 → 温柔度略微降低（更活泼）
        return -evolutionRate * emotion.intensity * 0.2;
      default:
        return 0;
    }
  }
  
  /// 根据用户情绪获取活泼度变化
  static double _getLivelinessDeltaFromEmotion(EmotionResult emotion) {
    switch (emotion.emotion) {
      case EmotionAnalyzer.happy:
      case EmotionAnalyzer.excited:
        // 用户正面情绪 → 鹅宝变得更活泼
        return evolutionRate * emotion.intensity * 0.6;
      case EmotionAnalyzer.tired:
      case EmotionAnalyzer.calm:
        // 用户低能量 → 活泼度略微降低（配合用户节奏）
        return -evolutionRate * emotion.intensity * 0.3;
      default:
        return 0;
    }
  }
  
  /// 根据用户情绪获取傲娇度变化
  static double _getTsundereDeltaFromEmotion(EmotionResult emotion) {
    switch (emotion.emotion) {
      case EmotionAnalyzer.angry:
      case EmotionAnalyzer.frustrated:
        // 用户愤怒/挫败 → 鹅宝变得稍微傲娇（缓和气氛）
        return evolutionRate * emotion.intensity * 0.4;
      case EmotionAnalyzer.grateful:
        // 用户感激 → 傲娇度略微上升（害羞）
        return evolutionRate * emotion.intensity * 0.3;
      default:
        return 0;
    }
  }
  
  /// 计算互动统计信息
  static InteractionStats _calculateInteractionStats(PetState state) {
    final total = state.totalInteractions.toDouble();
    if (total == 0) {
      return InteractionStats(
        happyRatio: 0,
        sadRatio: 0,
        calmRatio: 0,
        excitedRatio: 0,
        emotionVolatility: 0,
      );
    }
    
    final happyRatio = state.happyInteractions / total;
    final sadRatio = state.sadInteractions / total;
    final calmRatio = state.calmInteractions / total;
    final excitedRatio = state.excitedInteractions / total;
    
    // 计算情绪波动度（各情绪分布的方差）
    final variance = 
        (happyRatio - 0.2) * (happyRatio - 0.2) +
        (sadRatio - 0.1) * (sadRatio - 0.1) +
        (calmRatio - 0.3) * (calmRatio - 0.3) +
        (excitedRatio - 0.2) * (excitedRatio - 0.2);
    final emotionVolatility = (variance / 4.0).clamp(0.0, 1.0);
    
    return InteractionStats(
      happyRatio: happyRatio,
      sadRatio: sadRatio,
      calmRatio: calmRatio,
      excitedRatio: excitedRatio,
      emotionVolatility: emotionVolatility,
    );
  }
  
  /// 根据性格维度生成性格描述
  static String getPersonalityDescription(PersonalityTraits traits) {
    final descriptions = <String>[];
    
    // 温柔度描述
    if (traits.gentleness >= 70) {
      descriptions.add('温柔体贴');
    } else if (traits.gentleness >= 50) {
      descriptions.add('善解人意');
    } else if (traits.gentleness < 30) {
      descriptions.add('独立自主');
    }
    
    // 活泼度描述
    if (traits.liveliness >= 70) {
      descriptions.add('活泼好动');
    } else if (traits.liveliness >= 50) {
      descriptions.add('开朗活泼');
    } else if (traits.liveliness < 30) {
      descriptions.add('沉稳内敛');
    }
    
    // 傲娇度描述
    if (traits.tsundere >= 70) {
      descriptions.add('傲娇可爱');
    } else if (traits.tsundere >= 50) {
      descriptions.add('小傲娇');
    }
    
    return descriptions.isEmpty ? '个性鲜明' : descriptions.join('、');
  }
  
  /// 根据性格调整回应语气提示词
  static String getTonePrompt(PersonalityTraits traits) {
    final prompts = <String>[];
    
    // 温柔度相关提示
    if (traits.gentleness >= 70) {
      prompts.add('你的回应要非常温柔体贴，像暖宝宝一样温暖主人的心。');
    } else if (traits.gentleness >= 50) {
      prompts.add('你的回应要温柔友好，让主人感受到你的关心。');
    }
    
    // 活泼度相关提示
    if (traits.liveliness >= 70) {
      prompts.add('你的性格很活泼，说话要充满活力，经常用可爱的语气词（~、！）。');
    } else if (traits.liveliness < 30) {
      prompts.add('你的性格比较沉稳，说话要稳重一些，不要过于活泼。');
    }
    
    // 傲娇度相关提示
    if (traits.tsundere >= 70) {
      prompts.add('你有点小傲娇，偶尔会嘴硬但其实很关心主人，比如"才、才不是因为担心你呢..."。');
    } else if (traits.tsundere >= 50) {
      prompts.add('你偶尔会小傲娇一下，但大部分时候都很坦诚。');
    }
    
    return prompts.isEmpty ? '' : '\n\n## 当前性格特点\n${prompts.join('\n')}';
  }
}

/// 性格维度
class PersonalityTraits {
  final double gentleness;  // 温柔度 0-100
  final double liveliness;  // 活泼度 0-100
  final double tsundere;    // 傲娇度 0-100
  
  const PersonalityTraits({
    required this.gentleness,
    required this.liveliness,
    required this.tsundere,
  });
}

/// 互动统计信息
class InteractionStats {
  final double happyRatio;      // 开心互动比例
  final double sadRatio;        // 悲伤互动比例
  final double calmRatio;       // 平静互动比例
  final double excitedRatio;    // 兴奋互动比例
  final double emotionVolatility; // 情绪波动度
  
  const InteractionStats({
    required this.happyRatio,
    required this.sadRatio,
    required this.calmRatio,
    required this.excitedRatio,
    required this.emotionVolatility,
  });
}
