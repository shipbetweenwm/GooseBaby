import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import '../../ai/llm_manager.dart';
import '../../ai/memory/memory_manager.dart';

import '../../core/pet_engine.dart';
import '../../models/models.dart';
import '../../skills/skill_manager.dart';
import '../../skills/skill_base.dart';
import '../../skills/agent_skill.dart';
import '../../skills/script_skill.dart';
import '../../skills/skill_file_utils.dart';
import '../../utils/storage.dart';
import 'scheduled_task_panel.dart';

/// 设置面板
class SettingsPanel extends StatefulWidget {
  final VoidCallback? onClose;
  final void Function(String message)? onShowBubble;

  const SettingsPanel({super.key, this.onClose, this.onShowBubble});

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  int _selectedTab = 0;
  String _workingDir = '';

  final _tabs = const ['🧠 AI模型', '🎮 技能', '⏰ 定时任务', '🦢 宠物', '📋 关于'];

  /// 气泡回调便捷方法
  void _bubble(String message) => widget.onShowBubble?.call(message);

  @override
  void initState() {
    super.initState();
    _loadWorkingDir();
  }

  void _loadWorkingDir() {
    final saved = StorageManager.getSetting<String>('working_directory');
    if (saved != null && Directory(saved).existsSync()) {
      _workingDir = saved;
      SkillFileUtils.customWorkingDir = saved;
    }
  }

  @override
  Widget build(BuildContext context) {
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
          _buildTitleBar(),
          _buildWorkingDirSection(),
          _buildTabBar(),
          Expanded(child: _buildTabContent()),
        ],
      ),
    );
  }

  /// 工作目录设置区域
  Widget _buildWorkingDirSection() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF8F9FA),
        border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          const Text('工作目录:', style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _workingDir.isEmpty ? '默认（桌面）' : p.basename(_workingDir),
              style: TextStyle(
                fontSize: 13,
                color: _workingDir.isEmpty ? Colors.grey : Colors.black87,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: _selectWorkingDir,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
            ),
            child: const Text('选择', style: TextStyle(fontSize: 12)),
          ),
          if (_workingDir.isNotEmpty) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: _resetWorkingDir,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                minimumSize: Size.zero,
              ),
              child: const Text('重置', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _selectWorkingDir() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择工作目录',
      initialDirectory: _workingDir.isNotEmpty ? _workingDir : null,
    );
    if (result != null && mounted) {
      setState(() {
        _workingDir = result;
      });
      StorageManager.setSetting('working_directory', result);
      SkillFileUtils.customWorkingDir = result;
    }
  }

  void _resetWorkingDir() {
    setState(() {
      _workingDir = '';
    });
    Hive.box('settings').delete('working_directory');
    SkillFileUtils.customWorkingDir = null;
  }

  Widget _buildTitleBar() {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Row(
          children: [
            const Text(
              '⚙️ 鹅宝设置',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _tabs.length,
        itemBuilder: (context, i) {
          final isActive = _selectedTab == i;
          return GestureDetector(
            onTap: () => setState(() => _selectedTab = i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: isActive ? const Color(0xFF4FC3F7) : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                _tabs[i],
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                  color: isActive ? const Color(0xFF4FC3F7) : Colors.grey,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTabContent() {
    switch (_selectedTab) {
      case 0:
        return _AIModelSettings(onShowBubble: _bubble);
      case 1:
        return _SkillSettings();
      case 2:
        return _ScheduledTaskSettings();
      case 3:
        return _PetSettings();
      case 4:
        return _AboutPanel(onShowBubble: _bubble);
      default:
        return const SizedBox();
    }
  }
}

/// AI 模型设置
class _AIModelSettings extends StatefulWidget {
  final void Function(String)? onShowBubble;
  const _AIModelSettings({this.onShowBubble});
  @override
  State<_AIModelSettings> createState() => _AIModelSettingsState();
}

class _AIModelSettingsState extends State<_AIModelSettings> {
  String _selectedProvider = 'qwen';
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();
  final _endpointController = TextEditingController();
  bool _configLoaded = false;
  bool _enableWebSearch = false;
  bool _enableDeepThink = false;

  /// 各 provider 独立缓存配置（provider -> JSON），切换时保存/恢复
  final Map<String, Map<String, dynamic>> _providerConfigs = {};

  final _providers = {
    'qwen': {'name': '通义千问', 'icon': '🌐', 'hint': 'DashScope API Key'},
    'hunyuan': {'name': '腾讯混元', 'icon': '🔮', 'hint': '混元 API Key (控制台创建)'},
    'openai': {'name': 'OpenAI', 'icon': '🤖', 'hint': 'OpenAI API Key'},
    'claude': {'name': 'Claude', 'icon': '🧠', 'hint': 'Anthropic API Key'},
    'ollama': {'name': 'Ollama本地', 'icon': '🏠', 'hint': '无需API Key'},
    'chatglm': {'name': '智谱ChatGLM', 'icon': '🔮', 'hint': '智谱 API Key'},
  };

  /// 将当前输入框的值缓存到 _providerConfigs
  void _cacheCurrentConfig() {
    _providerConfigs[_selectedProvider] = {
      'apiKey': _apiKeyController.text,
      'model': _modelController.text,
      'baseUrl': _endpointController.text,
      'enableWebSearch': _enableWebSearch,
      'enableDeepThink': _enableDeepThink,
    };
  }

  /// 从 _providerConfigs 或 Hive 恢复指定 provider 的配置到输入框
  void _loadProviderConfig(String provider) {
    // 优先从内存缓存取
    var cfg = _providerConfigs[provider];
    // 缓存没有则从 Hive 读取
    if (cfg == null) {
      final box = Hive.box('settings');
      final saved = box.get('llm_config_$provider');
      if (saved != null && saved is Map) {
        cfg = Map<String, dynamic>.from(saved);
        _providerConfigs[provider] = cfg;
      }
    }
    if (cfg != null) {
      _apiKeyController.text = cfg['apiKey'] ?? '';
      _modelController.text = cfg['model'] ?? '';
      _endpointController.text = cfg['baseUrl'] ?? '';
      _enableWebSearch = cfg['enableWebSearch'] ?? false;
      _enableDeepThink = cfg['enableDeepThink'] ?? false;
    } else {
      _apiKeyController.clear();
      _modelController.clear();
      _endpointController.clear();
      _enableWebSearch = false;
      _enableDeepThink = false;
    }
    // 混元旧版 URL 自动清空
    if (provider == 'hunyuan' && _endpointController.text.contains('hunyuan.tencentcloudapi.com')) {
      _endpointController.clear();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_configLoaded) {
      _configLoaded = true;
      final llmManager = context.read<LLMManager>();
      final config = llmManager.currentConfig;
      _selectedProvider = config.provider;
      // 用当前活跃的 config 初始化
      _apiKeyController.text = config.apiKey;
      _modelController.text = config.model;
      final savedUrl = config.baseUrl ?? '';
      if (config.provider == 'hunyuan' && savedUrl.contains('hunyuan.tencentcloudapi.com')) {
        _endpointController.text = '';
      } else {
        _endpointController.text = savedUrl;
      }
      _enableWebSearch = config.enableWebSearch;
      _enableDeepThink = config.enableDeepThink;
      // 缓存当前 provider 的配置
      _providerConfigs[_selectedProvider] = {
        'apiKey': _apiKeyController.text,
        'model': _modelController.text,
        'baseUrl': _endpointController.text,
        'enableWebSearch': _enableWebSearch,
        'enableDeepThink': _enableDeepThink,
      };
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _modelController.dispose();
    _endpointController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '选择 AI 模型',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),

          // 模型选择卡片
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _providers.entries.map((entry) {
              final isSelected = _selectedProvider == entry.key;
              return GestureDetector(
                onTap: () {
                  if (_selectedProvider != entry.key) {
                    _cacheCurrentConfig();
                    setState(() {
                      _selectedProvider = entry.key;
                    });
                    _loadProviderConfig(entry.key);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF4FC3F7).withOpacity(0.1) : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: isSelected ? const Color(0xFF4FC3F7) : Colors.grey.shade200,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(entry.value['icon']!, style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 6),
                      Text(
                        entry.value['name']!,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                          color: isSelected ? const Color(0xFF4FC3F7) : Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 20),

          // API Key 输入
          if (_selectedProvider != 'ollama') ...[
            _SettingField(
              label: 'API Key',
              hint: _providers[_selectedProvider]?['hint'] ?? '',
              controller: _apiKeyController,
              isPassword: true,
            ),
            const SizedBox(height: 12),
          ],

          // 模型名称
          _SettingField(
            label: '模型名称',
            hint: _getDefaultModel(),
            controller: _modelController,
          ),
          const SizedBox(height: 12),

          // API 端点
          _SettingField(
            label: 'API 端点 (可选)',
            hint: _getDefaultEndpoint(),
            controller: _endpointController,
          ),

          const SizedBox(height: 16),

          // 增强功能开关
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.7),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '增强功能',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('联网搜索', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    _selectedProvider == 'ollama'
                        ? '需要 Ollama v0.5+'
                        : '让 AI 搜索互联网获取实时信息',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
                  value: _enableWebSearch,
                  activeColor: const Color(0xFF4FC3F7),
                  onChanged: (v) => setState(() => _enableWebSearch = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('深度思考', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    _selectedProvider == 'hunyuan'
                        ? '选择思考模型（如 hunyuan-turbos）自动启用'
                        : '启用推理增强，提高复杂问题回答质量',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                  ),
                  value: _enableDeepThink,
                  activeColor: const Color(0xFF4FC3F7),
                  onChanged: _selectedProvider == 'ollama'
                      ? null // Ollama 本地模型不支持
                      : (v) => setState(() => _enableDeepThink = v),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // 保存按钮
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saveSettings,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4FC3F7),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('保存配置'),
            ),
          ),
        ],
      ),
    );
  }

  String _getDefaultModel() {
    switch (_selectedProvider) {
      case 'qwen': return 'qwen-turbo';
      case 'hunyuan': return 'hunyuan-lite';
      case 'openai': return 'gpt-4o-mini';
      case 'claude': return 'claude-3-haiku-20240307';
      case 'ollama': return 'llama3';
      default: return '';
    }
  }

  String _getDefaultEndpoint() {
    switch (_selectedProvider) {
      case 'qwen': return 'https://dashscope.aliyuncs.com/compatible-mode/v1';
      case 'hunyuan': return 'https://api.hunyuan.cloud.tencent.com/v1';
      case 'openai': return 'https://api.openai.com/v1';
      case 'claude': return 'https://api.anthropic.com';
      case 'ollama': return 'http://localhost:11434';
      case 'chatglm': return 'https://open.bigmodel.cn/api/paas/v4';
      default: return '';
    }
  }

  void _saveSettings() {
    final llmManager = context.read<LLMManager>();
    final config = LLMConfig(
      provider: _selectedProvider,
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim().isEmpty ? _getDefaultModel() : _modelController.text.trim(),
      baseUrl: _endpointController.text.trim().isEmpty ? _getDefaultEndpoint() : _endpointController.text.trim(),
      enableWebSearch: _enableWebSearch,
      enableDeepThink: _enableDeepThink,
    );
    llmManager.setConfig(config);

    // 独立保存当前 provider 的配置
    final box = Hive.box('settings');
    box.put('llm_config_${_selectedProvider}', config.toJson());

    widget.onShowBubble?.call('✅ AI模型配置已保存~ 嘎！');
  }
}

/// 技能设置（支持导入文件/文件夹、刷新、删除外部技能）
class _SkillSettings extends StatefulWidget {
  @override
  State<_SkillSettings> createState() => _SkillSettingsState();
}

class _SkillSettingsState extends State<_SkillSettings> {
  bool _isLoading = false;
  String _statusMessage = '';

  @override
  Widget build(BuildContext context) {
    final skillManager = context.watch<SkillManager>();

    // 技能尚未初始化完成时显示加载提示
    if (!skillManager.isInitialized) {
      return const Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(strokeWidth: 2),
                  SizedBox(height: 12),
                  Text('正在加载技能...', style: TextStyle(fontSize: 13, color: Colors.grey)),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final categories = skillManager.getSkillsByCategory();
    
    // 过滤掉 MCP 技能（不显示在技能板中）
    final filteredCategories = <String, List<GooseSkill>>{};
    categories.forEach((category, skills) {
      final filtered = skills.where((s) => s.id != 'mcp_tools').toList();
      if (filtered.isNotEmpty) {
        filteredCategories[category] = filtered;
      }
    });

    return Column(
      children: [
        // 操作栏：导入 + 刷新
        _buildActionBar(skillManager),
        // 状态消息
        if (_statusMessage.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: const Color(0xFFE8F5E9),
            child: Row(
              children: [
                if (_isLoading)
                  const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  const Icon(Icons.check_circle, size: 14, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusMessage,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF2E7D32)),
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _statusMessage = ''),
                  child: const Icon(Icons.close, size: 14, color: Colors.grey),
                ),
              ],
            ),
          ),
        // 技能列表（可滚动）
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: filteredCategories.entries.map((entry) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    child: Row(
                      children: [
                        Text(
                          entry.key,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${entry.value.length}',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ...entry.value.map((skill) {
                    final isEnabled = skillManager.enabledSkills.contains(skill);
                    final isExternal = skillManager.isExternalSkill(skill.id);
                    // 有源文件目录的技能才允许删除（外部导入 + skills/ 目录加载的目录级技能）
                    final canDelete = _skillHasSource(skill);
                    return _SkillCard(
                      skill: skill,
                      isEnabled: isEnabled,
                      isExternal: isExternal,
                      onToggle: (v) => skillManager.setEnabled(skill.id, v),
                      onDelete: canDelete ? () => _deleteSkill(skillManager, skill) : null,
                      onTap: () => _showSkillDetail(skill),
                    );
                  }),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildActionBar(SkillManager skillManager) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: const Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      child: Row(
        children: [
          // 导入 ZIP 技能包
          _ActionChip(
            icon: Icons.archive,
            label: '导入ZIP',
            onTap: () => _importZip(skillManager),
          ),
          const SizedBox(width: 6),
          // 导入文件夹
          _ActionChip(
            icon: Icons.folder_open,
            label: '导入文件夹',
            onTap: () => _importFolder(skillManager),
          ),
          const SizedBox(width: 6),
          // 从 JSON 创建技能
          _ActionChip(
            icon: Icons.add_circle_outline,
            label: '创建技能',
            onTap: () => _createSkillFromJson(skillManager),
          ),
          const Spacer(),
          // 外部技能数量
          if (skillManager.externalSkillCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF4FC3F7).withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '外部: ${skillManager.externalSkillCount}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF4FC3F7), fontWeight: FontWeight.w600),
              ),
            ),
          if (skillManager.agentSkillCount > 0) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF66BB6A).withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Agent: ${skillManager.agentSkillCount}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF66BB6A), fontWeight: FontWeight.w600),
              ),
            ),
          ],
          const SizedBox(width: 6),
          // 刷新按钮
          InkWell(
            onTap: _isLoading ? null : () => _refreshSkills(skillManager),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                Icons.refresh,
                size: 18,
                color: _isLoading ? Colors.grey.shade300 : Colors.grey.shade600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _importZip(SkillManager skillManager) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        dialogTitle: '选择技能包 ZIP 文件',
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) return;

      if (!mounted) return;
      setState(() {
        _isLoading = true;
        _statusMessage = '正在导入 ZIP...';
      });

      int successCount = 0;
      for (final file in result.files) {
        if (file.path != null) {
          final count = await skillManager.importFromZip(file.path!);
          successCount += count;
        }
      }

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _statusMessage = successCount > 0
            ? '✅ 成功导入 $successCount 个技能！'
            : '⚠️ ZIP 中未找到有效技能';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _statusMessage = '❌ ZIP 导入出错: $e';
      });
    }
  }

  Future<void> _importFolder(SkillManager skillManager) async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择技能包文件夹',
      );

      if (result == null) return;

      if (!mounted) return;
      setState(() {
        _isLoading = true;
        _statusMessage = '正在从文件夹导入...';
      });

      final count = await skillManager.importFromFolder(result);

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _statusMessage = count > 0
            ? '✅ 从文件夹导入 $count 个技能！'
            : '⚠️ 文件夹中未找到有效技能';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _statusMessage = '❌ 文件夹导入出错: $e';
      });
    }
  }

  Future<void> _refreshSkills(SkillManager skillManager) async {
    setState(() {
      _isLoading = true;
      _statusMessage = '正在刷新外部技能...';
    });

    final count = await skillManager.reloadSkills();

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _statusMessage = '✅ 已刷新，加载了 $count 个外部技能';
    });
  }

  void _deleteSkill(SkillManager skillManager, GooseSkill skill) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除技能 "${skill.name}"？'),
        content: const Text('此操作将永久删除技能及其源文件，无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final deleted = await skillManager.deleteSkill(skill.id);
              if (mounted) {
                setState(() {
                  _statusMessage = deleted
                      ? '已删除技能: ${skill.name}'
                      : '已移除技能: ${skill.name}（源文件未找到）';
                });
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 判断技能是否有源文件目录（可删除）
  bool _skillHasSource(GooseSkill skill) {
    if (skill is AgentSkill) return skill.sourcePath != null;
    if (skill is ScriptSkill) return skill.sourcePath != null;
    return false;
  }

  void _createSkillFromJson(SkillManager skillManager) {
    final jsonController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('创建自定义技能'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '粘贴 JSON 配置来创建一个新技能：',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: jsonController,
              maxLines: 8,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: '{"id": "my_skill", "name": "我的技能", ...}',
                hintStyle: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.all(8),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final json = jsonController.text.trim();
              if (json.isEmpty) return;
              final success = skillManager.registerFromJson(json);
              Navigator.of(ctx).pop();
              if (mounted) {
                setState(() {
                  _statusMessage = success
                      ? '✅ 技能创建成功！'
                      : '⚠️ JSON 格式无效，请检查配置';
                });
              }
            },
            style: TextButton.styleFrom(foregroundColor: Color(0xFF4FC3F7)),
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _showSkillDetail(GooseSkill skill) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 360,
          constraints: const BoxConstraints(maxHeight: 480),
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题行
                Row(
                  children: [
                    Text(skill.icon, style: const TextStyle(fontSize: 28)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(skill.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          Row(
                            children: [
                              Text(skill.category, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                              if (skill is AgentSkill) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF66BB6A).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'Agent',
                                    style: TextStyle(fontSize: 9, color: Color(0xFF66BB6A), fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 描述
                Text(skill.description, style: const TextStyle(fontSize: 13, height: 1.5)),
                const SizedBox(height: 12),
                // ID
                _DetailRow(label: 'ID', value: skill.id),
                // 来源
                if (skill is ScriptSkill && skill.sourcePath != null)
                  _DetailRow(label: '来源', value: skill.sourcePath!),
                if (skill is ScriptSkill && skill.packName != null)
                  _DetailRow(label: '技能包', value: skill.packName!),
                // Agent Skill 特有信息
                if (skill is AgentSkill) ...[
                  _DetailRow(label: '版本', value: skill.version),
                  if (skill.sourcePath != null)
                    _DetailRow(label: '来源', value: skill.sourcePath!),
                  if (skill.allowedTools.isNotEmpty)
                    _DetailRow(label: '工具', value: skill.allowedTools),
                  if (skill.requiredBins.isNotEmpty)
                    _DetailRow(label: '依赖', value: skill.requiredBins.join(', ')),
                  if (skill.readWhen.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('触发场景', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    ...skill.readWhen.map((when) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('• ', style: TextStyle(fontSize: 12, color: Color(0xFF66BB6A))),
                          Expanded(
                            child: Text(
                              when,
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                            ),
                          ),
                        ],
                      ),
                    )),
                  ],
                  // 脚本列表
                  if (skill.scripts.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.code, size: 14, color: Color(0xFF42A5F5)),
                        const SizedBox(width: 4),
                        Text(
                          '脚本 (${skill.scripts.length})',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ...skill.scripts.map((script) => Container(
                      margin: const EdgeInsets.only(bottom: 3),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF42A5F5).withOpacity(0.06),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.insert_drive_file_outlined, size: 13, color: Color(0xFF42A5F5)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              script.commandPath,
                              style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w500),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFF42A5F5).withOpacity(0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              script.language,
                              style: const TextStyle(fontSize: 9, color: Color(0xFF42A5F5)),
                            ),
                          ),
                        ],
                      ),
                    )),
                  ],
                  // 参考文档列表
                  if (skill.referenceFiles.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Icon(Icons.description_outlined, size: 14, color: Color(0xFFFFA726)),
                        const SizedBox(width: 4),
                        Text(
                          '参考文档 (${skill.referenceFiles.length})',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ...skill.referenceFiles.map((ref) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        children: [
                          const Text('📄 ', style: TextStyle(fontSize: 11)),
                          Expanded(
                            child: Text(
                              ref,
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade700, fontFamily: 'monospace'),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    )),
                  ],
                ],
                const SizedBox(height: 12),
                // 参数列表
                if (skill.params.isNotEmpty) ...[
                  const Text('参数', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  ...skill.params.map((p) => Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Text(
                          p.name,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, fontFamily: 'monospace'),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF4FC3F7).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(p.type, style: const TextStyle(fontSize: 10, color: Color(0xFF4FC3F7))),
                        ),
                        if (p.required) ...[
                          const SizedBox(width: 4),
                          const Text('*', style: TextStyle(fontSize: 12, color: Colors.red)),
                        ],
                        const Spacer(),
                        Flexible(
                          child: Text(
                            p.description,
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  )),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// MCP 服务器设置
class _McpSettings extends StatefulWidget {
  final void Function(String)? onShowBubble;
  const _McpSettings({this.onShowBubble});
  @override
  State<_McpSettings> createState() => _McpSettingsState();
}

class _McpSettingsState extends State<_McpSettings> {
  final Map<String, McpServerConfig> _serverConfigs = {};
  final _nameController = TextEditingController();
  final _commandController = TextEditingController();
  final _argsController = TextEditingController();
  final _envController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  void _loadConfigs() {
    final saved = StorageManager.getSetting<Map<dynamic, dynamic>>('mcp_servers', defaultValue: {});
    if (saved != null) {
      setState(() {
        saved.forEach((key, value) {
          if (value is Map) {
            _serverConfigs[key.toString()] = McpServerConfig.fromJson(
              Map<String, dynamic>.from(value),
            );
          }
        });
      });
    }
  }

  void _saveConfigs() {
    final data = <String, dynamic>{};
    _serverConfigs.forEach((key, config) {
      data[key] = config.toJson();
    });
    StorageManager.setSetting('mcp_servers', data);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _commandController.dispose();
    _argsController.dispose();
    _envController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 操作栏
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            border: const Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
          ),
          child: Row(
            children: [
              const Text(
                'MCP 服务器',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              _ActionChip(
                icon: Icons.add,
                label: '添加服务器',
                onTap: _showAddServerDialog,
              ),
            ],
          ),
        ),
        // 服务器列表
        Expanded(
          child: _serverConfigs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.extension_outlined, size: 48, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text(
                        '暂无 MCP 服务器',
                        style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'MCP 让鹅宝可以使用更多外部工具',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _serverConfigs.length,
                  itemBuilder: (context, index) {
                    final entry = _serverConfigs.entries.elementAt(index);
                    return _McpServerCard(
                      name: entry.key,
                      config: entry.value,
                      onEdit: () => _editServer(entry.key, entry.value),
                      onDelete: () => _deleteServer(entry.key),
                      onToggle: (enabled) => _toggleServer(entry.key, enabled),
                    );
                  },
                ),
        ),
        // 帮助说明
        Container(
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: Colors.blue.shade400),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'MCP (Model Context Protocol) 让鹅宝可以使用外部工具，如文件系统、数据库、API 等。',
                  style: TextStyle(fontSize: 11, color: Colors.blue.shade700),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showAddServerDialog() {
    _nameController.clear();
    _commandController.clear();
    _argsController.clear();
    _envController.clear();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('添加 MCP 服务器'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingField(
                label: '服务器名称',
                hint: '如: filesystem',
                controller: _nameController,
              ),
              const SizedBox(height: 12),
              _SettingField(
                label: '启动命令',
                hint: '如: npx',
                controller: _commandController,
              ),
              const SizedBox(height: 12),
              _SettingField(
                label: '参数 (空格分隔)',
                hint: '如: -y @modelcontextprotocol/server-filesystem /path',
                controller: _argsController,
              ),
              const SizedBox(height: 12),
              _SettingField(
                label: '环境变量 (JSON)',
                hint: '{"API_KEY": "xxx"}',
                controller: _envController,
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () => _addServer(ctx),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4FC3F7),
              foregroundColor: Colors.white,
            ),
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _addServer(BuildContext ctx) {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      widget.onShowBubble?.call('请输入服务器名称');
      return;
    }

    final args = _argsController.text.trim().split(' ').where((s) => s.isNotEmpty).toList();
    
    Map<String, String>? env;
    if (_envController.text.trim().isNotEmpty) {
      try {
        final envMap = <String, String>{};
        final decoded = _envController.text.trim();
        // 简单解析 KEY=value 格式
        if (!decoded.startsWith('{')) {
          for (final line in decoded.split('\n')) {
            final parts = line.split('=');
            if (parts.length == 2) {
              envMap[parts[0].trim()] = parts[1].trim();
            }
          }
        }
        env = envMap.isNotEmpty ? envMap : null;
      } catch (_) {}
    }

    setState(() {
      _serverConfigs[name] = McpServerConfig(
        command: _commandController.text.trim(),
        args: args,
        env: env,
        enabled: true,
      );
    });
    _saveConfigs();
    Navigator.of(ctx).pop();

    widget.onShowBubble?.call('✅ 已添加 MCP 服务器: $name');
  }

  void _editServer(String name, McpServerConfig config) {
    _nameController.text = name;
    _commandController.text = config.command;
    _argsController.text = config.args.join(' ');
    _envController.text = config.env?.entries.map((e) => '${e.key}=${e.value}').join('\n') ?? '';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('编辑 $name'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingField(
                label: '启动命令',
                hint: '如: npx',
                controller: _commandController,
              ),
              const SizedBox(height: 12),
              _SettingField(
                label: '参数 (空格分隔)',
                hint: '如: -y @modelcontextprotocol/server-filesystem /path',
                controller: _argsController,
              ),
              const SizedBox(height: 12),
              _SettingField(
                label: '环境变量 (KEY=value)',
                hint: 'API_KEY=xxx',
                controller: _envController,
                maxLines: 3,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              final args = _argsController.text.trim().split(' ').where((s) => s.isNotEmpty).toList();
              
              Map<String, String>? env;
              if (_envController.text.trim().isNotEmpty) {
                final envMap = <String, String>{};
                for (final line in _envController.text.trim().split('\n')) {
                  final parts = line.split('=');
                  if (parts.length == 2) {
                    envMap[parts[0].trim()] = parts[1].trim();
                  }
                }
                env = envMap.isNotEmpty ? envMap : null;
              }

              setState(() {
                _serverConfigs[name] = McpServerConfig(
                  command: _commandController.text.trim(),
                  args: args,
                  env: env,
                  enabled: config.enabled,
                );
              });
              _saveConfigs();
              Navigator.of(ctx).pop();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF4FC3F7),
              foregroundColor: Colors.white,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _deleteServer(String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除服务器 "$name"？'),
        content: const Text('此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              setState(() => _serverConfigs.remove(name));
              _saveConfigs();
              Navigator.of(ctx).pop();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  void _toggleServer(String name, bool enabled) {
    final config = _serverConfigs[name];
    if (config != null) {
      setState(() {
        _serverConfigs[name] = McpServerConfig(
          command: config.command,
          args: config.args,
          env: config.env,
          enabled: enabled,
        );
      });
      _saveConfigs();
    }
  }
}

/// MCP 服务器卡片
class _McpServerCard extends StatelessWidget {
  final String name;
  final McpServerConfig config;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  const _McpServerCard({
    required this.name,
    required this.config,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: (config.enabled ? const Color(0xFF4FC3F7) : Colors.grey)
                  .withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.extension,
              color: config.enabled ? const Color(0xFF4FC3F7) : Colors.grey,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  '${config.command} ${config.args.take(2).join(' ')}${config.args.length > 2 ? '...' : ''}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // 编辑按钮
          InkWell(
            onTap: onEdit,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.edit_outlined, size: 18, color: Colors.grey.shade600),
            ),
          ),
          // 删除按钮
          InkWell(
            onTap: onDelete,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade400),
            ),
          ),
          // 启用开关
          Switch(
            value: config.enabled,
            onChanged: onToggle,
            activeColor: const Color(0xFF4FC3F7),
          ),
        ],
      ),
    );
  }
}

/// MCP 服务器配置
class McpServerConfig {
  final String command;
  final List<String> args;
  final Map<String, String>? env;
  final bool enabled;

  McpServerConfig({
    required this.command,
    this.args = const [],
    this.env,
    this.enabled = true,
  });

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    return McpServerConfig(
      command: json['command'] as String? ?? '',
      args: (json['args'] as List?)?.map((e) => e.toString()).toList() ?? [],
      env: json['env'] != null
          ? Map<String, String>.from(json['env'] as Map)
          : null,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'command': command,
      'args': args,
      if (env != null) 'env': env,
      'enabled': enabled,
    };
  }
}

/// 定时任务设置
class _ScheduledTaskSettings extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const ScheduledTaskPanel();
  }
}

/// 宠物设置
class _PetSettings extends StatefulWidget {
  @override
  State<_PetSettings> createState() => _PetSettingsState2();
}

class _PetSettingsState2 extends State<_PetSettings> {
  double _chatFontSize = StorageManager.getSetting<double>('chat_font_size', defaultValue: 14.0) ?? 14.0;

  @override
  void initState() {
    super.initState();
    _chatFontSize = StorageManager.getSetting<double>('chat_font_size', defaultValue: 14.0) ?? 14.0;
  }

  @override
  Widget build(BuildContext context) {
    final engine = context.watch<PetEngine>();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '鹅宝个性化',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          _SettingToggle(
            title: '始终置顶',
            subtitle: '鹅宝始终显示在最上层',
            value: engine.alwaysOnTop,
            onChanged: (v) {
              engine.setAlwaysOnTop(v);
              windowManager.setAlwaysOnTop(v);
            },
          ),
          _SettingToggle(
            title: '智能关怀',
            subtitle: '贴心关心 + 健康/喝水/休息提醒',
            value: engine.notificationEnabled && engine.healthReminderEnabled,
            onChanged: (v) {
              engine.setNotificationEnabled(v);
              engine.setHealthReminderEnabled(v);
            },
          ),
          if (engine.healthReminderEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '提醒间隔',
                        style: TextStyle(fontSize: 13, color: Colors.black54),
                      ),
                      const Spacer(),
                      Text(
                        '${engine.healthReminderInterval}分钟',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  Slider(
                    value: engine.healthReminderInterval.toDouble(),
                    min: 5,
                    max: 120,
                    divisions: 23,
                    label: '${engine.healthReminderInterval}分钟',
                    onChanged: (v) => engine.setHealthReminderInterval(v.round()),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          const Text(
            '透明度',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: engine.opacity,
                  onChanged: (v) {
                    engine.setOpacity(v);
                    windowManager.setOpacity(v);
                  },
                  min: 0.3,
                  max: 1.0,
                  activeColor: const Color(0xFF4FC3F7),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${(engine.opacity * 100).toInt()}%',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '鹅宝大小',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: engine.scale.clamp(0.5, 1.0),
                  onChanged: (v) => engine.setScale(v),
                  min: 0.5,
                  max: 1.0,
                  activeColor: const Color(0xFF4FC3F7),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${(engine.scale * 100).toInt()}%',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '对话框字体大小',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: _chatFontSize,
                  min: 10,
                  max: 22,
                  activeColor: const Color(0xFF4FC3F7),
                  onChanged: (v) {
                    setState(() => _chatFontSize = v);
                    StorageManager.setSetting('chat_font_size', v);
                  },
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${_chatFontSize.toInt()}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 关于面板
class _AboutPanel extends StatelessWidget {
  final void Function(String)? onShowBubble;
  const _AboutPanel({this.onShowBubble});
  @override
  Widget build(BuildContext context) {
    final engine = context.watch<PetEngine>();
    final memoryManager = context.watch<MemoryManager>();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🦢', style: TextStyle(fontSize: 48)),
          const SizedBox(height: 8),
          const Text(
            '鹅宝 GooseBaby',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'v1.0.0',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 12),
          Text(
            'AI 驱动的桌面智能宠物伙伴',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),

          // 鹅宝数据统计
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFF3E5F5).withOpacity(0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('📊 数据统计', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                _InfoRow(label: '等级', value: 'Lv.${engine.state.level} (${engine.state.exp}/${engine.state.expToNextLevel} EXP)'),
                _InfoRow(label: '陪伴', value: '${engine.state.companionDays} 天'),
                _InfoRow(label: '金币', value: '🪙 ${engine.coins}'),
                _InfoRow(label: '记忆', value: '${memoryManager.longTermMemories.length} 条长期记忆'),
                _InfoRow(label: '画像', value: '${memoryManager.userProfile.length} 个标签'),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 用户画像预览
          if (memoryManager.userProfile.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.blue.shade50.withOpacity(0.4),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('🧠 鹅宝记住的', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => _showClearMemoryDialog(context, memoryManager),
                        child: Text('清除', style: TextStyle(fontSize: 11, color: Colors.red.shade300)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ...memoryManager.userProfile.entries.take(5).map((e) =>
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '${e.key}: ${e.value}',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (memoryManager.userProfile.length > 5)
                    Text(
                      '... 还有 ${memoryManager.userProfile.length - 5} 项',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),

          // 技术信息
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Column(
              children: [
                _InfoRow(label: '框架', value: 'Flutter + Dart'),
                _InfoRow(label: '平台', value: 'macOS / Windows'),
                _InfoRow(label: 'AI引擎', value: '千问 / 混元 / OpenAI / Claude / Ollama'),
                _InfoRow(label: '许可', value: 'MIT License'),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 数据操作按钮
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showClearMemoryDialog(context, memoryManager),
                  icon: const Icon(Icons.psychology_outlined, size: 16),
                  label: const Text('清除记忆', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orange,
                    side: const BorderSide(color: Colors.orange),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _showResetDialog(context),
                  icon: const Icon(Icons.restore, size: 16),
                  label: const Text('重置数据', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showClearMemoryDialog(BuildContext context, MemoryManager memoryManager) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('清除鹅宝记忆？'),
        content: const Text('这将清除鹅宝对你的所有记忆（包括名字、喜好等），但不会影响对话历史和宠物状态。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              memoryManager.clearAll();
              Navigator.of(ctx).pop();
              onShowBubble?.call('🦢 鹅宝的记忆已清除~ 让我们重新认识吧！');
            },
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('确定清除'),
          ),
        ],
      ),
    );
  }

  void _showResetDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('⚠️ 重置所有数据？'),
        content: const Text('这将清除所有数据：宠物状态、等级、金币、记忆、聊天历史、设置配置。此操作不可撤销！'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              await StorageManager.clearAll();
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (context.mounted) {
                onShowBubble?.call('🦢 所有数据已重置~ 重启应用后生效');
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('确定重置'),
          ),
        ],
      ),
    );
  }
}

/// 通用设置组件
class _SettingField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final bool isPassword;
  final int maxLines;

  const _SettingField({
    required this.label,
    required this.hint,
    required this.controller,
    this.isPassword = false,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: isPassword,
          maxLines: maxLines,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
          ),
          style: const TextStyle(fontSize: 13),
        ),
      ],
    );
  }
}

class _SettingToggle extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingToggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14)),
                Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFF4FC3F7),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// 技能卡片组件
class _SkillCard extends StatelessWidget {
  final GooseSkill skill;
  final bool isEnabled;
  final bool isExternal;
  final ValueChanged<bool> onToggle;
  final VoidCallback? onDelete;
  final VoidCallback? onTap;

  const _SkillCard({
    required this.skill,
    required this.isEnabled,
    required this.isExternal,
    required this.onToggle,
    this.onDelete,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: skill is AgentSkill
              ? const Color(0xFFE8F5E9).withOpacity(0.4)
              : isExternal
                  ? const Color(0xFFF3E5F5).withOpacity(0.3)
                  : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: skill is AgentSkill
              ? Border.all(color: const Color(0xFF66BB6A).withOpacity(0.3))
              : isExternal
                  ? Border.all(color: const Color(0xFFCE93D8).withOpacity(0.3))
                  : null,
        ),
        child: Row(
          children: [
            Text(skill.icon, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          skill.name,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (skill is AgentSkill) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFF66BB6A).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'Agent',
                            style: TextStyle(fontSize: 9, color: Color(0xFF66BB6A), fontWeight: FontWeight.w600),
                          ),
                        ),
                      ] else if (isExternal) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFAB47BC).withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '外部',
                            style: TextStyle(fontSize: 9, color: Color(0xFFAB47BC), fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    skill.description,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (onDelete != null)
              InkWell(
                onTap: onDelete,
                borderRadius: BorderRadius.circular(8),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline, size: 16, color: Colors.red),
                ),
              ),
            Switch(
              value: isEnabled,
              onChanged: onToggle,
              activeColor: const Color(0xFF4FC3F7),
            ),
          ],
        ),
      ),
    );
  }
}

/// 操作小按钮
class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: const Color(0xFF4FC3F7)),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// 详情行
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 50,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
