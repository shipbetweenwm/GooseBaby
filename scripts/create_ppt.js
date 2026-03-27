const PptxGenJS = require('pptxgenjs');

// 创建演示文稿
const pptx = new PptxGenJS();

// 配色方案 - Berry & Cream (温暖可爱风格)
const colors = {
  primary: '6D2E46',      // Berry - 主色调
  secondary: 'A26769',    // Dusty rose - 辅助色
  accent: 'ECE2D0',       // Cream - 背景色
  white: 'FFFFFF',
  dark: '2F3C7E',         // 深蓝色用于文字
  lightPink: 'F5E6E8',    // 浅粉色
};

// 设置幻灯片尺寸
pptx.defineLayout({ name: 'CUSTOM', width: 13.33, height: 7.5 });
pptx.layout = 'CUSTOM';

// ============================================
// 第1页: 封面
// ============================================
let slide1 = pptx.addSlide();

// 背景渐变
slide1.background = { color: colors.primary };

// 主标题
slide1.addText('🦢 鹅宝 GooseBaby', {
  x: 0.5, y: 1.5, w: 12.33, h: 1.5,
  fontSize: 60, fontFace: 'Arial', bold: true,
  color: colors.white, align: 'center',
});

// 标语
slide1.addText('"不只是宠物，是会记住你每一句话的陪伴"', {
  x: 1, y: 3.2, w: 11.33, h: 0.8,
  fontSize: 28, fontFace: 'Arial', italic: true,
  color: colors.accent, align: 'center',
});

// 副标题
slide1.addText('AI 驱动的桌面智能宠物伙伴', {
  x: 1, y: 4.2, w: 11.33, h: 0.6,
  fontSize: 22, fontFace: 'Arial',
  color: colors.lightPink, align: 'center',
});

// 底部装饰条
slide1.addShape(pptx.ShapeType.rect, {
  x: 3, y: 6.2, w: 7.33, h: 0.05,
  fill: { color: colors.accent },
});

// 版本信息
slide1.addText('v1.0.0 | Windows 桌面应用', {
  x: 0.5, y: 6.5, w: 12.33, h: 0.5,
  fontSize: 14, fontFace: 'Arial',
  color: colors.secondary, align: 'center',
});

// ============================================
// 第2页: 为什么是鹅宝
// ============================================
let slide2 = pptx.addSlide();
slide2.background = { color: colors.accent };

// 标题
slide2.addText('💕 为什么是鹅宝？', {
  x: 0.5, y: 0.4, w: 12.33, h: 0.9,
  fontSize: 36, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

// 痛点描述
const painPoints = [
  { icon: '🌙', text: '加班到深夜，只有屏幕的光陪着你' },
  { icon: '💭', text: '心里话想找人倾诉，又怕打扰朋友' },
  { icon: '📅', text: '生活里的小确幸，不知道该分享给谁' },
];

painPoints.forEach((item, i) => {
  slide2.addText(`${item.icon}  ${item.text}`, {
    x: 0.8, y: 1.5 + i * 0.7, w: 11.5, h: 0.6,
    fontSize: 20, fontFace: 'Arial',
    color: colors.dark, align: 'left',
  });
});

// 对比表格
slide2.addText('普通 AI', {
  x: 2, y: 4, w: 4, h: 0.5,
  fontSize: 18, fontFace: 'Arial', bold: true,
  color: colors.secondary, align: 'center',
});
slide2.addText('鹅宝', {
  x: 7, y: 4, w: 4, h: 0.5,
  fontSize: 18, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'center',
});

const comparisons = [
  ['聊完就忘', '📝 记住你说过的每一件事'],
  ['只会回答问题', '💭 懂你的情绪，会撒娇会关心'],
  ['需要你主动找它', '🕐 主动提醒你喝水、休息'],
  ['只能聊天', '🤖 还能帮你干活（智能体技能）'],
];

comparisons.forEach((row, i) => {
  slide2.addText(row[0], {
    x: 2, y: 4.6 + i * 0.6, w: 4, h: 0.5,
    fontSize: 16, fontFace: 'Arial',
    color: colors.secondary, align: 'center',
  });
  slide2.addText(row[1], {
    x: 7, y: 4.6 + i * 0.6, w: 4, h: 0.5,
    fontSize: 16, fontFace: 'Arial', bold: true,
    color: colors.primary, align: 'center',
  });
});

// ============================================
// 第3页: 核心功能 - 表情动画
// ============================================
let slide3 = pptx.addSlide();
slide3.background = { color: colors.white };

// 标题
slide3.addText('🎀 萌到犯规的 11 种表情', {
  x: 0.5, y: 0.3, w: 12.33, h: 0.8,
  fontSize: 36, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

slide3.addText('每一帧都在治愈你的心 💗', {
  x: 0.5, y: 1, w: 12.33, h: 0.5,
  fontSize: 18, fontFace: 'Arial', italic: true,
  color: colors.secondary, align: 'left',
});

// 表情网格
const expressions = [
  ['🥺 装萌', '歪头杀 100%'],
  ['😴 睡觉', '睡着的小泡泡'],
  ['💼 工作', '陪你一起打工'],
  ['🎾 玩玩具', '自娱自乐第一名'],
  ['💕 被撸了', '被摸摸超开心'],
  ['🥳 开心', '高兴到原地起飞'],
  ['🍖 吃零食', '干饭鹅干饭魂'],
  ['🛁 洗澡', '爱干净的好宝宝'],
  ['😢 哭了', '委屈巴巴惹人怜'],
  ['😪 困了', '打哈欠想睡觉'],
  ['🤔 发呆', '发呆的时候最萌'],
];

expressions.forEach((item, i) => {
  const col = i % 4;
  const row = Math.floor(i / 4);
  const x = 0.8 + col * 3.1;
  const y = 1.8 + row * 1.5;

  // 卡片背景
  slide3.addShape(pptx.ShapeType.roundRect, {
    x: x, y: y, w: 2.8, h: 1.2,
    fill: { color: colors.accent },
    line: { color: colors.secondary, width: 0.5 },
  });

  // 表情名称
  slide3.addText(item[0], {
    x: x, y: y + 0.2, w: 2.8, h: 0.5,
    fontSize: 16, fontFace: 'Arial', bold: true,
    color: colors.primary, align: 'center',
  });

  // 描述
  slide3.addText(item[1], {
    x: x, y: y + 0.65, w: 2.8, h: 0.4,
    fontSize: 12, fontFace: 'Arial',
    color: colors.secondary, align: 'center',
  });
});

// 小彩蛋提示
slide3.addText('💡 小彩蛋：双击它试试~ 每次反应都不一样！', {
  x: 0.5, y: 6.8, w: 12.33, h: 0.4,
  fontSize: 14, fontFace: 'Arial', italic: true,
  color: colors.dark, align: 'center',
});

// ============================================
// 第4页: 长期记忆
// ============================================
let slide4 = pptx.addSlide();
slide4.background = { color: colors.accent };

// 标题
slide4.addText('🧠 它是真的记得你', {
  x: 0.5, y: 0.3, w: 12.33, h: 0.8,
  fontSize: 36, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

slide4.addText('长期记忆 · 陪伴感拉满 ✨', {
  x: 0.5, y: 1, w: 12.33, h: 0.5,
  fontSize: 20, fontFace: 'Arial',
  color: colors.secondary, align: 'left',
});

// 对话示例框
slide4.addShape(pptx.ShapeType.roundRect, {
  x: 0.8, y: 1.7, w: 11.5, h: 2.2,
  fill: { color: colors.white },
  line: { color: colors.primary, width: 1 },
});

slide4.addText('你："我今天升职了！！"', {
  x: 1, y: 1.9, w: 11, h: 0.5,
  fontSize: 16, fontFace: 'Arial', bold: true,
  color: colors.dark, align: 'left',
});

slide4.addText('鹅宝："哇！！恭喜你呀！！🦆✨\n我记得你之前说为这个项目加班了好久，\n现在终于熬出头了！今晚必须好好犒劳自己！"', {
  x: 1, y: 2.5, w: 11, h: 1.2,
  fontSize: 15, fontFace: 'Arial',
  color: colors.primary, align: 'left',
});

// 功能列表
const memoryFeatures = [
  { icon: '📝', title: '记住重要事件', desc: '生日、纪念日、工作项目...' },
  { icon: '💬', title: '理解上下文', desc: '不用每次重新解释' },
  { icon: '🎯', title: '越聊越懂你', desc: '知道你的喜好和习惯' },
  { icon: '⏰', title: '主动关心', desc: '"你昨天说今天要面试，加油哦！"' },
];

memoryFeatures.forEach((item, i) => {
  const x = 0.8 + i * 3.1;
  
  slide4.addShape(pptx.ShapeType.roundRect, {
    x: x, y: 4.3, w: 2.8, h: 1.8,
    fill: { color: colors.white },
    line: { color: colors.secondary, width: 0.5 },
  });

  slide4.addText(item.icon, {
    x: x, y: 4.5, w: 2.8, h: 0.5,
    fontSize: 28, align: 'center',
  });

  slide4.addText(item.title, {
    x: x, y: 5.1, w: 2.8, h: 0.4,
    fontSize: 14, fontFace: 'Arial', bold: true,
    color: colors.primary, align: 'center',
  });

  slide4.addText(item.desc, {
    x: x, y: 5.5, w: 2.8, h: 0.5,
    fontSize: 11, fontFace: 'Arial',
    color: colors.secondary, align: 'center',
  });
});

// 用户评价
slide4.addText('🕊️ "养了三个月，它比我闺蜜还了解我的口味"', {
  x: 0.5, y: 6.5, w: 12.33, h: 0.5,
  fontSize: 14, fontFace: 'Arial', italic: true,
  color: colors.dark, align: 'center',
});

// ============================================
// 第5页: 技能系统
// ============================================
let slide5 = pptx.addSlide();
slide5.background = { color: colors.white };

// 标题
slide5.addText('🤖 不只是宠物，还能帮你干活', {
  x: 0.5, y: 0.3, w: 12.33, h: 0.8,
  fontSize: 36, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

slide5.addText('智能体技能系统 🔧', {
  x: 0.5, y: 1, w: 12.33, h: 0.5,
  fontSize: 20, fontFace: 'Arial',
  color: colors.secondary, align: 'left',
});

// 技能列表
const skills = [
  { icon: '📝', name: '文件操作', desc: '创建、读取、编辑文件' },
  { icon: '💻', name: '命令执行', desc: '运行 Shell 命令和脚本' },
  { icon: '🧠', name: '记忆管理', desc: '查询和管理记忆内容' },
  { icon: '⏰', name: '定时任务', desc: '创建和管理定时提醒' },
  { icon: '🔍', name: '网页搜索', desc: '联网搜索实时信息' },
  { icon: '🤔', name: '深度思考', desc: '复杂问题的分析和推理' },
];

skills.forEach((skill, i) => {
  const col = i % 3;
  const row = Math.floor(i / 3);
  const x = 0.8 + col * 4;
  const y = 1.7 + row * 1.6;

  slide5.addShape(pptx.ShapeType.roundRect, {
    x: x, y: y, w: 3.7, h: 1.3,
    fill: { color: colors.accent },
    line: { color: colors.primary, width: 0.5 },
  });

  slide5.addText(`${skill.icon} ${skill.name}`, {
    x: x + 0.2, y: y + 0.2, w: 3.3, h: 0.5,
    fontSize: 16, fontFace: 'Arial', bold: true,
    color: colors.primary, align: 'left',
  });

  slide5.addText(skill.desc, {
    x: x + 0.2, y: y + 0.7, w: 3.3, h: 0.4,
    fontSize: 13, fontFace: 'Arial',
    color: colors.secondary, align: 'left',
  });
});

// 自定义技能
slide5.addShape(pptx.ShapeType.roundRect, {
  x: 0.8, y: 5.2, w: 11.5, h: 1.5,
  fill: { color: colors.primary },
});

slide5.addText('📦 自定义智能体技能包', {
  x: 1, y: 5.4, w: 5, h: 0.5,
  fontSize: 18, fontFace: 'Arial', bold: true,
  color: colors.white, align: 'left',
});

slide5.addText('支持 Claude Code 格式的技能包\nmy-skill/  ├── SKILL.md  # 技能说明书\n          ├── scripts/  # 可执行脚本\n          └── references/  # 参考文档', {
  x: 1, y: 5.9, w: 11, h: 0.8,
  fontSize: 12, fontFace: 'Consolas',
  color: colors.accent, align: 'left',
});

// ============================================
// 第6页: 养成系统
// ============================================
let slide6 = pptx.addSlide();
slide6.background = { color: colors.accent };

// 标题
slide6.addText('🎮 养成系快乐', {
  x: 0.5, y: 0.3, w: 12.33, h: 0.8,
  fontSize: 36, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

// 三个模块
const modules = [
  {
    title: '📊 属性管理',
    items: ['🍖 饥饿度', '😊 心情值', '🧼 清洁度', '⚡ 精力值'],
    x: 0.5,
  },
  {
    title: '💰 金币系统',
    items: ['⏰ 在线陪伴 1 金币/分钟', '💬 聊天互动 5-15 金币/次', '🛒 商店兑换物品和装扮'],
    x: 4.5,
  },
  {
    title: '🏆 成就收集',
    items: ['✓ 第一次对话', '✓ 陪伴满 30 天', '✓ 解锁全部动画'],
    x: 8.5,
  },
];

modules.forEach((mod) => {
  slide6.addShape(pptx.ShapeType.roundRect, {
    x: mod.x, y: 1.3, w: 4, h: 3.5,
    fill: { color: colors.white },
    line: { color: colors.primary, width: 1 },
  });

  slide6.addText(mod.title, {
    x: mod.x + 0.2, y: 1.5, w: 3.6, h: 0.5,
    fontSize: 18, fontFace: 'Arial', bold: true,
    color: colors.primary, align: 'center',
  });

  mod.items.forEach((item, i) => {
    slide6.addText(item, {
      x: mod.x + 0.3, y: 2.2 + i * 0.7, w: 3.4, h: 0.5,
      fontSize: 14, fontFace: 'Arial',
      color: colors.dark, align: 'left',
    });
  });
});

// 日记模块
slide6.addShape(pptx.ShapeType.roundRect, {
  x: 0.5, y: 5.1, w: 12.33, h: 1.5,
  fill: { color: colors.white },
  line: { color: colors.secondary, width: 1 },
});

slide6.addText('📔 宠物日记', {
  x: 0.8, y: 5.3, w: 3, h: 0.5,
  fontSize: 18, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

slide6.addText('鹅宝默默记录你们的每一天：💬 今天聊了多少句  |  🎮 互动了多少次  |  😊 心情怎么样\n回头翻翻，满满都是回忆 📖', {
  x: 0.8, y: 5.8, w: 11.5, h: 0.7,
  fontSize: 14, fontFace: 'Arial',
  color: colors.dark, align: 'left',
});

// ============================================
// 第7页: 智能关怀
// ============================================
let slide7 = pptx.addSlide();
slide7.background = { color: colors.white };

// 标题
slide7.addText('⏰ 智能关怀', {
  x: 0.5, y: 0.3, w: 12.33, h: 0.8,
  fontSize: 36, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

slide7.addText('贴心的健康提醒', {
  x: 0.5, y: 1, w: 12.33, h: 0.5,
  fontSize: 20, fontFace: 'Arial',
  color: colors.secondary, align: 'left',
});

// 关怀卡片
const cares = [
  { icon: '💧', title: '喝水提醒', msg: '"该喝水啦~ 已经坐了2小时了"', color: '87CEEB' },
  { icon: '🚶', title: '活动提醒', msg: '"起来活动一下吧"', color: '90EE90' },
  { icon: '🌙', title: '休息提醒', msg: '"很晚了哦，早点休息"', color: 'DDA0DD' },
  { icon: '🎂', title: '节日祝福', msg: '"今天是你的生日！生日快乐！"', color: 'FFD700' },
];

cares.forEach((care, i) => {
  const x = 0.8 + i * 3.1;

  slide7.addShape(pptx.ShapeType.roundRect, {
    x: x, y: 1.7, w: 2.9, h: 2.5,
    fill: { color: care.color },
    line: { color: colors.primary, width: 0.5 },
  });

  slide7.addText(care.icon, {
    x: x, y: 1.9, w: 2.9, h: 0.7,
    fontSize: 36, align: 'center',
  });

  slide7.addText(care.title, {
    x: x, y: 2.6, w: 2.9, h: 0.4,
    fontSize: 16, fontFace: 'Arial', bold: true,
    color: colors.dark, align: 'center',
  });

  slide7.addText(care.msg, {
    x: x + 0.1, y: 3.1, w: 2.7, h: 0.8,
    fontSize: 12, fontFace: 'Arial', italic: true,
    color: colors.dark, align: 'center',
  });
});

// 主动关怀说明
slide7.addShape(pptx.ShapeType.roundRect, {
  x: 0.8, y: 4.5, w: 11.5, h: 2,
  fill: { color: colors.accent },
  line: { color: colors.primary, width: 1 },
});

slide7.addText('💡 智能主动关怀', {
  x: 1, y: 4.7, w: 11, h: 0.5,
  fontSize: 18, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

const smartCares = [
  '• 检测到用户连续打字 2 小时 → 提醒休息',
  '• 检测到晚上 11 点还在工作 → 提醒早睡',
  '• 检测到用户心情低落 → 主动安慰',
  '• 根据天气变化 → 提醒带伞/添衣',
];

smartCares.forEach((item, i) => {
  slide7.addText(item, {
    x: 1, y: 5.3 + i * 0.35, w: 11, h: 0.35,
    fontSize: 13, fontFace: 'Arial',
    color: colors.dark, align: 'left',
  });
});

// ============================================
// 第8页: 技术架构
// ============================================
let slide8 = pptx.addSlide();
slide8.background = { color: colors.accent };

// 标题
slide8.addText('🏗️ 技术架构', {
  x: 0.5, y: 0.3, w: 12.33, h: 0.8,
  fontSize: 36, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

// 前端技术
slide8.addShape(pptx.ShapeType.roundRect, {
  x: 0.5, y: 1.2, w: 4, h: 2.8,
  fill: { color: colors.white },
  line: { color: colors.primary, width: 1 },
});

slide8.addText('前端技术', {
  x: 0.5, y: 1.4, w: 4, h: 0.5,
  fontSize: 18, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'center',
});

const frontendTech = ['Flutter 3.16+', 'Provider 状态管理', 'Hive 本地存储', 'media_kit 视频播放', 'window_manager'];
frontendTech.forEach((tech, i) => {
  slide8.addText(`• ${tech}`, {
    x: 0.7, y: 2 + i * 0.45, w: 3.5, h: 0.4,
    fontSize: 14, fontFace: 'Arial',
    color: colors.dark, align: 'left',
  });
});

// AI 集成
slide8.addShape(pptx.ShapeType.roundRect, {
  x: 4.7, y: 1.2, w: 4, h: 2.8,
  fill: { color: colors.white },
  line: { color: colors.secondary, width: 1 },
});

slide8.addText('AI 集成', {
  x: 4.7, y: 1.4, w: 4, h: 0.5,
  fontSize: 18, fontFace: 'Arial', bold: true,
  color: colors.secondary, align: 'center',
});

const aiTech = ['OpenAI 兼容 API', 'Function Calling', '多轮对话上下文', 'Token 预算控制', '深度思考模式'];
aiTech.forEach((tech, i) => {
  slide8.addText(`• ${tech}`, {
    x: 4.9, y: 2 + i * 0.45, w: 3.5, h: 0.4,
    fontSize: 14, fontFace: 'Arial',
    color: colors.dark, align: 'left',
  });
});

// 技能系统
slide8.addShape(pptx.ShapeType.roundRect, {
  x: 8.9, y: 1.2, w: 4, h: 2.8,
  fill: { color: colors.white },
  line: { color: colors.primary, width: 1 },
});

slide8.addText('技能系统', {
  x: 8.9, y: 1.4, w: 4, h: 0.5,
  fontSize: 18, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'center',
});

const skillTech = ['标准化技能接口', 'ZIP 包导入', 'Python/Shell 脚本', '安全沙箱执行', 'SKILL.md 解析'];
skillTech.forEach((tech, i) => {
  slide8.addText(`• ${tech}`, {
    x: 9.1, y: 2 + i * 0.45, w: 3.5, h: 0.4,
    fontSize: 14, fontFace: 'Arial',
    color: colors.dark, align: 'left',
  });
});

// 支持的模型
slide8.addShape(pptx.ShapeType.roundRect, {
  x: 0.5, y: 4.3, w: 12.33, h: 1.3,
  fill: { color: colors.white },
  line: { color: colors.secondary, width: 1 },
});

slide8.addText('支持的 AI 模型', {
  x: 0.7, y: 4.5, w: 3, h: 0.4,
  fontSize: 16, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

slide8.addText('通义千问 (阿里云)  |  腾讯混元  |  DeepSeek  |  OpenAI  |  其他兼容 API', {
  x: 0.7, y: 5, w: 11.5, h: 0.4,
  fontSize: 14, fontFace: 'Arial',
  color: colors.dark, align: 'left',
});

// ============================================
// 第9页: 未来规划
// ============================================
let slide9 = pptx.addSlide();
slide9.background = { color: colors.white };

// 标题
slide9.addText('🗺️ 未来规划', {
  x: 0.5, y: 0.3, w: 12.33, h: 0.8,
  fontSize: 36, fontFace: 'Arial', bold: true,
  color: colors.primary, align: 'left',
});

// 规划项目
const roadmap = [
  { icon: '🍎', title: 'macOS / Linux 支持', status: '计划中' },
  { icon: '👗', title: '更多宠物形象和装扮', status: '计划中' },
  { icon: '🎤', title: '语音对话能力', status: '计划中' },
  { icon: '🦆', title: '多宠物互动', status: '计划中' },
  { icon: '☁️', title: '云端同步', status: '计划中' },
  { icon: '🏪', title: '社区技能市场', status: '计划中' },
];

roadmap.forEach((item, i) => {
  const col = i % 3;
  const row = Math.floor(i / 3);
  const x = 0.8 + col * 4.1;
  const y = 1.3 + row * 1.8;

  slide9.addShape(pptx.ShapeType.roundRect, {
    x: x, y: y, w: 3.9, h: 1.5,
    fill: { color: colors.accent },
    line: { color: colors.primary, width: 0.5 },
  });

  slide9.addText(item.icon, {
    x: x, y: y + 0.2, w: 1, h: 0.6,
    fontSize: 32, align: 'center',
  });

  slide9.addText(item.title, {
    x: x + 1, y: y + 0.3, w: 2.7, h: 0.5,
    fontSize: 16, fontFace: 'Arial', bold: true,
    color: colors.primary, align: 'left',
  });

  slide9.addText(item.status, {
    x: x + 1, y: y + 0.8, w: 2.7, h: 0.4,
    fontSize: 12, fontFace: 'Arial',
    color: colors.secondary, align: 'left',
  });
});

// 社区参与
slide9.addShape(pptx.ShapeType.roundRect, {
  x: 0.8, y: 5, w: 11.5, h: 1.5,
  fill: { color: colors.primary },
});

slide9.addText('🤝 一起让鹅宝更好', {
  x: 1, y: 5.2, w: 11, h: 0.5,
  fontSize: 20, fontFace: 'Arial', bold: true,
  color: colors.white, align: 'center',
});

slide9.addText('🐛 报告问题  |  💡 提建议  |  🔧 贡献代码  |  ⭐ 给个 Star', {
  x: 1, y: 5.8, w: 11, h: 0.5,
  fontSize: 16, fontFace: 'Arial',
  color: colors.accent, align: 'center',
});

// ============================================
// 第10页: 结尾
// ============================================
let slide10 = pptx.addSlide();
slide10.background = { color: colors.primary };

// 主标题
slide10.addText('🦢 鹅宝 GooseBaby', {
  x: 0.5, y: 1.8, w: 12.33, h: 1,
  fontSize: 48, fontFace: 'Arial', bold: true,
  color: colors.white, align: 'center',
});

// 标语
slide10.addText('每一个需要陪伴的灵魂，都值得被温柔以待', {
  x: 1, y: 3, w: 11.33, h: 0.6,
  fontSize: 24, fontFace: 'Arial', italic: true,
  color: colors.accent, align: 'center',
});

// 副标语
slide10.addText('愿鹅宝成为你生活里的一束小光 ✨', {
  x: 1, y: 3.8, w: 11.33, h: 0.5,
  fontSize: 18, fontFace: 'Arial',
  color: colors.secondary, align: 'center',
});

// 装饰条
slide10.addShape(pptx.ShapeType.rect, {
  x: 3, y: 4.8, w: 7.33, h: 0.05,
  fill: { color: colors.accent },
});

// GitHub
slide10.addText('github.com/shipbetweenwm/GooseBaby', {
  x: 0.5, y: 5.2, w: 12.33, h: 0.4,
  fontSize: 16, fontFace: 'Arial',
  color: colors.lightPink, align: 'center',
});

// 底部
slide10.addText('Made with 💕 by GooseBaby Team', {
  x: 0.5, y: 6.5, w: 12.33, h: 0.4,
  fontSize: 14, fontFace: 'Arial',
  color: colors.secondary, align: 'center',
});

// 标签
slide10.addText('#桌面宠物 #治愈系 #AI陪伴 #长期记忆 #智能体', {
  x: 0.5, y: 6.9, w: 12.33, h: 0.4,
  fontSize: 12, fontFace: 'Arial',
  color: colors.lightPink, align: 'center',
});

// 保存文件
pptx.writeFile({ fileName: '/Users/jiangdianchen/CodeBuddy/GooseBaby/鹅宝_GooseBaby_产品介绍.pptx' })
  .then(fileName => {
    console.log(`✅ PPT 已生成: ${fileName}`);
  })
  .catch(err => {
    console.error('❌ 生成失败:', err);
  });
