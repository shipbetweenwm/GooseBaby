import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import '../../ai/llm_manager.dart';
import '../../ai/memory/memory_manager.dart';
import '../../ai/memory/context_manager.dart';
import '../../ai/config/agent_config.dart';

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

  final _tabs = const ['🧠 AI模型', '🎮 技能', '⏰ 定时任务', '🔧 Agent', '🦢 宠物', '📋 关于'];

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
        return _AgentSettings(onShowBubble: _bubble);
      case 4:
        return _PetSettings();
      case 5:
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
  String _selectedModel = '';
  final _apiKeyController = TextEditingController();
  bool _configLoaded = false;
  bool _enableWebSearch = false;
  bool _enableDeepThink = false;
  PromptLevel _promptLevel = PromptLevel.full;

  // ── 多模态模型（品牌跟随文本模型）──
  String _visionModel = '';

  /// 各 provider 独立缓存（切换时保存/恢复）
  final Map<String, Map<String, dynamic>> _providerConfigs = {};

  // ════════════════════════════════════════════
  // 精简的品牌 + 预设模型列表
  // ════════════════════════════════════════════
  static const _brands = {
    'qwen':    {'name': '通义千问',     'icon': '🌐', 'hint': 'DashScope API Key (sk-xxx)'},
    'hunyuan': {'name': '腾讯混元',     'icon': '🔮', 'hint': '混元 API Key'},
    'chatglm': {'name': '智谱 GLM',    'icon': '🔬', 'hint': '智谱 API Key'},
    'openai':  {'name': 'OpenAI',      'icon': '🤖', 'hint': 'OpenAI API Key (sk-xxx)'},
    'claude':  {'name': 'Claude',      'icon': '🧠', 'hint': 'Anthropic API Key (sk-ant-xxx)'},
    'gemini':  {'name': 'Gemini',      'icon': '💎', 'hint': 'Google AI API Key'},
    'ollama':  {'name': 'Ollama 本地', 'icon': '🏠', 'hint': '无需 API Key'},
  };

  /// 每个品牌的预设模型列表  [model_id, 显示名]
  static const _presetModels = <String, List<List<String>>>{
    'qwen': [
      ['qwen3-max',         'Qwen3 Max（旗舰）'],
      ['qwen3-plus',        'Qwen3 Plus（均衡）'],
      ['qwen3-turbo',       'Qwen3 Turbo（快速）'],
      ['qwq-plus',          'QwQ Plus（推理增强）'],
      ['qwen3-235b-a22b',   'Qwen3-235B（开源旗舰）'],
      ['qwen3-32b',         'Qwen3-32B（开源均衡）'],
    ],
    'hunyuan': [
      ['hunyuan-t1',            'Hunyuan T1（旗舰推理）'],
      ['hunyuan-turbos-latest', 'Hunyuan TurboS（快速思考）'],
      ['hunyuan-a13b',          'Hunyuan A13B（MoE 均衡）'],
      ['hunyuan-large',         'Hunyuan Large（高质量）'],
      ['hunyuan-lite',          'Hunyuan Lite（免费）'],
    ],
    'chatglm': [
      ['glm-5',        'GLM-5（旗舰）'],
      ['glm-5-turbo',  'GLM-5 Turbo（快速）'],
      ['glm-4-plus',   'GLM-4 Plus'],
      ['glm-4-flash',  'GLM-4 Flash（免费）'],
    ],
    'openai': [
      ['gpt-4o',          'GPT-4o'],
      ['gpt-4o-mini',     'GPT-4o Mini（快速省钱）'],
      ['o3',              'o3（最强推理）'],
      ['o4-mini',         'o4-mini（快速推理）'],
    ],
    'claude': [
      ['claude-opus-4-5',           'Claude Opus 4.5（最强）'],
      ['claude-sonnet-4-5',         'Claude Sonnet 4.5（均衡）'],
      ['claude-3-7-sonnet-20250219','Claude 3.7 Sonnet（思考）'],
      ['claude-3-5-haiku-20241022', 'Claude 3.5 Haiku（快速）'],
    ],
    'gemini': [
      ['gemini-2.5-pro',          'Gemini 2.5 Pro（最强）'],
      ['gemini-2.0-flash',        'Gemini 2.0 Flash（均衡）'],
      ['gemini-2.0-flash-lite',   'Gemini 2.0 Flash Lite（快速）'],
    ],
    'ollama': [
      ['llama3.3',       'Llama 3.3 70B'],
      ['qwen3:30b',      'Qwen3 30B'],
      ['deepseek-r2',    'DeepSeek R2'],
      ['gemma3:27b',     'Gemma 3 27B'],
      ['mistral',        'Mistral'],
    ],
  };

  /// 多模态预设模型列表 [model_id, 显示名]
  static const _visionPresetModels = <String, List<List<String>>>{
    'qwen': [
      ['qwen3-vl-plus',    'Qwen3-VL Plus（最强视觉）'],
      ['qwen3-vl-flash',   'Qwen3-VL Flash（快速）'],
      ['qwen-vl-max',      'Qwen-VL Max（上代旗舰）'],
    ],
    'hunyuan': [
      ['hunyuan-vision',   'Hunyuan Vision（视觉旗舰）'],
    ],
    'chatglm': [
      ['glm-4v-plus',      'GLM-4V Plus（最强视觉）'],
      ['glm-4v-flash',     'GLM-4V Flash（快速）'],
    ],
    'claude': [
      ['claude-sonnet-4-20250514',      'Claude Sonnet 4（推荐）'],
      ['claude-3-5-sonnet-20241022',    'Claude 3.5 Sonnet'],
      ['claude-3-5-haiku-20241022',     'Claude 3.5 Haiku（快速）'],
    ],
  };

  /// 各品牌默认 API 端点
  static const _defaultEndpoints = {
    'qwen':    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'hunyuan': 'https://api.hunyuan.cloud.tencent.com/v1',
    'chatglm': 'https://open.bigmodel.cn/api/paas/v4',
    'openai':  'https://api.openai.com/v1',
    'claude':  'https://api.anthropic.com',
    'gemini':  'https://generativelanguage.googleapis.com/v1beta/openai',
    'ollama':  'http://localhost:11434',
  };

  void _cacheCurrentConfig() {
    _providerConfigs[_selectedProvider] = {
      'apiKey': _apiKeyController.text,
      'model': _selectedModel,
      'enableWebSearch': _enableWebSearch,
      'enableDeepThink': _enableDeepThink,
    };
  }

  void _loadProviderConfig(String provider) {
    var cfg = _providerConfigs[provider];
    if (cfg == null) {
      final box = Hive.box('settings');
      final saved = box.get('llm_config_$provider');
      if (saved != null && saved is Map) {
        cfg = Map<String, dynamic>.from(saved);
        _providerConfigs[provider] = cfg;
      }
    }
    final models = _presetModels[provider] ?? [];
    final defaultModel = models.isNotEmpty ? models.first[0] : '';

    if (cfg != null) {
      _apiKeyController.text = cfg['apiKey'] as String? ?? '';
      final savedModel = cfg['model'] as String? ?? '';
      // 如果保存的 model 不在预设列表里，也允许保留（自定义模型兼容）
      _selectedModel = savedModel.isNotEmpty ? savedModel : defaultModel;
      _enableWebSearch = cfg['enableWebSearch'] as bool? ?? false;
      _enableDeepThink = cfg['enableDeepThink'] as bool? ?? false;
    } else {
      _apiKeyController.clear();
      _selectedModel = defaultModel;
      _enableWebSearch = false;
      _enableDeepThink = false;
    }

    // 不支持的功能自动关闭
    if (!_supportsWebSearch(provider)) _enableWebSearch = false;
    if (!_supportsDeepThink(provider)) _enableDeepThink = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_configLoaded) {
      _configLoaded = true;
      final llmManager = context.read<LLMManager>();
      final config = llmManager.currentConfig;
      _selectedProvider = config.provider;
      _apiKeyController.text = config.apiKey;
      _selectedModel = config.model;
      _enableWebSearch = config.enableWebSearch;
      _enableDeepThink = config.enableDeepThink;
      _providerConfigs[_selectedProvider] = {
        'apiKey': config.apiKey,
        'model': config.model,
        'enableWebSearch': config.enableWebSearch,
        'enableDeepThink': config.enableDeepThink,
      };
      // 多模态配置
      _visionModel = config.visionModel ?? '';
      final savedLevel = StorageManager.getSetting<String>('prompt_level', defaultValue: 'full');
      _promptLevel = PromptLevelExtension.fromString(savedLevel ?? 'full') ?? PromptLevel.full;
    }
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final models = _presetModels[_selectedProvider] ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 品牌选择 ──
          const Text('选择 AI 品牌', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _brands.entries.map((e) {
              final isSelected = _selectedProvider == e.key;
              return GestureDetector(
                onTap: () {
                  if (_selectedProvider != e.key) {
                    _cacheCurrentConfig();
                    setState(() => _selectedProvider = e.key);
                    _loadProviderConfig(e.key);
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF4FC3F7).withOpacity(0.12) : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isSelected ? const Color(0xFF4FC3F7) : Colors.grey.shade200,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(e.value['icon']!, style: const TextStyle(fontSize: 16)),
                      const SizedBox(width: 5),
                      Text(
                        e.value['name']!,
                        style: TextStyle(
                          fontSize: 12,
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

          // ── API Key（Ollama 不需要）──
          if (_selectedProvider != 'ollama') ...[
            _SettingField(
              label: 'API Key',
              hint: _brands[_selectedProvider]?['hint'] ?? '',
              controller: _apiKeyController,
              isPassword: true,
            ),
            const SizedBox(height: 14),
          ],

          // ── 模型选择 ──
          const Text('选择模型', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),

          // 文本模型
          Row(
            children: [
              SizedBox(
                width: 70,
                child: Text('文本模型', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ),
              Expanded(
                child: _buildModelDropdown(
                  models: models,
                  value: _selectedModel,
                  onChanged: (v) {
                    if (v != null) setState(() => _selectedModel = v);
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // 多模态模型（品牌跟随文本模型）
          Row(
            children: [
              SizedBox(
                width: 70,
                child: Text('视觉模型', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ),
              Expanded(
                child: Builder(builder: (context) {
                  final vModels = _visionPresetModels[_selectedProvider] ?? [];
                  if (vModels.isEmpty) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFE0E0E0)),
                        borderRadius: BorderRadius.circular(10),
                        color: Colors.grey.shade50,
                      ),
                      child: Text(
                        '当前品牌暂不支持视觉模型',
                        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                      ),
                    );
                  }
                  // 切换品牌时重置视觉模型选择
                  final currentModel = vModels.any((m) => m[0] == _visionModel)
                      ? _visionModel
                      : vModels.first[0];
                  if (currentModel != _visionModel) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) setState(() => _visionModel = currentModel);
                    });
                  }
                  return _buildModelDropdown(
                    models: vModels,
                    value: currentModel,
                    onChanged: (v) {
                      if (v != null) setState(() => _visionModel = v);
                    },
                  );
                }),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 74),
            child: Text(
              '用于截图分析，复用当前品牌的 API Key',
              style: TextStyle(fontSize: 10, color: Colors.grey[400]),
            ),
          ),

          // ── 增强功能（只显示支持的）──
          if (_supportsWebSearch(_selectedProvider) || _supportsDeepThink(_selectedProvider)) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('增强功能', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[700])),
                  const SizedBox(height: 6),
                  if (_supportsWebSearch(_selectedProvider))
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('联网搜索', style: TextStyle(fontSize: 13)),
                      subtitle: Text(_webSearchSubtitle(_selectedProvider),
                          style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                      value: _enableWebSearch,
                      activeThumbColor: const Color(0xFF4FC3F7),
                      onChanged: (v) => setState(() => _enableWebSearch = v),
                    ),
                  if (_supportsDeepThink(_selectedProvider))
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('深度思考', style: TextStyle(fontSize: 13)),
                      subtitle: Text(_deepThinkSubtitle(_selectedProvider),
                          style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                      value: _enableDeepThink,
                      activeThumbColor: const Color(0xFF4FC3F7),
                      onChanged: (v) => setState(() => _enableDeepThink = v),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── 上下文模式 ──
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('上下文模式', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey[700])),
                const SizedBox(height: 4),
                Text('System Prompt 详细程度', style: TextStyle(fontSize: 11, color: Colors.grey[500])),
                const SizedBox(height: 10),
                ...[PromptLevel.minimal, PromptLevel.standard, PromptLevel.full].map((level) {
                  final isSelected = _promptLevel == level;
                  return GestureDetector(
                    onTap: () => setState(() => _promptLevel = level),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: isSelected ? const Color(0xFF4FC3F7).withOpacity(0.1) : Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected ? const Color(0xFF4FC3F7) : Colors.grey.shade300,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                            color: isSelected ? const Color(0xFF4FC3F7) : Colors.grey,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getPromptLevelDisplayName(level),
                                  style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal),
                                ),
                                Text(
                                  _getPromptLevelDescription(level),
                                  style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── 保存按钮 ──
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

  String _getPromptLevelDisplayName(PromptLevel level) {
    switch (level) {
      case PromptLevel.minimal: return '简洁模式 (~500 tokens)';
      case PromptLevel.standard: return '标准模式 (~2000 tokens)';
      case PromptLevel.full: return '完整模式 (~4000 tokens) ⭐推荐';
    }
  }

  String _getPromptLevelDescription(PromptLevel level) {
    switch (level) {
      case PromptLevel.minimal: return '简单聊天，节省 token，响应更快';
      case PromptLevel.standard: return '日常对话，包含基础工具说明';
      case PromptLevel.full: return '完整人格设定和工具说明，最佳体验';
    }
  }

  // ── 联网搜索支持 ──
  bool _supportsWebSearch(String provider) =>
      const {'qwen', 'hunyuan', 'chatglm', 'openai', 'claude'}.contains(provider);

  String _webSearchSubtitle(String provider) {
    const map = {
      'qwen':    '阿里云内置联网搜索',
      'hunyuan': '腾讯混元内置联网搜索',
      'chatglm': '智谱 GLM 内置联网搜索',
      'openai':  'OpenAI web_search_preview',
      'claude':  'Anthropic 内置联网搜索',
    };
    return map[provider] ?? '';
  }

  // ── 深度思考支持 ──
  bool _supportsDeepThink(String provider) =>
      const {'qwen', 'chatglm', 'openai', 'claude'}.contains(provider);

  String _deepThinkSubtitle(String provider) {
    const map = {
      'qwen':    '启用推理增强（与工具调用互斥）',
      'chatglm': '仅 GLM-5 系列支持',
      'openai':  'o1/o3/o4 系列推理模型',
      'claude':  'claude-3-7 系列 extended thinking',
    };
    return map[provider] ?? '';
  }

  /// 统一的下拉框样式组件
  Widget _buildModelDropdown({
    required List<List<String>> models,
    required String value,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE0E0E0)),
        borderRadius: BorderRadius.circular(10),
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: models.any((m) => m[0] == value) ? value : (models.isNotEmpty ? models.first[0] : null),
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down, size: 20, color: Color(0xFF9E9E9E)),
          style: const TextStyle(fontSize: 13, color: Colors.black87),
          dropdownColor: Colors.white,
          elevation: 8,
          borderRadius: BorderRadius.circular(10),
          menuMaxHeight: 280,
          items: models.map((m) => DropdownMenuItem(
            value: m[0],
            child: Text(
              m[1],
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
          )).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  void _saveSettings() {
    final llmManager = context.read<LLMManager>();
    final model = _selectedModel.isNotEmpty
        ? _selectedModel
        : (_presetModels[_selectedProvider]?.first[0] ?? '');
    final endpoint = _defaultEndpoints[_selectedProvider] ?? '';

    // 多模态配置
    final visionModels = _visionPresetModels[_selectedProvider] ?? [];
    final savedVisionModel = _visionModel.isNotEmpty && visionModels.any((m) => m[0] == _visionModel)
        ? _visionModel
        : (visionModels.isNotEmpty ? visionModels.first[0] : '');

    final config = LLMConfig(
      provider: _selectedProvider,
      apiKey: _apiKeyController.text.trim(),
      model: model,
      baseUrl: endpoint,
      enableWebSearch: _enableWebSearch,
      enableDeepThink: _enableDeepThink,
      visionProvider: _selectedProvider,
      visionModel: savedVisionModel,
    );
    llmManager.setConfig(config);

    final box = Hive.box('settings');
    box.put('llm_config_$_selectedProvider', config.toJson());
    StorageManager.setSetting('prompt_level', _promptLevel.name);

    // 缓存当前配置
    _providerConfigs[_selectedProvider] = {
      'apiKey': _apiKeyController.text,
      'model': model,
      'enableWebSearch': _enableWebSearch,
      'enableDeepThink': _enableDeepThink,
    };

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
            title: '主动搭话',
            subtitle: '瞎养会主动找你聊天、撒娇、关心你',
            value: engine.notificationEnabled,
            onChanged: (v) {
              engine.setNotificationEnabled(v);
            },
          ),
          if (engine.notificationEnabled)
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 16, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '搭话频率',
                        style: TextStyle(fontSize: 13, color: Colors.black54),
                      ),
                      const Spacer(),
                      Text(
                        '${engine.proactiveChatInterval}分钟',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  Slider(
                    value: engine.proactiveChatInterval.toDouble(),
                    min: 3,
                    max: 60,
                    divisions: 19,
                    label: '${engine.proactiveChatInterval}分钟',
                    onChanged: (v) => engine.setProactiveChatInterval(v.round()),
                  ),
                ],
              ),
            ),
          _SettingToggle(
            title: '健康提醒',
            subtitle: '定时提醒喝水、休息、活动',
            value: engine.healthReminderEnabled,
            onChanged: (v) {
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

// ════════════════════════════════════════════════════════
// Agent 配置设置面板（模块 8 的 UI 层）
// ════════════════════════════════════════════════════════

class _AgentSettings extends StatefulWidget {
  final void Function(String)? onShowBubble;
  const _AgentSettings({this.onShowBubble});

  @override
  State<_AgentSettings> createState() => _AgentSettingsState();
}

class _AgentSettingsState extends State<_AgentSettings> {
  final _config = AgentConfig();

  // ── 模块开关状态 ──
  bool _enableGuardrails = true;
  bool _enableObservability = true;
  bool _enableRecovery = true;
  bool _enableToolSelector = true;

  @override
  void initState() {
    super.initState();
    _enableGuardrails = _config.enableGuardrails;
    _enableObservability = _config.enableObservability;
    _enableRecovery = _config.enableRecovery;
    _enableToolSelector = _config.enableToolSelector;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ── 循环控制 ──
        _buildSectionTitle('🔄 循环控制', '控制 Agent 执行循环的核心参数'),
        _buildSliderItem(
          label: '最大工具轮数',
          value: _config.maxTurns.toDouble(),
          min: 5,
          max: 100,
          divisions: 19,
          unit: '轮',
          configKey: 'agent.maxTurns',
        ),
        _buildSliderItem(
          label: '重复检测阈值',
          value: _config.maxDuplicateRounds.toDouble(),
          min: 2,
          max: 10,
          divisions: 8,
          unit: '轮',
          configKey: 'loop.maxDuplicateRounds',
        ),
        _buildSliderItem(
          label: '停滞检测阈值',
          value: _config.maxStagnantRounds.toDouble(),
          min: 2,
          max: 10,
          divisions: 8,
          unit: '轮',
          configKey: 'loop.maxStagnantRounds',
        ),
        _buildSliderItem(
          label: '最大连续失败',
          value: _config.maxFailedCalls.toDouble(),
          min: 2,
          max: 15,
          divisions: 13,
          unit: '次',
          configKey: 'loop.maxFailedCalls',
        ),
        const Divider(height: 24),

        // ── 模块开关 ──
        _buildSectionTitle('🧩 优化模块', '启用/禁用各个 AI 优化模块'),
        _buildModuleSwitch(
          icon: '🛡️',
          title: 'Guardrails 防护系统',
          subtitle: '4 层防护：输入验证 / 命令安全 / 输出脱敏 / 成本控制',
          value: _enableGuardrails,
          onChanged: (v) {
            setState(() => _enableGuardrails = v);
            _config.setOverride('guardrails.enabled', v);
            widget.onShowBubble?.call(v ? '已启用 Guardrails 防护' : '已关闭 Guardrails 防护');
          },
        ),
        _buildModuleSwitch(
          icon: '📊',
          title: 'Observability 可观测性',
          subtitle: 'Trace 链路追踪 + Metrics 指标收集 + 性能分析',
          value: _enableObservability,
          onChanged: (v) {
            setState(() => _enableObservability = v);
            _config.setOverride('observability.enabled', v);
            widget.onShowBubble?.call(v ? '已启用可观测性追踪' : '已关闭可观测性追踪');
          },
        ),
        _buildModuleSwitch(
          icon: '🔄',
          title: 'Recovery 错误恢复',
          subtitle: '状态快照 / 自动回滚 / 降级策略（重试→缩范围→简化→备选）',
          value: _enableRecovery,
          onChanged: (v) {
            setState(() => _enableRecovery = v);
            _config.setOverride('recovery.enabled', v);
            widget.onShowBubble?.call(v ? '已启用错误恢复' : '已关闭错误恢复');
          },
        ),
        _buildModuleSwitch(
          icon: '🎯',
          title: 'ToolSelector 智能工具选择',
          subtitle: '基于任务类型 + 历史成功率 + 延迟的加权评分排序',
          value: _enableToolSelector,
          onChanged: (v) {
            setState(() => _enableToolSelector = v);
            _config.setOverride('toolSelector.enabled', v);
            widget.onShowBubble?.call(v ? '已启用智能工具选择' : '已关闭智能工具选择');
          },
        ),
        const Divider(height: 24),

        // ── Guardrails 详细配置 ──
        if (_enableGuardrails) ...[
          _buildSectionTitle('🛡️ Guardrails 配置', '成本预算与安全限制'),
          _buildSliderItem(
            label: '单会话 Token 上限',
            value: _config.maxTokensPerSession.toDouble(),
            min: 10000,
            max: 500000,
            divisions: 49,
            unit: '',
            configKey: 'agent.maxTokensPerSession',
            displayTransform: (v) => '${(v / 1000).round()}K',
          ),
          _buildSliderItem(
            label: '工具调用预算',
            value: _config.maxToolCallBudget.toDouble(),
            min: 10,
            max: 200,
            divisions: 19,
            unit: '次',
            configKey: 'guardrails.maxToolCallBudget',
          ),
          _buildSliderItem(
            label: '时间预算',
            value: _config.maxTimeBudgetMinutes.toDouble(),
            min: 1,
            max: 30,
            divisions: 29,
            unit: '分钟',
            configKey: 'guardrails.maxTimeBudgetMinutes',
          ),
          const Divider(height: 24),
        ],

        // ── Recovery 详细配置 ──
        if (_enableRecovery) ...[
          _buildSectionTitle('🔄 Recovery 配置', '快照与重试策略'),
          _buildSliderItem(
            label: '最大快照数',
            value: _config.maxSnapshots.toDouble(),
            min: 3,
            max: 20,
            divisions: 17,
            unit: '个',
            configKey: 'recovery.maxSnapshots',
          ),
          _buildSliderItem(
            label: '最大重试次数',
            value: _config.retryMaxAttempts.toDouble(),
            min: 1,
            max: 10,
            divisions: 9,
            unit: '次',
            configKey: 'recovery.retryMaxAttempts',
          ),
          const Divider(height: 24),
        ],

        // ── 快捷操作 ──
        _buildSectionTitle('⚡ 快捷操作', '重置配置或导出诊断信息'),
        Row(
          children: [
            _buildActionButton(
              icon: Icons.restart_alt,
              label: '恢复默认',
              color: Colors.orange,
              onTap: () {
                _config.reset();
                setState(() {
                  _enableGuardrails = true;
                  _enableObservability = true;
                  _enableRecovery = true;
                  _enableToolSelector = true;
                });
                widget.onShowBubble?.call('已恢复所有 Agent 配置为默认值');
              },
            ),
            const SizedBox(width: 8),
            _buildActionButton(
              icon: Icons.content_copy,
              label: '导出配置',
              color: const Color(0xFF4FC3F7),
              onTap: () {
                final config = _config.exportAll();
                final configStr = config.entries
                    .map((e) => '${e.key}: ${e.value}')
                    .join('\n');
                Clipboard.setData(ClipboardData(text: configStr));
                widget.onShowBubble?.call('配置已复制到剪贴板');
              },
            ),
          ],
        ),
        const SizedBox(height: 16),

        // ── 当前配置概览 ──
        _buildConfigOverview(),
      ],
    );
  }

  Widget _buildSectionTitle(String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _buildSliderItem({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String unit,
    required String configKey,
    String Function(double)? displayTransform,
  }) {
    final displayValue = displayTransform != null
        ? displayTransform(value)
        : '${value.round()}$unit';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 13)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF4FC3F7).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  displayValue,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF4FC3F7),
                  ),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: const Color(0xFF4FC3F7),
              thumbColor: const Color(0xFF4FC3F7),
              overlayColor: const Color(0xFF4FC3F7).withOpacity(0.1),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (v) {
                setState(() {
                  _config.setOverride(configKey, v.round());
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModuleSwitch({
    required String icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: value ? const Color(0xFFE3F2FD).withOpacity(0.5) : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: value
            ? Border.all(color: const Color(0xFF4FC3F7).withOpacity(0.3))
            : Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600), maxLines: 2),
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

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigOverview() {
    final overrides = _config.exportAll();
    if (overrides.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Text('所有配置均为默认值', style: TextStyle(fontSize: 12, color: Colors.grey)),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('📋 当前覆盖配置', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              const Spacer(),
              Text('${overrides.length} 项', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ],
          ),
          const SizedBox(height: 8),
          ...overrides.entries.take(10).map((e) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    e.key,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade700, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${e.value}',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF4FC3F7)),
                ),
              ],
            ),
          )),
          if (overrides.length > 10)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '... 还有 ${overrides.length - 10} 项',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ),
        ],
      ),
    );
  }
}
