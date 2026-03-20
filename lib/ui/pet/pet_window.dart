import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/pet_engine.dart';
import '../../skills/skill_manager.dart';
import '../chat/chat_panel.dart';
import '../settings/settings_panel.dart';
import 'pet_canvas.dart';

/// 宠物主窗口 - 组合鹅宝画布+交互逻辑
class PetWindow extends StatefulWidget {
  const PetWindow({super.key});

  @override
  State<PetWindow> createState() => _PetWindowState();
}

class _PetWindowState extends State<PetWindow> {
  bool _showChat = false;
  bool _showSettings = false;
  bool _showMenu = false;

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<PetEngine>();

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // 鹅宝主体
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 状态指示器
                _StatusBar(engine: engine),
                const SizedBox(height: 8),
                // 鹅宝画布
                PetCanvas(
                  engine: engine,
                  onTap: _onPetTap,
                  onDoubleTap: _toggleChat,
                  onDrag: _onDrag,
                ),
                const SizedBox(height: 8),
                // 名字
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: const Text(
                    '🦢 鹅宝',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF424242),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 右键菜单
          if (_showMenu) _buildContextMenu(),

          // 聊天面板
          if (_showChat)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: SizedBox(
                width: 360,
                child: ChatPanel(onClose: () => setState(() => _showChat = false)),
              ),
            ),

          // 设置面板
          if (_showSettings)
            Center(
              child: SettingsPanel(
                onClose: () => setState(() => _showSettings = false),
              ),
            ),
        ],
      ),
    );
  }

  void _onPetTap() {
    final engine = context.read<PetEngine>();
    engine.interact('pat');
    setState(() => _showMenu = !_showMenu);
  }

  void _toggleChat() {
    setState(() {
      _showChat = !_showChat;
      _showMenu = false;
    });
  }

  void _onDrag(DragUpdateDetails details) {
    // 拖拽移动窗口 - 由 window_manager 处理
  }

  Widget _buildContextMenu() {
    return Positioned(
      bottom: 60,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MenuButton(
                icon: '💬',
                label: '聊天',
                onTap: () {
                  _toggleChat();
                },
              ),
              _MenuButton(
                icon: '🎮',
                label: '技能',
                onTap: () {
                  setState(() => _showMenu = false);
                  _showSkillList();
                },
              ),
              _MenuButton(
                icon: '🍖',
                label: '喂食',
                onTap: () {
                  context.read<PetEngine>().interact('feed');
                  setState(() => _showMenu = false);
                },
              ),
              _MenuButton(
                icon: '😴',
                label: '休息',
                onTap: () {
                  context.read<PetEngine>().interact('sleep');
                  setState(() => _showMenu = false);
                },
              ),
              _MenuButton(
                icon: '⚙️',
                label: '设置',
                onTap: () {
                  setState(() {
                    _showSettings = true;
                    _showMenu = false;
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSkillList() {
    final skillManager = context.read<SkillManager>();
    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Container(
          width: 320,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '🦢 鹅宝技能',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ...skillManager.getSkillsByCategory().entries.map((entry) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        entry.key,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    ...entry.value.map((skill) {
                      return ListTile(
                        dense: true,
                        leading: Text(skill.icon, style: const TextStyle(fontSize: 20)),
                        title: Text(skill.name),
                        subtitle: Text(
                          skill.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        contentPadding: EdgeInsets.zero,
                      );
                    }),
                  ],
                );
              }),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 状态指示条（显示心情、饥饿度等）
class _StatusBar extends StatelessWidget {
  final PetEngine engine;

  const _StatusBar({required this.engine});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.85),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MiniBar(icon: '❤️', value: engine.happiness / 100, color: Colors.red),
          const SizedBox(width: 8),
          _MiniBar(icon: '🍖', value: engine.hunger / 100, color: Colors.orange),
          const SizedBox(width: 8),
          _MiniBar(icon: '⚡', value: engine.energy / 100, color: Colors.blue),
        ],
      ),
    );
  }
}

class _MiniBar extends StatelessWidget {
  final String icon;
  final double value;
  final Color color;

  const _MiniBar({required this.icon, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(icon, style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 3),
        SizedBox(
          width: 32,
          height: 6,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: value.clamp(0, 1),
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
      ],
    );
  }
}

/// 菜单按钮
class _MenuButton extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback onTap;

  const _MenuButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(icon, style: const TextStyle(fontSize: 22)),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: Color(0xFF616161)),
            ),
          ],
        ),
      ),
    );
  }
}
