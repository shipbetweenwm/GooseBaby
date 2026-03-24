import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../../core/achievement_manager.dart';

/// 成就页面面板（展示所有成就列表，按类别分组）
class AchievementPanel extends StatefulWidget {
  final VoidCallback onClose;

  const AchievementPanel({super.key, required this.onClose});

  @override
  State<AchievementPanel> createState() => _AchievementPanelState();
}

class _AchievementPanelState extends State<AchievementPanel>
    with SingleTickerProviderStateMixin {

  late TabController _tabController;

  static const _categories = AchievementCategory.values;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _categories.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<AchievementManager>();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: Column(
        children: [
          // 标题栏
          _buildHeader(manager),
          // 分类标签
          _buildCategoryTabs(manager),
          // 成就列表
          Expanded(
            child: _buildAchievementList(manager),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(AchievementManager manager) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          children: [
            Row(
              children: [
                const Text(
                  '🏆 成就殿堂',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: widget.onClose,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 总进度
            _buildOverallProgress(manager),
          ],
        ),
      ),
    );
  }

  Widget _buildOverallProgress(AchievementManager manager) {
    final percent = manager.completionPercent;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.amber.shade50,
            Colors.orange.shade50,
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber.shade200, width: 0.5),
      ),
      child: Row(
        children: [
          // 完成度圆环
          SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: percent,
                  strokeWidth: 5,
                  backgroundColor: Colors.amber.shade100,
                  valueColor: AlwaysStoppedAnimation(Colors.amber.shade700),
                ),
                Text(
                  '${(percent * 100).toInt()}%',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.amber.shade800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已解锁 ${manager.unlockedCount} / ${manager.totalCount}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.amber.shade900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _getEncourageText(percent),
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getEncourageText(double percent) {
    if (percent >= 1.0) return '🎉 恭喜！全部成就已解锁！';
    if (percent >= 0.8) return '✨ 即将集齐所有成就，加油！';
    if (percent >= 0.5) return '🌟 已经过半了，继续努力！';
    if (percent >= 0.2) return '💪 有不错的进展，坚持就是胜利！';
    return '🌱 成就之旅刚刚开始~';
  }

  Widget _buildCategoryTabs(AchievementManager manager) {
    return Container(
      color: Colors.white,
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        labelColor: Colors.amber.shade800,
        unselectedLabelColor: Colors.grey.shade500,
        indicatorColor: Colors.amber.shade700,
        indicatorWeight: 3,
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        tabAlignment: TabAlignment.start,
        tabs: _categories.map((cat) {
          final unlocked = manager.getCategoryUnlockedCount(cat);
          final total = manager.getCategoryTotalCount(cat);
          return Tab(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_categoryIcon(cat)),
                const SizedBox(width: 4),
                Text(_categoryName(cat)),
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: unlocked == total
                        ? Colors.amber.shade100
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$unlocked/$total',
                    style: TextStyle(
                      fontSize: 10,
                      color: unlocked == total
                          ? Colors.amber.shade800
                          : Colors.grey.shade500,
                    ),
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildAchievementList(AchievementManager manager) {
    return TabBarView(
      controller: _tabController,
      children: _categories.map((cat) {
        final catAchievements = manager.getByCategory(cat);
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          itemCount: catAchievements.length,
          itemBuilder: (context, index) {
            final achievement = catAchievements[index];
            final isUnlocked = manager.isUnlocked(achievement.id);
            final unlockTime = manager.getUnlockTime(achievement.id);
            final progress = achievement.getProgress(manager.stats);

            return _AchievementCard(
              achievement: achievement,
              isUnlocked: isUnlocked,
              unlockTime: unlockTime,
              currentProgress: progress.$1,
              targetProgress: progress.$2,
            );
          },
        );
      }).toList(),
    );
  }

  String _categoryIcon(AchievementCategory cat) {
    switch (cat) {
      case AchievementCategory.companion: return '🤝';
      case AchievementCategory.growth: return '📈';
      case AchievementCategory.wealth: return '💰';
      case AchievementCategory.care: return '💕';
      case AchievementCategory.explore: return '🔍';
      case AchievementCategory.special: return '✨';
    }
  }

  String _categoryName(AchievementCategory cat) {
    switch (cat) {
      case AchievementCategory.companion: return '陪伴';
      case AchievementCategory.growth: return '成长';
      case AchievementCategory.wealth: return '财富';
      case AchievementCategory.care: return '关爱';
      case AchievementCategory.explore: return '探索';
      case AchievementCategory.special: return '特殊';
    }
  }
}

/// 单个成就卡片
class _AchievementCard extends StatelessWidget {
  final Achievement achievement;
  final bool isUnlocked;
  final DateTime? unlockTime;
  final int currentProgress;
  final int targetProgress;

  const _AchievementCard({
    required this.achievement,
    required this.isUnlocked,
    this.unlockTime,
    required this.currentProgress,
    required this.targetProgress,
  });

  @override
  Widget build(BuildContext context) {
    final progressPercent =
        targetProgress > 0 ? currentProgress / targetProgress : 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isUnlocked ? Colors.white : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isUnlocked
              ? _rarityColor(achievement.rarity).withOpacity(0.4)
              : Colors.grey.shade200,
          width: isUnlocked ? 1.5 : 1,
        ),
        boxShadow: isUnlocked
            ? [
                BoxShadow(
                  color: _rarityColor(achievement.rarity).withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 图标
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: isUnlocked
                  ? _rarityColor(achievement.rarity).withOpacity(0.12)
                  : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
              border: isUnlocked
                  ? Border.all(
                      color: _rarityColor(achievement.rarity).withOpacity(0.3),
                    )
                  : null,
            ),
            child: Center(
              child: Text(
                isUnlocked ? achievement.icon : '🔒',
                style: TextStyle(
                  fontSize: isUnlocked ? 24 : 20,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // 信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        achievement.name,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isUnlocked
                              ? const Color(0xFF37474F)
                              : Colors.grey.shade400,
                        ),
                      ),
                    ),
                    // 稀有度标签
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isUnlocked
                            ? _rarityColor(achievement.rarity).withOpacity(0.15)
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _rarityName(achievement.rarity),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: isUnlocked
                              ? _rarityColor(achievement.rarity)
                              : Colors.grey.shade400,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  achievement.description,
                  style: TextStyle(
                    fontSize: 12,
                    color: isUnlocked
                        ? Colors.grey.shade600
                        : Colors.grey.shade400,
                  ),
                ),
                const SizedBox(height: 6),
                // 进度条
                if (!isUnlocked) ...[
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: progressPercent.clamp(0.0, 1.0),
                            minHeight: 6,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: AlwaysStoppedAnimation(
                              _rarityColor(achievement.rarity).withOpacity(0.5),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$currentProgress/$targetProgress',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  // 已解锁 - 显示时间和奖励
                  Row(
                    children: [
                      if (achievement.rewardCoins > 0) ...[
                        Text(
                          '🪙 +${achievement.rewardCoins}',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.amber.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (achievement.rewardExp > 0) ...[
                        Text(
                          '⭐ +${achievement.rewardExp}',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.blue.shade400,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      const Spacer(),
                      if (unlockTime != null)
                        Text(
                          '✅ ${_formatTime(unlockTime!)}',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade400,
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _rarityColor(AchievementRarity rarity) {
    switch (rarity) {
      case AchievementRarity.common:
        return Colors.grey.shade600;
      case AchievementRarity.rare:
        return const Color(0xFF2196F3);
      case AchievementRarity.epic:
        return const Color(0xFF9C27B0);
      case AchievementRarity.legendary:
        return const Color(0xFFFF8F00);
    }
  }

  String _rarityName(AchievementRarity rarity) {
    switch (rarity) {
      case AchievementRarity.common: return '普通';
      case AchievementRarity.rare: return '稀有';
      case AchievementRarity.epic: return '史诗';
      case AchievementRarity.legendary: return '传说';
    }
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    return '${time.month}/${time.day}';
  }
}
