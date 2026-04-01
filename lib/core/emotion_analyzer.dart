/// 情绪分析器
/// 通过关键词和模式匹配分析用户输入的情绪
class EmotionAnalyzer {
  /// 情绪类型枚举
  static const String happy = 'happy';           // 开心
  static const String sad = 'sad';               // 悲伤
  static const String angry = 'angry';           // 愤怒
  static const String anxious = 'anxious';       // 焦虑
  static const String excited = 'excited';       // 兴奋
  static const String tired = 'tired';           // 疲惫
  static const String calm = 'calm';             // 平静
  static const String grateful = 'grateful';     // 感激
  static const String frustrated = 'frustrated'; // 挫败
  
  /// 情绪关键词词典
  static const Map<String, List<String>> _emotionKeywords = {
    happy: [
      '开心', '高兴', '快乐', '幸福', '棒', '好棒', '太好了', '哈哈', '嘻嘻', '呵呵',
      '喜欢', '爱', '谢谢', '感谢', '感动', '欣慰', '满足', '愉快', '美好', '精彩',
      '厉害', '优秀', '完美', '成功', '胜利', '赞', '牛', '666', 'nice', 'good',
      '太棒了', '太好了', '好开心', '好幸福', '好喜欢', '超级', '特别', '非常',
      '😄', '😊', '🙂', '😋', '🥰', '😍', '🤗', '👍', '👏', '🎉', '🎊', '💖',
    ],
    sad: [
      '难过', '伤心', '悲伤', '痛苦', '哭', '眼泪', '失落', '沮丧', '郁闷', '忧愁',
      '不开心', '不高兴', '难过', '心疼', '遗憾', '后悔', '失望', '绝望', '崩溃',
      '丧', '低落', '消沉', '哀伤', '哭泣', '呜呜', '呜', '难受', '心里难受',
      '😢', '😭', '😿', '💔', '🥺', '😔', '😞', '😟', '🙁',
    ],
    angry: [
      '生气', '愤怒', '火大', '烦躁', '讨厌', '烦', '气死', '气死我了', '恼火',
      '愤怒', '暴躁', '恼怒', '愤恨', '憎恨', '厌恶', '反感', '不爽', '不爽了',
      '无语', '服了', '真的是', '烦死了', '讨厌死了', '可恶', '该死', '混蛋',
      '😡', '😠', '🤬', '💢', '🔥', '👎', '👊',
    ],
    anxious: [
      '焦虑', '担心', '担忧', '紧张', '不安', '害怕', '恐惧', '恐慌', '烦躁',
      '着急', '急', '焦虑症', '强迫症', '压力', '压力大', '压力大啊',
      '睡不着', '失眠', '多梦', '噩梦', '心慌', '心跳快', '手抖',
      '😨', '😰', '😱', '🤯', '😫', '😩',
    ],
    excited: [
      '兴奋', '激动', '期待', '迫不及待', '热血', '燃', '燃起来了',
      '激动人心', '刺激', '好激动', '好兴奋', '太期待了', '等不及了',
      '冲冲冲', '冲鸭', '加油', '努力', '奋斗', '拼搏',
      '🤩', '😃', '😆', '🥳', '✨', '🌟', '💪', '🚀', '💫',
    ],
    tired: [
      '累', '疲惫', '困', '困了', '好累', '好困', '累死了', '困死了',
      '没力气', '无力', '倦怠', '乏力', '精疲力尽', '筋疲力尽',
      '想睡觉', '想休息', '需要休息', '休息', '躺平', '摆烂',
      '😴', '😪', '🥱', '😫', '😩', '🛌',
    ],
    calm: [
      '嗯', '哦', '好的', '知道了', '了解', '明白', '清楚', '懂了',
      '可以', '行', '没问题', '好的', 'OK', 'ok', '嗯嗯',
      '平静', '安静', '冷静', '淡定', '镇定', '从容',
      '🙂', '😐', '😶', '🤔',
    ],
    grateful: [
      '谢谢', '感谢', '多谢', '谢了', '太感谢了', '非常感谢', '谢谢你',
      '感恩', '感激', '感动', '暖心', '温暖', '贴心', '体贴',
      '你真好', '太好了', '帮大忙了', '帮了我大忙', '救了我',
      '🙏', '🤝', '❤️', '💕', '💗', '💓', '💞', '💝',
    ],
    frustrated: [
      '挫败', '失败', '输了', '输了啊', '完了', '完蛋', '糟糕',
      '不行', '做不到', '搞不定', '没办法', '无力', '无能为力',
      '太难了', '太难了啊', '搞不懂', '不明白', '不理解', '困惑',
      '挫败感', '打击', '受挫', '碰壁', '处处碰壁',
      '😤', '😤', '😣', '😖', '😢',
    ],
  };
  
  /// 表情符号计数正则
  static final RegExp _emojiRegex = RegExp(
    r'[\u{1F600}-\u{1F64F}]|'  // 表情符号
    r'[\u{1F300}-\u{1F5FF}]|'  // 符号和象形文字
    r'[\u{1F680}-\u{1F6FF}]|'  // 交通和地图符号
    r'[\u{1F700}-\u{1F77F}]|'  // 炼金术符号
    r'[\u{1F780}-\u{1F7FF}]|'  // 几何图形扩展
    r'[\u{1F800}-\u{1F8FF}]|'  // 补充箭头-C
    r'[\u{1F900}-\u{1F9FF}]|'  // 补充符号和象形文字
    r'[\u{1FA00}-\u{1FA6F}]|'  // 国际象棋符号
    r'[\u{1FA70}-\u{1FAFF}]|'  // 符号和象形文字扩展-A
    r'[\u{2600}-\u{26FF}]|'    // 杂项符号
    r'[\u{2700}-\u{27BF}]',    // 装饰符号
    unicode: true,
  );
  
  /// 分析用户消息的情绪
  /// 返回情绪类型和强度
  static EmotionResult analyze(String message) {
    if (message.trim().isEmpty) {
      return EmotionResult(emotion: calm, intensity: 0.5);
    }
    
    // 统计各情绪的匹配次数
    final Map<String, int> emotionCounts = {};
    final Map<String, double> emotionScores = {};
    
    for (final entry in _emotionKeywords.entries) {
      final emotion = entry.key;
      final keywords = entry.value;
      
      int count = 0;
      for (final keyword in keywords) {
        if (message.contains(keyword)) {
          count++;
        }
      }
      
      if (count > 0) {
        emotionCounts[emotion] = count;
        // 根据匹配次数计算分数（对数增长，避免过度放大）
        emotionScores[emotion] = 1.0 + (count * 0.2);
      }
    }
    
    // 如果没有匹配到任何情绪关键词，根据消息特征判断
    if (emotionScores.isEmpty) {
      return _analyzeByFeatures(message);
    }
    
    // 找出得分最高的情绪
    String dominantEmotion = calm;
    double maxScore = 0;
    
    for (final entry in emotionScores.entries) {
      if (entry.value > maxScore) {
        maxScore = entry.value;
        dominantEmotion = entry.key;
      }
    }
    
    // 计算情绪强度（归一化到 0-1）
    final intensity = (maxScore / 3.0).clamp(0.0, 1.0);
    
    return EmotionResult(
      emotion: dominantEmotion,
      intensity: intensity,
      matchedKeywords: emotionCounts[dominantEmotion] ?? 0,
    );
  }
  
  /// 根据消息特征分析情绪（当没有关键词匹配时）
  static EmotionResult _analyzeByFeatures(String message) {
    // 检查消息长度
    if (message.length <= 3) {
      // 很短的消息通常是平静/敷衍的
      return EmotionResult(emotion: calm, intensity: 0.3);
    }
    
    // 检查标点符号
    final exclamationCount = '！!'.allMatches(message).length;
    final questionCount = '？?'.allMatches(message).length;
    final ellipsisCount = '……...'.allMatches(message).length;
    
    // 检查表情符号
    final emojiMatches = _emojiRegex.allMatches(message);
    final emojiCount = emojiMatches.length;
    
    // 根据特征判断
    if (exclamationCount >= 2) {
      // 多个感叹号可能是兴奋或愤怒
      return EmotionResult(emotion: excited, intensity: 0.6);
    }
    
    if (ellipsisCount >= 1 && message.length < 10) {
      // 省略号 + 短消息可能是疲惫或无奈
      return EmotionResult(emotion: tired, intensity: 0.5);
    }
    
    if (questionCount >= 2) {
      // 多个问号可能是困惑或焦虑
      return EmotionResult(emotion: anxious, intensity: 0.5);
    }
    
    if (emojiCount > 0) {
      // 有表情符号，倾向于开心
      return EmotionResult(emotion: happy, intensity: 0.6);
    }
    
    // 默认平静
    return EmotionResult(emotion: calm, intensity: 0.5);
  }
  
  /// 统计消息中的表情符号数量
  static int countEmojis(String message) {
    return _emojiRegex.allMatches(message).length;
  }
  
  /// 获取所有情绪类型
  static List<String> getAllEmotions() {
    return [
      happy, sad, angry, anxious, excited, tired, calm, grateful, frustrated,
    ];
  }
  
  /// 获取情绪的中文名称
  static String getEmotionName(String emotion) {
    const names = {
      happy: '开心',
      sad: '悲伤',
      angry: '愤怒',
      anxious: '焦虑',
      excited: '兴奋',
      tired: '疲惫',
      calm: '平静',
      grateful: '感激',
      frustrated: '挫败',
    };
    return names[emotion] ?? '平静';
  }
}

/// 情绪分析结果
class EmotionResult {
  /// 情绪类型
  final String emotion;
  
  /// 情绪强度（0-1）
  final double intensity;
  
  /// 匹配到的关键词数量
  final int matchedKeywords;
  
  const EmotionResult({
    required this.emotion,
    required this.intensity,
    this.matchedKeywords = 0,
  });
  
  @override
  String toString() => 'EmotionResult(emotion: $emotion, intensity: ${intensity.toStringAsFixed(2)}, keywords: $matchedKeywords)';
}
