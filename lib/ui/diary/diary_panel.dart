import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import '../../models/models.dart';
import '../../services/diary_service.dart';
import '../../ai/llm_manager.dart';
import '../chat/conversation_manager.dart';

/// 宠物日记面板
class DiaryPanel extends StatefulWidget {
  final VoidCallback? onClose;

  const DiaryPanel({super.key, this.onClose});

  @override
  State<DiaryPanel> createState() => _DiaryPanelState();
}

class _DiaryPanelState extends State<DiaryPanel> {
  DiaryEntry? _selectedEntry;
  final _searchController = TextEditingController();
  String _searchQuery = '';
  bool _isRegenerating = false;
  
  @override
  void initState() {
    super.initState();
    // 默认选中今天的日记（如果有）
    final entries = DiaryService.instance.entries;
    if (entries.isNotEmpty) {
      final today = DateTime.now();
      final todayEntry = entries.where((e) => 
        e.date.year == today.year && 
        e.date.month == today.month && 
        e.date.day == today.day
      ).firstOrNull;
      _selectedEntry = todayEntry ?? entries.first;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<DiaryEntry> get _filteredEntries {
    if (_searchQuery.isEmpty) {
      return DiaryService.instance.entries;
    }
    return DiaryService.instance.search(_searchQuery);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<DiaryService>(
      builder: (context, diaryService, child) {
        final entries = _filteredEntries;
        
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBF5),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            children: [
              // 顶部标题栏
              _buildHeader(),
              
              // 搜索栏
              _buildSearchBar(),
              
              // 日记列表 + 内容
              Expanded(
                child: entries.isEmpty 
                    ? _buildEmptyState()
                    : _buildContent(entries),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Color(0xFFE0D5C5), width: 1),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFE4B5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('📔', style: TextStyle(fontSize: 20)),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '鹅宝的日记',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF5D4037),
                  ),
                ),
                Text(
                  '记录我和主人的点点滴滴',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            const Spacer(),
            // 手动生成按钮（调试用）
            IconButton(
              icon: const Icon(Icons.edit_note, size: 20, color: Color(0xFF8D6E63)),
              onPressed: () async {
                // 获取今日会话内容并生成日记
                final conversations = await ConversationManager.getTodayConversationsSummary();
                await DiaryService.instance.generateNow(
                  todayConversationsCallback: () => conversations,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('日记已生成~'), duration: Duration(seconds: 2)),
                  );
                }
              },
              tooltip: '生成今日日记',
            ),
            if (widget.onClose != null)
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: widget.onClose,
                color: Colors.grey,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: _searchController,
        onChanged: (value) {
          setState(() => _searchQuery = value);
        },
        decoration: InputDecoration(
          hintText: '搜索日记内容...',
          hintStyle: const TextStyle(fontSize: 14, color: Colors.grey),
          prefixIcon: const Icon(Icons.search, size: 20, color: Colors.grey),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                )
              : null,
          filled: true,
          fillColor: const Color(0xFFF5EFE6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E1),
              shape: BoxShape.circle,
            ),
            child: const Text('📔', style: TextStyle(fontSize: 48)),
          ),
          const SizedBox(height: 16),
          const Text(
            '还没有日记哦~',
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text(
            '晚上10点鹅宝会自动写日记\n你也可以点击右上角手动生成',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(List<DiaryEntry> entries) {
    return Row(
      children: [
        // 左侧：日记列表
        SizedBox(
          width: 200,
          child: _buildEntryList(entries),
        ),
        
        // 右侧：日记详情
        Expanded(
          child: _selectedEntry != null
              ? _buildEntryDetail(_selectedEntry!)
              : _buildNoSelectionState(),
        ),
      ],
    );
  }

  Widget _buildEntryList(List<DiaryEntry> entries) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: Color(0xFFE0D5C5), width: 1)),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: entries.length,
        itemBuilder: (context, index) {
          final entry = entries[index];
          final isSelected = _selectedEntry?.id == entry.id;
          
          return _buildEntryCard(entry, isSelected);
        },
      ),
    );
  }

  Widget _buildEntryCard(DiaryEntry entry, bool isSelected) {
    final moodEmoji = _getMoodEmoji(entry.mood);
    
    return InkWell(
      onTap: () => setState(() => _selectedEntry = entry),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFFE4B5) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(moodEmoji, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 6),
                Text(
                  entry.formattedDate,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: const Color(0xFF5D4037),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              entry.weekdayName,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            if (entry.specialEvent != null) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFCDD2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '✨ ${entry.specialEvent}',
                  style: const TextStyle(fontSize: 10, color: Color(0xFFD32F2F)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEntryDetail(DiaryEntry entry) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 日期和天气
          Row(
            children: [
              Text(
                entry.formattedDate,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF5D4037),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                entry.weekdayName,
                style: const TextStyle(fontSize: 14, color: Colors.grey),
              ),
              if (entry.weather != null) ...[
                const SizedBox(width: 12),
                Text(
                  entry.weather!,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
              const Spacer(),
              // 重新写按钮
              if (_isRegenerating)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton.icon(
                  onPressed: () => _regenerateEntry(entry),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重新写', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF8D6E63),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                ),
            ],
          ),
          
          const SizedBox(height: 16),
          
          // 统计信息
          _buildStatsRow(entry),
          
          const SizedBox(height: 20),
          
          // 高光时刻
          if (entry.highlights.isNotEmpty) ...[
            _buildHighlightsSection(entry.highlights),
            const SizedBox(height: 20),
          ],
          
          // 日记内容
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF8E1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE0D5C5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('🪿', style: TextStyle(fontSize: 20)),
                    const SizedBox(width: 8),
                    const Text(
                      '鹅宝的日记',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF8D6E63),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  entry.content,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.8,
                    color: Color(0xFF4E342E),
                  ),
                ),
              ],
            ),
          ),
          
          // 特殊事件标签
          if (entry.specialEvent != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFCDD2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('🎉', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Text(
                    '今日特别: ${entry.specialEvent}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFFC62828),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatsRow(DiaryEntry entry) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _buildStatChip('💬 ${entry.messageCount} 条对话'),
        _buildStatChip('🤗 ${entry.interactionCount} 次互动'),
        if (entry.avgHappiness != null)
          _buildStatChip('😊 心情 ${entry.avgHappiness!.toStringAsFixed(0)}'),
      ],
    );
  }

  Widget _buildStatChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5EFE6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, color: Color(0xFF5D4037)),
      ),
    );
  }

  Widget _buildHighlightsSection(List<String> highlights) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '✨ 今日高光',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Color(0xFF8D6E63),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: highlights.map((h) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFFCC80)),
            ),
            child: Text(h, style: const TextStyle(fontSize: 12, color: Color(0xFFE65100))),
          )).toList(),
        ),
      ],
    );
  }

  Widget _buildNoSelectionState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('📔', style: TextStyle(fontSize: 48)),
          SizedBox(height: 12),
          Text(
            '选择一篇日记查看详情',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  String _getMoodEmoji(String mood) {
    switch (mood) {
      case 'happy': return '😊';
      case 'sad': return '😢';
      case 'excited': return '🤩';
      default: return '😐';
    }
  }

  /// 重新生成日记
  Future<void> _regenerateEntry(DiaryEntry entry) async {
    if (_isRegenerating) return;

    setState(() => _isRegenerating = true);

    try {
      final llmManager = context.read<LLMManager>();
      
      // 获取今日会话内容（仅当重新生成今天的日记时使用）
      final conversations = await ConversationManager.getTodayConversationsSummary();
      
      final success = await DiaryService.instance.regenerateEntry(
        entry.id,
        llmChatCallback: (systemPrompt, userMessage) async {
          final messages = [
            {'role': 'system', 'content': systemPrompt},
            {'role': 'user', 'content': userMessage},
          ];
          return await llmManager.chatRaw(messages);
        },
        todayConversationsCallback: () => conversations,
      );

      if (mounted) {
        if (success) {
          // 更新选中的日记（重新获取最新的条目）
          final newEntry = DiaryService.instance.entries.firstWhere(
            (e) => e.id == entry.id,
            orElse: () => entry,
          );
          setState(() => _selectedEntry = newEntry);
          
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('日记已重新生成~'),
              duration: Duration(seconds: 2),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('生成失败，请稍后重试'),
              duration: Duration(seconds: 2),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isRegenerating = false);
      }
    }
  }
}
