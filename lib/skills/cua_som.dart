/// CUA SOM (Set of Mark) 标记生成器
///
/// 在截图上绘制编号圆圈标记，标注可交互 UI 元素。
/// Brain（视觉模型）通过标记号 [N] 引用元素，系统自动解析为坐标。
///
/// 绘制方案：通过 Python Pillow 脚本绘制（dart:ui 的 toImage 在 macOS 桌面端
/// 有纹理大小限制，Retina 截图 3456×2234 会失败）。
///
/// 参考方案：Anthropic Claude Computer Use / Microsoft OmniParser
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' show min, max;

import 'package:flutter/foundation.dart';

import 'cua_accessibility.dart';

/// 单个 SOM 标记
class SomMarker {
  final int id;
  final double x; // normalized 0~1000 (element top-left)
  final double y;
  final double width; // normalized 0~1000
  final double height;
  final String role;
  final String title;
  final String? description;

  const SomMarker({
    required this.id,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.role,
    required this.title,
    this.description,
  });

  /// 中心点（归一化坐标 0~1000）
  double get centerX => x + width / 2;
  double get centerY => y + height / 2;

  @override
  String toString() => '[$id] (${centerX.round()}, ${centerY.round()}) $role "$title"';
}

class CuaSom {
  /// 最大标记数量
  static const maxMarkers = 80;

  /// 最小元素面积（归一化平方，1000x1000 坐标系下）
  static const minArea = 10.0; // ~1% of 1000x1000

  /// 最大元素面积
  static const maxArea = 800000.0; // ~80% of 1000x1000

  /// 合并距离阈值（逻辑像素数，与 Python 测试脚本一致）
  static const _mergeDistLogicalPixels = 50;

  /// 当前截图的标记列表（由截图流程更新，Brain 回调读取）
  static List<SomMarker> lastMarkers = [];

  /// 从 UI 树提取所有有坐标的节点，距离合并去重
  ///
  /// [windowBounds] 可选的应用窗口边界 (x, y, w, h)（逻辑坐标），
  /// 如果提供，则只标记窗口边界内的元素。
  static List<SomMarker> extractMarkers(
    UiTreeNode? root,
    int screenW,
    int screenH, {
    (double, double, double, double)? windowBounds,
  }) {
    if (root == null) return [];

    // 如果未提供窗口边界，从根节点的子元素中找面积最大的窗口
    (double, double, double, double)? bounds = windowBounds;
    if (bounds == null) {
      double maxArea = 0;
      for (final child in root.children) {
        if (child.x != null && child.y != null &&
            child.width != null && child.height != null &&
            child.width! > 0 && child.height! > 0) {
          final area = child.width! * child.height!;
          if (area > maxArea) {
            maxArea = area;
            bounds = (child.x!, child.y!, child.width!, child.height!);
          }
        }
      }
    }

    final candidates = <SomMarker>[];
    var nextId = 1;

    void traverse(UiTreeNode node) {
      if (node.x != null && node.y != null &&
          node.width != null && node.height != null) {
        // 如果有窗口边界，跳过窗口外的元素
        if (bounds != null) {
          final (bx, by, bw, bh) = bounds;
          final nx = node.x!;
          final ny = node.y!;
          final nw = node.width!;
          final nh = node.height!;
          // 元素中心必须在窗口边界内（留 5% 容差）
          final cx = nx + nw / 2;
          final cy = ny + nh / 2;
          final margin = 0.05;
          if (cx < bx - bw * margin || cx > bx + bw * (1 + margin) ||
              cy < by - bh * margin || cy > by + bh * (1 + margin)) {
            // 不在窗口内，但仍然递归子元素（子元素可能在窗口内）
            for (final child in node.children) {
              traverse(child);
            }
            return;
          }
        }

        // 归一化到 0~1000 坐标系
        final nx = (node.x! / screenW * 1000).clamp(0.0, 1000.0);
        final ny = (node.y! / screenH * 1000).clamp(0.0, 1000.0);
        final nw = (node.width! / screenW * 1000).clamp(0.0, 1000.0);
        final nh = (node.height! / screenH * 1000).clamp(0.0, 1000.0);

        // 优先取自身文本，否则从 value/description 取
        String label = node.title;
        if (label.isEmpty) label = node.value;
        if (label.isEmpty) label = node.description;
        if (label.length > 30) label = '${label.substring(0, 30)}...';

        candidates.add(SomMarker(
          id: nextId++,
          x: nx,
          y: ny,
          width: nw,
          height: nh,
          role: node.role,
          title: label,
          description:
              node.description.isNotEmpty ? node.description : null,
        ));
      }

      for (final child in node.children) {
        traverse(child);
      }
    }

    traverse(root);
    // 合并距离：50 逻辑像素 → 归一化坐标（与 Python 测试脚本一致）
    final mergeDist = _mergeDistLogicalPixels / screenW * 1000.0;
    return _filterAndMerge(candidates, mergeDist);
  }

  /// 过滤太小/太大的元素，距离合并 + 包含合并去重
  static List<SomMarker> _filterAndMerge(List<SomMarker> candidates, double mergeDist) {
    // 面积过滤
    final filtered = candidates.where((m) {
      final area = m.width * m.height;
      return area >= minArea && area <= maxArea &&
          m.width >= 3 && m.height >= 3;
    }).toList();

    // 面积升序排列：小元素优先保留，父大元素更容易被淘汰
    filtered.sort((a, b) => (a.width * a.height).compareTo(b.width * b.height));

    final result = <SomMarker>[];
    for (final m in filtered) {
      bool merged = false;
      for (final k in result) {
        // 1) 距离合并：中心点很近
        final dx = (m.centerX - k.centerX).abs();
        final dy = (m.centerY - k.centerY).abs();
        if (dx < mergeDist && dy < mergeDist) {
          merged = true;
          break;
        }
        // 2) 包含合并：当前候选被已保留的元素包含（父元素被淘汰）
        if (_isContained(m, k)) {
          merged = true;
          break;
        }
      }

      if (merged) continue;

      // 3) 替换检查：当前候选包含了已保留的小元素（父大元素替换子小元素）
      //    仅当大元素有文本信息时才替换
      final toRemove = <int>[];
      bool replaced = false;
      for (var i = 0; i < result.length; i++) {
        if (!replaced && _isContained(result[i], m)) {
          if (m.title.isNotEmpty || result[i].title.isEmpty) {
            toRemove.add(i);
            replaced = true;
          }
        }
      }
      if (replaced) {
        for (var i = toRemove.length - 1; i >= 0; i--) {
          result.removeAt(toRemove[i]);
        }
      }
      result.add(m);
      if (result.length >= maxMarkers) break;
    }

    // 重新编号
    for (var i = 0; i < result.length; i++) {
      result[i] = SomMarker(
        id: i + 1,
        x: result[i].x,
        y: result[i].y,
        width: result[i].width,
        height: result[i].height,
        role: result[i].role,
        title: result[i].title,
        description: result[i].description,
      );
    }

    return result;
  }

  /// 判断 inner 是否被 outer 包含（≥80% 面积重叠即视为包含）
  static bool _isContained(SomMarker inner, SomMarker outer) {
    final iArea = inner.width * inner.height;
    if (iArea <= 0) return false;
    final oArea = outer.width * outer.height;
    // outer 必须比 inner 大，否则不可能是包含关系
    if (oArea < iArea * 1.2) return false;
    // 计算重叠矩形
    final ix1 = inner.x, iy1 = inner.y;
    final ix2 = inner.x + inner.width, iy2 = inner.y + inner.height;
    final ox1 = outer.x, oy1 = outer.y;
    final ox2 = outer.x + outer.width, oy2 = outer.y + outer.height;
    final overlapX = min(ix2, ox2) - max(ix1, ox1);
    final overlapY = min(iy2, oy2) - max(iy1, oy1);
    if (overlapX <= 0 || overlapY <= 0) return false;
    final overlapArea = overlapX * overlapY;
    return overlapArea >= iArea * 0.6;
  }

  /// 用 Python Pillow 在 PNG 图像上绘制标记圆圈
  ///
  /// 比 dart:ui 的 toImage 更可靠（无纹理大小限制），
  /// macOS 系统自带 Python3 + Pillow 通常可用。
  ///
  /// [pngPath] PNG 文件路径（就地覆盖）
  /// [markers] 要绘制的标记列表
  /// [imgW] PNG 实际像素宽度（Retina = 逻辑宽度 × scaleFactor）
  /// [imgH] PNG 实际像素高度
  ///
  /// 返回 true 表示成功绘制
  static Future<bool> drawMarkersWithPillow(
    String pngPath,
    List<SomMarker> markers, {
    int? imgW,
    int? imgH,
  }) async {
    if (markers.isEmpty) return false;

    try {
      // 构建 markers JSON
      final markersJson = jsonEncode(
        markers.map((m) => {
          'id': m.id,
          'cx': m.centerX / 1000.0, // 归一化到 0~1
          'cy': m.centerY / 1000.0,
          'w': m.width / 1000.0,
          'h': m.height / 1000.0,
          'title': m.title,
        }).toList(),
      );

      const script = r'''
import json, sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("NO_PILLOW")
    sys.exit(1)

png_path = sys.argv[1]
markers_json = sys.argv[2]

markers = json.loads(markers_json)
img = Image.open(png_path).convert("RGBA")
w, h = img.size

overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(overlay)

# 加载字体（优先中文字体）
font = None
font_small = None
for fp in [
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/Library/Fonts/Arial Unicode.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/SFNSText.ttf",
]:
    try:
        if font is None:
            font = ImageFont.truetype(fp, 14)
            font_small = ImageFont.truetype(fp, 11)
        break
    except (IOError, OSError):
        continue

# 颜色方案
COLORS = [
    (220, 50, 47, 220), (38, 139, 210, 220), (133, 153, 0, 220),
    (181, 137, 0, 220), (211, 54, 130, 220), (108, 113, 196, 220),
]

for m in markers:
    cx = int(m["cx"] * w)
    cy = int(m["cy"] * h)
    ew = m["w"] * w
    eh = m["h"] * h
    color = COLORS[(m["id"] - 1) % len(COLORS)]
    # 元素矩形边界
    x1 = int(cx - ew / 2)
    y1 = int(cy - eh / 2)
    x2 = int(cx + ew / 2)
    y2 = int(cy + eh / 2)
    # 绘制描边框（不填充，只画边框）
    draw.rectangle([x1, y1, x2, y2], outline=color, width=2)
    # 左上角编号气泡（放在框内）
    badge_r = 10
    bx = x1 + badge_r
    by = y1 + badge_r
    draw.ellipse([bx-badge_r, by-badge_r, bx+badge_r, by+badge_r],
                 fill=color, outline=(255,255,255,255), width=1)
    label = str(m["id"])
    if font:
        bbox = draw.textbbox((0, 0), label, font=font)
        tw, th = bbox[2]-bbox[0], bbox[3]-bbox[1]
        draw.text((bx - tw//2, by - th//2 - 1), label, fill=(255,255,255,255), font=font)
    else:
        draw.text((bx - 4, by - 7), label, fill=(255,255,255,255))
    # 文字标签（框内左下角）
    title = m.get("title", "")
    if title and font_small:
        tag = title[:20]
        tbbox = draw.textbbox((0, 0), tag, font=font_small)
        ttw = tbbox[2] - tbbox[0]
        tth = tbbox[3] - tbbox[1]
        tx = x1 + 4
        ty = y2 - tth - 4
        # 半透明背景
        draw.rectangle([tx-2, ty-1, tx+ttw+2, ty+tth+2], fill=(0,0,0,160))
        draw.text((tx, ty), tag, fill=(255,255,255,255), font=font_small)

result = Image.alpha_composite(img, overlay)
result.convert("RGB").save(png_path, "PNG")
print(f"OK:{len(markers)}")
''';

      final result = await Process.run(
        'python3',
        ['-c', script, pngPath, markersJson],
      ).timeout(const Duration(seconds: 10));

      if (result.exitCode == 0) {
        final stdout = result.stdout.toString().trim();
        debugPrint('🏷️ SOM Pillow: $stdout');
        return stdout.startsWith('OK:');
      }

      final stderr = result.stderr.toString().trim();
      if (stderr.contains('NO_PILLOW')) {
        debugPrint('🏷️ SOM: Pillow 未安装，尝试自动安装...');
        // 尝试安装 Pillow
        final installResult = await Process.run(
          'python3',
          ['-m', 'pip', 'install', 'Pillow', '-q'],
        ).timeout(const Duration(seconds: 30));

        if (installResult.exitCode == 0) {
          // 安装成功，重试绘制
          final retryResult = await Process.run(
            'python3',
            ['-c', script, pngPath, markersJson],
          ).timeout(const Duration(seconds: 10));

          if (retryResult.exitCode == 0) {
            final stdout = retryResult.stdout.toString().trim();
            debugPrint('🏷️ SOM Pillow (重试): $stdout');
            return stdout.startsWith('OK:');
          }
        }
        debugPrint('🏷️ SOM: Pillow 安装/重试失败');
      } else {
        debugPrint('🏷️ SOM Pillow 错误: $stderr');
      }
      return false;
    } catch (e) {
      debugPrint('⚠️ SOM Pillow 绘制失败: $e');
      return false;
    }
  }

  /// 将 Brain 输出中的标记引用 [N] 替换为归一化坐标 (x, y)
  ///
  /// 例如 "点击 [15]" → "点击 (350, 100)"
  static String resolveMarkers(String text, List<SomMarker> markers) {
    if (markers.isEmpty) return text;

    return text.replaceAllMapped(
      RegExp(r'\[(\d+)\]'),
      (m) {
        final id = int.tryParse(m.group(1)!);
        if (id == null) return m.group(0)!;

        final marker =
            markers.where((mk) => mk.id == id).firstOrNull;
        if (marker == null) return m.group(0)!;

        return '(${marker.centerX.round()}, ${marker.centerY.round()})';
      },
    );
  }

  /// 构建标记列表文本（供 Brain prompt 使用）
  ///
  /// 输出示例：
  /// ```
  /// [1] AXButton "关闭"
  /// [2] AXTextField "搜索"
  /// [3] AXButton "搜索"
  /// ```
  static String buildMarkerListText(List<SomMarker> markers) {
    if (markers.isEmpty) return '';

    final buf = StringBuffer();
    for (final m in markers) {
      final label = <String>[m.role];
      if (m.title.isNotEmpty) label.add('"$m.title"');
      if (m.description != null && m.description != m.title) {
        label.add('(${m.description})');
      }
      buf.writeln('[${m.id}] ${label.join(' ')}');
    }
    return buf.toString();
  }

  /// 根据归一化坐标找到最近的 SOM 标记
  ///
  /// 用于在 mouse_click 等操作后，输出点击命中的标记信息。
  /// [maxDist] 最大匹配距离（归一化坐标），默认 20（= 屏幕 2%）。
  static SomMarker? findNearestMarker(double normalizedX, double normalizedY, {double maxDist = 20.0}) {
    if (lastMarkers.isEmpty) return null;
    SomMarker? closest;
    double minDist = double.infinity;
    for (final m in lastMarkers) {
      final dx = (m.centerX - normalizedX).abs();
      final dy = (m.centerY - normalizedY).abs();
      final dist = dx + dy; // Manhattan distance
      if (dist < minDist) {
        minDist = dist;
        closest = m;
      }
    }
    if (closest == null || minDist > maxDist) return null;
    return closest;
  }
}
