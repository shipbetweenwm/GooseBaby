import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'whack_a_mole_game.dart';
import 'guess_number_game.dart';

/// 小游戏面板（左侧展开，不覆盖宠物）
class GamePanel extends StatelessWidget {
  final VoidCallback onClose;

  const GamePanel({super.key, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
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
          // 标题栏（可拖动窗口）
          GestureDetector(
            onPanStart: (_) => windowManager.startDragging(),
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  const Text(
                    '🎮 小游戏',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClose,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          // 游戏列表
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                _GameCard(
                  icon: '🔨',
                  title: '打地鼠',
                  description: '地鼠从洞里冒出来，快点击锤它！',
                  reward: '+5经验',
                  color: const Color(0xFFFFECB3),
                  onTap: () => _openGame(context, 'whack_a_mole'),
                ),
                const SizedBox(height: 12),
                _GameCard(
                  icon: '🔢',
                  title: '猜数字',
                  description: '猜一个1~100的数字，越少次数越高分！',
                  reward: '+3经验',
                  color: const Color(0xFFE3F2FD),
                  onTap: () => _openGame(context, 'guess_number'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openGame(BuildContext context, String gameId) {
    Widget game;
    switch (gameId) {
      case 'whack_a_mole':
        game = const WhackAMoleGame();
        break;
      case 'guess_number':
        game = const GuessNumberGame();
        break;
      default:
        return;
    }

    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black38,
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) {
          return FadeTransition(
            opacity: animation,
            child: game,
          );
        },
      ),
    );
  }
}

/// 游戏入口卡片
class _GameCard extends StatelessWidget {
  final String icon;
  final String title;
  final String description;
  final String reward;
  final Color color;
  final VoidCallback onTap;

  const _GameCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.reward,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.8),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Text(icon, style: const TextStyle(fontSize: 28)),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF37474F),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          reward,
                          style: const TextStyle(fontSize: 11, color: Color(0xFFFF8F00), fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
          ],
        ),
      ),
    );
  }
}
