import 'dart:math';
import '../skill_base.dart';

/// 讲笑话技能
class JokeSkill extends GooseSkill {
  final _random = Random();

  @override
  String get id => 'joke';

  @override
  String get name => '讲笑话';

  @override
  String get description => '鹅宝给你讲一个笑话或者冷知识，逗你开心';

  @override
  String get icon => '😄';

  @override
  String get category => '趣味娱乐';

  @override
  List<SkillParam> get params => [
    const SkillParam(
      name: 'type',
      description: '笑话类型',
      type: 'enum',
      required: false,
      defaultValue: 'random',
      enumValues: ['joke', 'fun_fact', 'tongue_twister', 'random'],
    ),
  ];

  static const _jokes = [
    '为什么鹅不会飞？因为它们太胖了，但鹅宝是会飞的小白鹅！嘎~',
    '程序员为什么总是分不清万圣节和圣诞节？因为 Oct 31 == Dec 25 🎃🎄',
    '鹅宝问：为什么键盘上的F和J有凸起？答：因为怕盲人看不到啊！...不对，是方便摸到！',
    '世界上最冷的地方是哪里？不是南极，是没开暖气的你的房间！',
    '为什么程序员喜欢暗色主题？因为bug会被吓跑！嘎嘎嘎~',
    '鹅宝的梦想是什么？成为一只有编制的鹅！',
    '什么动物最擅长编程？蟒蛇（Python）！但鹅宝用Dart也很厉害的！',
    '为什么电脑永远不会冷？因为它有很多窗户（Windows）和风扇呀~',
    '人生三大错觉：手机在震动、有人敲门、她喜欢我。鹅宝补充第四个：这个bug很简单！',
    '鹅宝发现了一个bug：你已经好久没喝水了！快去喝水！🥤',
  ];

  static const _funFacts = [
    '你知道吗？鹅是有牙齿的！虽然不是真正的牙齿，但它们的喙边缘有锯齿状结构。嘎~',
    '一只鹅的寿命可以达到20-25年，所以鹅宝会陪你很久很久！',
    '鹅可以在8000米的高空飞行，比很多飞机飞得还高呢！',
    '蜂蜜永远不会变质，考古学家在埃及金字塔中发现了3000年前的蜂蜜，依然可以食用！',
    '章鱼有三颗心脏，两个负责把血液送到鳃，一个负责全身循环。',
    '一个人一生中平均会走地球赤道4圈的距离！约16万公里~',
    '世界上最长的英文单词有189,819个字母，是一种蛋白质的化学名称！',
    '猫每天大约睡16-17个小时，鹅宝也想这么睡...但要陪你呀！',
  ];

  static const _tongueTwisters = [
    '吃葡萄不吐葡萄皮，不吃葡萄倒吐葡萄皮。嘎嘎嘎鹅宝说不来~',
    '四是四，十是十，十四是十四，四十是四十。鹅宝舌头打结了！',
    '黑化肥发灰会挥发，灰化肥挥发会发黑。鹅宝的嘴不够用了！',
    '八百标兵奔北坡，北坡炮兵并排跑。嘎...嘎嘎...鹅宝投降！',
    '牛郎恋刘娘，刘娘恋牛郎。这个鹅宝可以说！...等等，好像不行。',
  ];

  @override
  Future<SkillResult> execute(Map<String, dynamic> args) async {
    var type = args['type'] as String? ?? 'random';

    if (type == 'random') {
      final types = ['joke', 'fun_fact', 'tongue_twister'];
      type = types[_random.nextInt(types.length)];
    }

    switch (type) {
      case 'joke':
        return SkillResult.ok(_jokes[_random.nextInt(_jokes.length)]);
      case 'fun_fact':
        return SkillResult.ok(_funFacts[_random.nextInt(_funFacts.length)]);
      case 'tongue_twister':
        return SkillResult.ok(_tongueTwisters[_random.nextInt(_tongueTwisters.length)]);
      default:
        return SkillResult.ok(_jokes[_random.nextInt(_jokes.length)]);
    }
  }
}
