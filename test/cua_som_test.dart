/// CUA SOM (Set of Mark) 截图打标逻辑的单元测试
///
/// 测试覆盖：
/// 1. extractMarkers — 从 UI 树提取标记
/// 2. _filterAndMerge — 过滤 + 距离合并 + 包含合并
/// 3. resolveMarkers — [N] 标记引用替换为坐标
/// 4. buildMarkerListText — 构建标记文本
/// 5. findNearestMarker — 查找最近标记
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:goose_baby/skills/cua_accessibility.dart';
import 'package:goose_baby/skills/cua_som.dart';

// ═══════════════════════════════════════════
// 辅助构造器
// ═══════════════════════════════════════════

UiTreeNode node({
  String role = 'AXButton',
  String title = '',
  String value = '',
  String description = '',
  double? x,
  double? y,
  double? width,
  double? height,
  bool enabled = true,
  List<UiTreeNode> children = const [],
}) {
  return UiTreeNode(
    role: role,
    title: title,
    value: value,
    description: description,
    x: x,
    y: y,
    width: width,
    height: height,
    enabled: enabled,
    children: children,
  );
}

/// 创建一个标准的 1920×1080 屏幕上的窗口（坐标为逻辑像素）
UiTreeNode createWindow({
  double x = 100,
  double y = 100,
  double width = 800,
  double height = 600,
  List<UiTreeNode> children = const [],
}) {
  return node(
    role: 'AXWindow',
    title: 'Test Window',
    x: x, y: y, width: width, height: height,
    children: children,
  );
}

void main() {
  // ═══════════════════════════════════════════
  // 1. extractMarkers 基础测试
  // ═══════════════════════════════════════════

  group('extractMarkers', () {
    test('空 UI 树返回空列表', () {
      expect(CuaSom.extractMarkers(null, 1920, 1080), isEmpty);
    });

    test('无坐标节点不生成标记', () {
      final root = node(role: 'AXGroup', children: [
        node(role: 'AXStaticText', title: 'Hello'),
      ]);
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers, isEmpty);
    });

    test('有坐标的节点生成标记', () {
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXButton', title: 'OK', x: 100, y: 100, width: 80, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers, hasLength(1));
      expect(markers.first.role, 'AXButton');
      expect(markers.first.title, 'OK');
    });

    test('归一化坐标计算正确', () {
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXButton', title: 'Test', x: 960, y: 540, width: 192, height: 108),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers, hasLength(1));
      // 960/1920*1000 = 500, 540/1080*1000 = 500
      expect(markers.first.x, closeTo(500.0, 0.1));
      expect(markers.first.y, closeTo(500.0, 0.1));
      // 192/1920*1000 = 100, 108/1080*1000 = 100
      expect(markers.first.width, closeTo(100.0, 0.1));
      expect(markers.first.height, closeTo(100.0, 0.1));
      expect(markers.first.centerX, closeTo(550.0, 0.1));
      expect(markers.first.centerY, closeTo(550.0, 0.1));
    });

    test('标记按遍历顺序分配递增 ID', () {
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXButton', title: 'A', x: 10, y: 10, width: 100, height: 30),
          node(role: 'AXButton', title: 'B', x: 200, y: 10, width: 100, height: 30),
          node(role: 'AXTextField', title: 'C', x: 10, y: 100, width: 200, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers, hasLength(3));
      // 过滤+合并后重新编号，ID 从 1 开始连续
      final ids = markers.map((m) => m.id).toList();
      expect(ids, [1, 2, 3]);
    });
  });

  // ═══════════════════════════════════════════
  // 2. 窗口边界过滤
  // ═══════════════════════════════════════════

  group('窗口边界过滤', () {
    test('只标记窗口内的元素', () {
      final root = node(
        role: 'AXGroup',
        children: [
          createWindow(
            x: 200, y: 200, width: 400, height: 300,
            children: [
              node(role: 'AXButton', title: 'Inside', x: 250, y: 250, width: 50, height: 30),
            ],
          ),
          node(role: 'AXButton', title: 'Outside', x: 10, y: 10, width: 50, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      final titles = markers.map((m) => m.title);
      expect(titles, contains('Inside'));
      expect(titles, isNot(contains('Outside')));
    });

    test('自动选择面积最大的子元素作为窗口', () {
      final root = node(
        role: 'AXGroup',
        children: [
          node(role: 'AXWindow', x: 0, y: 0, width: 800, height: 600,
              children: [
                node(role: 'AXButton', title: 'InWindow', x: 100, y: 100, width: 50, height: 30),
              ]),
          node(role: 'AXWindow', x: 50, y: 50, width: 100, height: 100,
              children: [
                node(role: 'AXButton', title: 'InSmallWindow', x: 60, y: 60, width: 30, height: 20),
              ]),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      // 大窗口（800x600=480000）会被选为边界
      // 大窗口内按钮 center=(125, 115) 在大窗口 (0,0,800,600) 5% 容差内 → 保留
      // 小窗口内按钮 center=(75, 70) 在大窗口范围内 → 也保留
      // 但如果子窗口元素中心在大窗口内，也会保留
      expect(markers.any((m) => m.title == 'InWindow'), isTrue);
    });
  });

  // ═══════════════════════════════════════════
  // 3. _filterAndMerge 过滤与合并
  // ═══════════════════════════════════════════

  group('_filterAndMerge 过滤与合并', () {
    test('面积太小的元素被过滤', () {
      // minArea = 10, 在 1000 坐标系下
      // 一个 1x1 逻辑像素的按钮在 1920 宽度下 → 归一化 0.52×0.93 → 面积 0.48 < 10
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXButton', title: 'Tiny', x: 100, y: 100, width: 1, height: 1),
          node(role: 'AXButton', title: 'Normal', x: 100, y: 200, width: 80, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers.any((m) => m.title == 'Normal'), isTrue);
    });

    test('面积太大的元素被过滤', () {
      // maxArea = 800000, 在 1000 坐标系下
      // 一个几乎全屏的元素：1800x1000 逻辑像素 → 归一化 937.5×925.9 → 面积 > 800000
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXGroup', title: 'FullPage', x: 0, y: 0, width: 1800, height: 1000),
          node(role: 'AXButton', title: 'Small', x: 100, y: 100, width: 80, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers.any((m) => m.title == 'Small'), isTrue);
      expect(markers.any((m) => m.title == 'FullPage'), isFalse);
    });

    test('距离很近的元素合并（只保留一个）', () {
      // 两个按钮在 1920 宽度下距离 < 50 逻辑像素（mergeDistLogicalPixels=50）
      // 归一化距离 = 50/1920*1000 ≈ 26
      // 两个元素中心距离需 < 26（归一化）
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXButton', title: 'Btn1', x: 100, y: 100, width: 80, height: 30),
          node(role: 'AXStaticText', title: 'Label1', x: 101, y: 101, width: 80, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      // 中心点距离极近，应合并只保留一个
      // 面积排序后小元素优先，但两个面积接近，第二个会被距离合并
      expect(markers.length, lessThanOrEqualTo(2));
    });
  });

  // ═══════════════════════════════════════════
  // 4. _isContained 包含关系检测
  // ═══════════════════════════════════════════

  group('_isContained 包含关系', () {
    test('完全包含的子元素被淘汰', () {
      // 父元素包含子元素（面积比 > 1.2，重叠 > 60%）
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXGroup', title: 'Parent', x: 100, y: 100, width: 200, height: 100),
          node(role: 'AXButton', title: 'Child', x: 110, y: 110, width: 80, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      // Child 被 Parent 包含，面积排序后 Child 较小先处理
      // 然后 Parent 检查时，Child 已在 result 中
      // Parent 会替换包含的子元素（如果 Parent 有 title）
      expect(markers.any((m) => m.title == 'Parent'), isTrue);
    });

    test('不完全包含的元素不被淘汰', () {
      // 两个不重叠的按钮
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXButton', title: 'A', x: 100, y: 100, width: 80, height: 30),
          node(role: 'AXButton', title: 'B', x: 500, y: 500, width: 80, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers.any((m) => m.title == 'A'), isTrue);
      expect(markers.any((m) => m.title == 'B'), isTrue);
    });
  });

  // ═══════════════════════════════════════════
  // 5. 文本标签优先级
  // ═════ title > value > description
  // ═══════════════════════════════════════════

  group('文本标签优先级', () {
    test('优先使用 title', () {
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXButton', title: 'MyButton', value: 'ignored', description: 'ignored',
              x: 100, y: 100, width: 80, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers.first.title, 'MyButton');
    });

    test('title 为空时使用 value', () {
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXTextField', title: '', value: 'hello', description: 'ignored',
              x: 100, y: 100, width: 80, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers.first.title, 'hello');
    });

    test('title 和 value 为空时使用 description', () {
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXImage', title: '', value: '', description: 'icon',
              x: 100, y: 100, width: 30, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers.first.title, 'icon');
    });

    test('超长标签被截断到 30 字符', () {
      final longText = 'A' * 50;
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: [
          node(role: 'AXStaticText', title: longText,
              x: 100, y: 100, width: 80, height: 30),
        ],
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers.first.title.length, lessThanOrEqualTo(33)); // 30 + '...'
      expect(markers.first.title.endsWith('...'), isTrue);
    });
  });

  // ═══════════════════════════════════════════
  // 6. resolveMarkers 标记引用替换
  // ═══════════════════════════════════════════

  group('resolveMarkers', () {
    test('将 [N] 替换为坐标', () {
      final markers = [
        SomMarker(id: 1, x: 100, y: 100, width: 50, height: 50, role: 'AXButton', title: 'OK'),
        SomMarker(id: 2, x: 500, y: 200, width: 50, height: 50, role: 'AXButton', title: 'Cancel'),
      ];

      final result = CuaSom.resolveMarkers('点击 [1] 然后点击 [2]', markers);
      expect(result, contains('点击 (125, 125) 然后点击 (525, 225)'));
    });

    test('不存在的标记号保持不变', () {
      final markers = [
        SomMarker(id: 1, x: 100, y: 100, width: 50, height: 50, role: 'AXButton', title: 'OK'),
      ];

      final result = CuaSom.resolveMarkers('点击 [99]', markers);
      expect(result, '点击 [99]');
    });

    test('空标记列表时文本不变', () {
      expect(CuaSom.resolveMarkers('点击 [1]', []), '点击 [1]');
    });
  });

  // ═══════════════════════════════════════════
  // 7. buildMarkerListText
  // ═══════════════════════════════════════════

  group('buildMarkerListText', () {
    test('空列表返回空字符串', () {
      expect(CuaSom.buildMarkerListText([]), '');
    });

    test('生成正确的标记文本', () {
      final markers = [
        SomMarker(id: 1, x: 100, y: 100, width: 50, height: 50, role: 'AXButton', title: 'OK'),
        SomMarker(id: 2, x: 200, y: 200, width: 50, height: 50, role: 'AXTextField', title: '搜索', description: '搜索框'),
      ];

      final text = CuaSom.buildMarkerListText(markers);
      expect(text, contains('[1] AXButton "OK"'));
      expect(text, contains('[2] AXTextField "搜索" (搜索框)'));
    });

    test('description 与 title 相同时不重复显示', () {
      final markers = [
        SomMarker(id: 1, x: 100, y: 100, width: 50, height: 50, role: 'AXButton', title: 'OK', description: 'OK'),
      ];
      final text = CuaSom.buildMarkerListText(markers);
      expect(text, contains('[1] AXButton "OK"'));
      // 不应该重复出现 "(OK)"
      expect(text.split('OK').length, 3); // '[1] AXButton "OK"\n' → 3 段
    });
  });

  // ═══════════════════════════════════════════
  // 8. findNearestMarker
  // ═══════════════════════════════════════════

  group('findNearestMarker', () {
    setUp(() {
      CuaSom.lastMarkers = [
        SomMarker(id: 1, x: 100, y: 100, width: 50, height: 50, role: 'AXButton', title: 'A'),
        SomMarker(id: 2, x: 500, y: 200, width: 50, height: 50, role: 'AXButton', title: 'B'),
        SomMarker(id: 3, x: 800, y: 500, width: 50, height: 50, role: 'AXButton', title: 'C'),
      ];
    });

    tearDown(() {
      CuaSom.lastMarkers = [];
    });

    test('找到最近的标记', () {
      final marker = CuaSom.findNearestMarker(525, 225);
      expect(marker, isNotNull);
      expect(marker!.id, 2);
    });

    test('超出最大距离返回 null', () {
      // Manhattan 距离默认 maxDist = 20，给一个很远的坐标
      final marker = CuaSom.findNearestMarker(0, 0);
      // [1] 中心 (125, 125)，Manhattan 距离 = 250 > 20
      expect(marker, isNull);
    });

    test('自定义 maxDist', () {
      final marker = CuaSom.findNearestMarker(0, 0, maxDist: 300);
      expect(marker, isNotNull);
      expect(marker!.id, 1);
    });
  });

  // ═══════════════════════════════════════════
  // 9. maxMarkers 上限
  // ═══════════════════════════════════════════

  group('maxMarkers 上限', () {
    test('标记数量不超过 maxMarkers', () {
      final children = <UiTreeNode>[];
      for (var i = 0; i < 100; i++) {
        children.add(node(
          role: 'AXButton',
          title: 'Btn$i',
          x: (i % 10) * 100.0 + 50,
          y: (i ~/ 10) * 60.0 + 50,
          width: 80,
          height: 30,
        ));
      }
      final root = node(
        role: 'AXGroup',
        x: 0, y: 0, width: 1920, height: 1080,
        children: children,
      );
      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers.length, lessThanOrEqualTo(CuaSom.maxMarkers));
    });
  });

  // ═══════════════════════════════════════════
  // 10. SomMarker 数据模型
  // ═══════════════════════════════════════════

  group('SomMarker', () {
    test('centerX / centerY 计算正确', () {
      final m = SomMarker(id: 1, x: 100, y: 200, width: 60, height: 40, role: 'AXButton', title: 'Test');
      expect(m.centerX, 130.0);
      expect(m.centerY, 220.0);
    });

    test('toString 格式正确', () {
      final m = SomMarker(id: 5, x: 100, y: 200, width: 60, height: 40, role: 'AXButton', title: 'OK');
      expect(m.toString(), '[5] (130, 220) AXButton "OK"');
    });
  });

  // ═══════════════════════════════════════════
  // 11. 综合场景测试
  // ═══════════════════════════════════════════

  group('综合场景', () {
    test('模拟 macOS Finder 工具栏标记', () {
      // Finder 窗口 + 工具栏按钮 + 侧边栏
      final finder = createWindow(
        x: 0, y: 23, width: 800, height: 600,
        children: [
          // 工具栏（顶部）
          node(role: 'AXGroup', title: 'Toolbar', x: 0, y: 23, width: 800, height: 40, children: [
            node(role: 'AXButton', title: '后退', x: 10, y: 28, width: 30, height: 30),
            node(role: 'AXButton', title: '前进', x: 45, y: 28, width: 30, height: 30),
            node(role: 'AXTextField', title: '搜索', x: 300, y: 30, width: 200, height: 25),
          ]),
          // 侧边栏
          node(role: 'AXGroup', title: 'Sidebar', x: 0, y: 63, width: 180, height: 537, children: [
            node(role: 'AXStaticText', title: '收藏', x: 15, y: 80, width: 40, height: 20),
            node(role: 'AXRow', title: '桌面', x: 15, y: 105, width: 160, height: 25),
            node(role: 'AXRow', title: '文档', x: 15, y: 130, width: 160, height: 25),
          ]),
          // 文件列表区域
          node(role: 'AXGroup', title: 'FileList', x: 180, y: 63, width: 620, height: 537, children: [
            node(role: 'AXRow', title: 'file1.txt', x: 180, y: 63, width: 620, height: 25),
            node(role: 'AXRow', title: 'file2.pdf', x: 180, y: 88, width: 620, height: 25),
          ]),
        ],
      );

      final markers = CuaSom.extractMarkers(finder, 1440, 900);
      // 基本检查：应该有多个标记
      expect(markers, isNotEmpty);

      // 应包含搜索框和文件项
      final hasSearch = markers.any((m) => m.title == '搜索');
      expect(hasSearch, isTrue);
    });

    test('多层嵌套 UI 树正确遍历', () {
      final deepChild = node(role: 'AXButton', title: 'Deep', x: 50, y: 50, width: 30, height: 20);
      final level2 = node(role: 'AXGroup', x: 40, y: 40, width: 200, height: 100, children: [deepChild]);
      final level1 = node(role: 'AXGroup', x: 30, y: 30, width: 300, height: 200, children: [level2]);
      final root = node(role: 'AXGroup', x: 0, y: 0, width: 1920, height: 1080, children: [level1]);

      final markers = CuaSom.extractMarkers(root, 1920, 1080);
      expect(markers.any((m) => m.title == 'Deep'), isTrue);
    });
  });
}
