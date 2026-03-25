import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../../core/pet_engine.dart';
import '../../models/models.dart';

/// 鹅宝商店面板
class ShopPanel extends StatefulWidget {
  final VoidCallback? onClose;
  final void Function(ShopItem item)? onItemBought;
  final void Function(String message)? onShowBubble;

  const ShopPanel({super.key, this.onClose, this.onItemBought, this.onShowBubble});

  @override
  State<ShopPanel> createState() => _ShopPanelState();
}

class _ShopPanelState extends State<ShopPanel> {
  ShopItemType _selectedTab = ShopItemType.food;

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<PetEngine>();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildHeader(engine),
          _buildTabBar(),
          Expanded(child: _buildItemGrid(engine)),
        ],
      ),
    );
  }

  Widget _buildHeader(PetEngine engine) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFFFF8E1), Color(0xFFFFECB3)],
          ),
        ),
        child: Row(
          children: [
            const Text(
              '🛍️ 鹅宝商店',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            // 金币显示
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.9),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.orange.withOpacity(0.15),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
              children: [
                const Text('🪙', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 4),
                Text(
                  '${engine.coins}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFF8F00),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: widget.onClose,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Colors.grey.shade50,
      child: Row(
        children: [
          _TabChip(
            icon: '🍖',
            label: '食物',
            isSelected: _selectedTab == ShopItemType.food,
            onTap: () => setState(() => _selectedTab = ShopItemType.food),
          ),
          const SizedBox(width: 8),
          _TabChip(
            icon: '🎮',
            label: '玩具',
            isSelected: _selectedTab == ShopItemType.toy,
            onTap: () => setState(() => _selectedTab = ShopItemType.toy),
          ),
          const SizedBox(width: 8),
          _TabChip(
            icon: '💊',
            label: '药物',
            isSelected: _selectedTab == ShopItemType.medicine,
            onTap: () => setState(() => _selectedTab = ShopItemType.medicine),
          ),
          const SizedBox(width: 8),
          _TabChip(
            icon: '🧼',
            label: '清洁',
            isSelected: _selectedTab == ShopItemType.cleaning,
            onTap: () => setState(() => _selectedTab = ShopItemType.cleaning),
          ),
        ],
      ),
    );
  }

  Widget _buildItemGrid(PetEngine engine) {
    final items = ShopData.getByType(_selectedTab);

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = items[index];
        final canBuy = engine.coins >= item.price;

        return _ShopItemCard(
          item: item,
          canBuy: canBuy,
          onBuy: () => _buyItem(engine, item),
        );
      },
    );
  }

  void _buyItem(PetEngine engine, ShopItem item) {
    if (engine.buyItem(item)) {
      // 购买成功 → 通过气泡显示
      widget.onShowBubble?.call('${item.icon} 成功购买了${item.name}！鹅宝好开心~ 🦢');
      // 通知父组件关闭商店并播放动画
      widget.onItemBought?.call(item);
    } else {
      // 金币不足 → 通过气泡显示
      widget.onShowBubble?.call('🪙 金币不够啦~ 还差 ${item.price - engine.coins} 个金币');
    }
  }
}

/// 商店物品卡片
class _ShopItemCard extends StatelessWidget {
  final ShopItem item;
  final bool canBuy;
  final VoidCallback onBuy;

  const _ShopItemCard({
    required this.item,
    required this.canBuy,
    required this.onBuy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: canBuy ? Colors.white : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: canBuy ? Colors.grey.shade200 : Colors.grey.shade300,
        ),
        boxShadow: canBuy
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          // 物品图标
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: _getTypeBgColor().withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Text(item.icon, style: const TextStyle(fontSize: 26)),
          ),
          const SizedBox(width: 12),
          // 物品信息
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: canBuy ? Colors.black87 : Colors.grey,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.description,
                  style: TextStyle(
                    fontSize: 11,
                    color: canBuy ? Colors.grey.shade600 : Colors.grey.shade400,
                  ),
                ),
                const SizedBox(height: 4),
                _buildEffects(),
              ],
            ),
          ),
          // 购买按钮
          GestureDetector(
            onTap: canBuy ? onBuy : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: canBuy ? const Color(0xFFFF8F00) : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🪙', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 3),
                  Text(
                    '${item.price}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: canBuy ? Colors.white : Colors.grey.shade500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEffects() {
    final effects = <Widget>[];
    if (item.hungerBoost > 0) effects.add(_EffectBadge('🍖+${item.hungerBoost.toInt()}'));
    if (item.moodBoost > 0) effects.add(_EffectBadge('❤️+${item.moodBoost.toInt()}'));
    if (item.healthBoost > 0) effects.add(_EffectBadge('💚+${item.healthBoost.toInt()}'));
    if (item.energyBoost > 0) effects.add(_EffectBadge('⚡+${item.energyBoost.toInt()}'));
    if (item.energyBoost < 0) effects.add(_EffectBadge('⚡${item.energyBoost.toInt()}'));
    if (item.cleanBoost > 0) effects.add(_EffectBadge('🧼+${item.cleanBoost.toInt()}'));

    return Wrap(spacing: 4, children: effects);
  }

  Color _getTypeBgColor() {
    switch (item.type) {
      case ShopItemType.food:
        return Colors.orange;
      case ShopItemType.toy:
        return Colors.purple;
      case ShopItemType.medicine:
        return Colors.green;
      case ShopItemType.cleaning:
        return Colors.cyan;
    }
  }
}

class _EffectBadge extends StatelessWidget {
  final String text;
  const _EffectBadge(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final String icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _TabChip({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFF8F00).withOpacity(0.1) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFFFF8F00) : Colors.grey.shade300,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(icon, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: isSelected ? const Color(0xFFFF8F00) : Colors.grey.shade600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
