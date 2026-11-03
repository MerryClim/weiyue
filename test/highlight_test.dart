import 'package:flutter_test/flutter_test.dart';
import 'package:weiyue/core.dart';

void main() {
  Highlight hl(int s, int e, String color) =>
      Highlight(articleId: 1, start: s, end: e, text: '', color: color);

  test('基本分段：中间一段高亮', () {
    final segs = splitText(10, [hl(2, 5, 'yellow')]);
    expect(segs.length, 3);
    expect(segs[0].from, 0);
    expect(segs[0].to, 2);
    expect(segs[0].hl, isNull);
    expect(segs[1].from, 2);
    expect(segs[1].to, 5);
    expect(segs[1].hl!.color, 'yellow');
    expect(segs[2].from, 5);
    expect(segs[2].to, 10);
    expect(segs[2].hl, isNull);
  });

  test('越界区间自动裁剪', () {
    final segs = splitText(6, [hl(4, 99, 'blue')]);
    final colored = segs.where((s) => s.hl != null).toList();
    expect(colored.length, 1);
    expect(colored.first.from, 4);
    expect(colored.first.to, 6);
  });

  test('重叠区间：后添加的优先显示', () {
    final segs = splitText(10, [hl(1, 8, 'yellow'), hl(3, 6, 'blue')]);
    final colored = segs.where((s) => s.hl != null).toList();
    expect(colored.length, 3);
    expect(colored[0].from, 1);
    expect(colored[0].hl!.color, 'yellow');
    expect(colored[1].from, 3);
    expect(colored[1].hl!.color, 'blue');
    expect(colored[2].from, 6);
    expect(colored[2].hl!.color, 'yellow');
  });

  test('多段标记后总长度守恒', () {
    final hls = [hl(0, 4, 'green'), hl(7, 9, 'yellow'), hl(12, 12, 'blue')];
    final segs = splitText(15, hls);
    var total = 0;
    for (final s in segs) {
      total += s.to - s.from;
    }
    expect(total, 15);
  });

  test('整段全部高亮', () {
    final segs = splitText(5, [hl(0, 5, 'green')]);
    expect(segs.length, 1);
    expect(segs.first.hl!.color, 'green');
  });
}
