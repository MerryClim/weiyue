// 阅读页：正文渲染 / 划词标记 / 笔记 / 标记面板 / 导出 / 删除
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core.dart';

const _hlColors = <String, Color>{
  'yellow': Color(0x66F2C94C),
  'green': Color(0x6659B96B),
  'blue': Color(0x66518FE0),
};

const _bodyStyle = TextStyle(fontSize: 16.5, height: 1.85, color: Color(0xFF23262B));

class ReaderScreen extends StatefulWidget {
  final int articleId;
  const ReaderScreen({super.key, required this.articleId});
  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  Article? _art;
  List<Block> _blocks = [];
  List<Highlight> _hls = [];
  List<int> _blockStarts = [];
  List<int> _olNums = [];
  List<GlobalKey> _blockKeys = [];
  int? _flashBlock;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = await DB.article(widget.articleId);
    if (a == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final hls = await DB.highlights(widget.articleId);
    if (!mounted) return;
    setState(() {
      _art = a;
      _blocks = decodeBlocks(a.blocksJson);
      _hls = hls;
      _computeOffsets();
    });
  }

  void _computeOffsets() {
    _blockStarts = List<int>.filled(_blocks.length, 0);
    _olNums = List<int>.filled(_blocks.length, 0);
    _blockKeys = List.generate(_blocks.length, (_) => GlobalKey());
    var pos = 0;
    var ol = 0;
    for (var i = 0; i < _blocks.length; i++) {
      _blockStarts[i] = pos;
      final t = _blocks[i].text;
      if (t.trim().isNotEmpty) pos += t.length + 2;
      if (_blocks[i].type == 'li' && _blocks[i].src == 'ol') {
        ol++;
        _olNums[i] = ol;
      } else {
        ol = 0;
      }
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // ---------------- 顶部操作 ----------------
  Future<void> _toggleFav() async {
    final a = _art!;
    final v = a.favorite == 1 ? 0 : 1;
    a.favorite = v;
    await DB.updateArticle(a.id!, {'favorite': v});
    if (mounted) setState(() {});
    _toast(v == 1 ? '已收藏' : '已取消收藏');
  }

  Future<void> _pickCategory() async {
    final a = _art!;
    final cats = await DB.categories();
    if (!mounted) return;
    final sel = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('移动到分类', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.folder_off_outlined),
              title: const Text('未分类'),
              trailing: a.categoryId == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, -1),
            ),
            for (final c in cats)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(c.name),
                trailing: a.categoryId == c.id ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, c.id),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (sel == null) return;
    a.categoryId = sel == -1 ? null : sel;
    await DB.updateArticle(a.id!, {'category_id': a.categoryId});
    if (mounted) setState(() {});
  }

  Future<void> _delete() async {
    final a = _art!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('删除「${a.title}」？\n标记和笔记会一并删除，不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await DB.deleteArticle(a.id!);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _openOriginal() async {
    final a = _art!;
    if (a.url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(a.url), mode: LaunchMode.externalApplication);
    } catch (_) {
      _toast('无法打开链接');
    }
  }

  Future<void> _export() async {
    final a = _art!;
    final md = exportMarkdown(a, _blocks);
    try {
      final dir = await getTemporaryDirectory();
      var name = a.title.replaceAll(RegExp(r'[<>:"/\\|?*\r\n]'), '_').trim();
      if (name.isEmpty) name = 'article';
      if (name.length > 60) name = name.substring(0, 60);
      final file = File('${dir.path}/$name.md');
      await file.writeAsString(md);
      await Share.shareXFiles([XFile(file.path, mimeType: 'text/markdown')],
          subject: a.title);
    } catch (e) {
      _toast('导出失败：$e');
    }
  }

  // ---------------- 标记 ----------------
  void _addHighlight(int blockIndex, EditableTextState state, String color,
      String? withNote) {
    final b = _blocks[blockIndex];
    final sel = state.textEditingValue.selection;
    final start = sel.start < sel.end ? sel.start : sel.end;
    final end = sel.start < sel.end ? sel.end : sel.start;
    if (end <= start) return;
    final text = b.text.substring(start, end);
    if (text.trim().isEmpty) return;
    final blockStart = _blockStarts[blockIndex];
    final gs = blockStart + start;
    final ge = blockStart + end;
    if (_hls.any((h) => h.start < ge && h.end > gs)) {
      _toast('与已有标记重叠，请调整选区');
      return;
    }

    Future<void> save(String note) async {
      final h = await DB.addHighlight(Highlight(
          articleId: widget.articleId,
          start: gs,
          end: ge,
          text: text,
          note: note,
          color: color));
      if (!mounted) return;
      setState(() {
        _hls.add(h);
        _hls.sort((x, y) => x.start.compareTo(y.start));
      });
      _toast('已添加标记');
    }

    if (withNote == 'note') {
      _noteDialog('', '标记并写笔记', save);
    } else {
      save('');
    }
  }

  Future<void> _noteDialog(
      String current, String title, Future<void> Function(String) onSave) async {
    final ctrl = TextEditingController(text: current);
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 6,
          decoration: const InputDecoration(
              hintText: '写下你的想法、批注…', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (note != null) await onSave(note);
  }

  void _onTapHl(Highlight h) {
    // 用 id 回查原始对象，保证笔记修改/删除作用到真实数据
    h = _hls.firstWhere((x) => x.id == h.id, orElse: () => h);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _hlColors[h.color] ?? const Color(0x66F2C94C),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(h.text,
                    style: const TextStyle(fontSize: 15, height: 1.7)),
              ),
              if (h.note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(h.note,
                      style: const TextStyle(fontSize: 14, height: 1.7)),
                ),
              const SizedBox(height: 12),
              Row(children: [
                TextButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await Clipboard.setData(ClipboardData(text: h.text));
                    _toast('已复制');
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('复制'),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _noteDialog(h.note, '编辑笔记', (note) async {
                      h.note = note;
                      await DB.updateHighlight(h.id!, {'note': note});
                      if (mounted) setState(() {});
                      _toast('笔记已保存');
                    });
                  },
                  icon: const Icon(Icons.edit_note, size: 20),
                  label: const Text('笔记'),
                ),
                TextButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await DB.deleteHighlight(h.id!);
                    if (mounted) {
                      setState(() => _hls.removeWhere((x) => x.id == h.id));
                    }
                    _toast('标记已删除');
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('删除', style: TextStyle(color: Colors.red)),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  void _jumpTo(Highlight h) {
    Navigator.pop(context); // 关闭抽屉
    var idx = -1;
    for (var i = 0; i < _blockStarts.length; i++) {
      final len = _blocks[i].text.length;
      if (len == 0) continue;
      if (h.start >= _blockStarts[i] && h.start < _blockStarts[i] + len) {
        idx = i;
        break;
      }
    }
    if (idx < 0) return;
    final ctx = _blockKeys[idx].currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          alignment: 0.25);
    }
    setState(() {
      _flashBlock = idx;
    });
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() {
          _flashBlock = null;
        });
      }
    });
  }

  // ---------------- 文本渲染 ----------------
  List<InlineSpan> _buildSpans(Block b, int blockStart, TextStyle base) {
    final frag = hp.parseFragment(b.html);
    final runs = <_Run>[];
    _collectRuns(frag, base, null, runs);

    final len = b.text.length;
    final local = <Highlight>[];
    for (final h in _hls) {
      final s = h.start - blockStart;
      final e = h.end - blockStart;
      if (e > 0 && s < len) {
        local.add(Highlight(
          id: h.id,
          articleId: h.articleId,
          start: s < 0 ? 0 : s,
          end: e > len ? len : e,
          text: h.text,
          note: h.note,
          color: h.color,
        ));
      }
    }

    final spans = <InlineSpan>[];
    var runPos = 0;
    for (final run in runs) {
      final runLen = run.text.length;
      if (runLen == 0) continue;
      final nodeStart = runPos;
      final runLocal = <Highlight>[];
      for (final h in local) {
        final s = h.start - nodeStart;
        final e = h.end - nodeStart;
        if (e > 0 && s < runLen) {
          runLocal.add(Highlight(
            id: h.id,
            articleId: h.articleId,
            start: s < 0 ? 0 : s,
            end: e > runLen ? runLen : e,
            text: '',
            note: h.note,
            color: h.color,
          ));
        }
      }
      for (final seg in splitText(runLen, runLocal)) {
        final txt = run.text.substring(seg.from, seg.to);
        var st = run.style;
        TapGestureRecognizer? rec;
        if (seg.hl != null) {
          st = st.copyWith(
              backgroundColor: _hlColors[seg.hl!.color] ?? const Color(0x66F2C94C));
          final hl = seg.hl!;
          rec = TapGestureRecognizer()..onTap = () => _onTapHl(hl);
        } else if (run.href != null) {
          final href = run.href!;
          rec = TapGestureRecognizer()
            ..onTap = () async {
              try {
                await launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
              } catch (_) {}
            };
        }
        spans.add(TextSpan(text: txt, style: st, recognizer: rec));
      }
      runPos += runLen;
    }
    return spans;
  }

  void _collectRuns(dom.Node node, TextStyle style, String? href, List<_Run> runs) {
    if (node is dom.Text) {
      runs.add(_Run(node.text, style, href));
    } else if (node is dom.Element) {
      final tag = node.localName ?? '';
      var st = style;
      String? h = href;
      if (tag == 'b' || tag == 'strong') {
        st = st.merge(const TextStyle(fontWeight: FontWeight.w700));
      }
      if (tag == 'i' || tag == 'em') {
        st = st.merge(const TextStyle(fontStyle: FontStyle.italic));
      }
      if (tag == 'code') {
        st = st.merge(const TextStyle(
            fontFamily: 'monospace', fontSize: 14, backgroundColor: Color(0xFFF1F3F5)));
      }
      if (tag == 'a') {
        final hrefAttr = node.attributes['href'];
        if (hrefAttr != null && hrefAttr.startsWith('http')) h = hrefAttr;
      }
      for (final c in node.nodes) {
        _collectRuns(c, st, h, runs);
      }
    }
  }

  Widget _selectableText(int i, Block b, {TextStyle? style}) {
    final base = style ?? _bodyStyle;
    final blockStart = _blockStarts[i];
    final spans = _buildSpans(b, blockStart, base);
    return SelectableText.rich(
      TextSpan(style: base, children: spans),
      contextMenuBuilder: (context, editableTextState) {
        final items = <ContextMenuButtonItem>[];
        final sel = editableTextState.textEditingValue.selection;
        if (!sel.isCollapsed) {
          items.add(ContextMenuButtonItem(
              label: '🟡 黄色标记',
              onPressed: () => _addHighlight(i, editableTextState, 'yellow', null)));
          items.add(ContextMenuButtonItem(
              label: '🟢 绿色标记',
              onPressed: () => _addHighlight(i, editableTextState, 'green', null)));
          items.add(ContextMenuButtonItem(
              label: '🔵 蓝色标记',
              onPressed: () => _addHighlight(i, editableTextState, 'blue', null)));
          items.add(ContextMenuButtonItem(
              label: '📝 标记并写笔记',
              onPressed: () => _addHighlight(i, editableTextState, 'yellow', 'note')));
        }
        items.addAll(editableTextState.contextMenuButtonItems);
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: editableTextState.contextMenuAnchors,
          buttonItems: items,
        );
      },
    );
  }

  Widget _wrap(int i, Widget child) {
    return AnimatedContainer(
      key: _blockKeys[i],
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        color: _flashBlock == i ? const Color(0x3307C160) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }

  Widget _buildBlock(int i) {
    final b = _blocks[i];
    switch (b.type) {
      case 'img':
        return _wrap(
          i,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                b.src,
                headers: const {'Referer': 'https://mp.weixin.qq.com/'},
                fit: BoxFit.fitWidth,
                loadingBuilder: (ctx, child, progress) => progress == null
                    ? child
                    : Container(
                        height: 160,
                        color: const Color(0xFFEDEFF2),
                        alignment: Alignment.center,
                        child: const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                errorBuilder: (ctx, e, s) => Container(
                  height: 120,
                  color: const Color(0xFFEDEFF2),
                  alignment: Alignment.center,
                  child:
                      const Icon(Icons.broken_image_outlined, color: Colors.grey),
                ),
              ),
            ),
          ),
        );
      case 'video':
        return _wrap(
          i,
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF2F4F7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              const Icon(Icons.play_circle_outline, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: Text(b.text,
                    style: const TextStyle(color: Colors.grey, fontSize: 14)),
              ),
              TextButton(
                  onPressed: _openOriginal, child: const Text('去原文看')),
            ]),
          ),
        );
      case 'pre':
        return _wrap(
          i,
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF6F7F9),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: SelectableText(b.text,
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 13.5, height: 1.7)),
          ),
        );
      case 'li':
        final isOl = b.src == 'ol';
        return _wrap(
          i,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 30,
                child: Text(
                  isOl ? '${_olNums[i]}.' : '•',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black45),
                ),
              ),
              Expanded(child: _selectableText(i, b)),
            ]),
          ),
        );
      case 'quote':
        return _wrap(
          i,
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            decoration: const BoxDecoration(
              border: Border(
                  left: BorderSide(color: Color(0xFF07C160), width: 3)),
              color: Color(0xFFF6F8F7),
              borderRadius:
                  BorderRadius.horizontal(right: Radius.circular(8)),
            ),
            child: _selectableText(i, b,
                style: const TextStyle(
                    fontSize: 15, height: 1.8, color: Colors.black54)),
          ),
        );
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final lvl = int.parse(b.type.substring(1));
        final size = [0.0, 22.0, 20.0, 18.5, 17.0, 16.0, 16.0][lvl];
        return _wrap(
          i,
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 4),
            child: _selectableText(i, b,
                style: TextStyle(
                    fontSize: size,
                    height: 1.5,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF1F2329))),
          ),
        );
      default: // p
        return _wrap(
          i,
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _selectableText(i, b),
          ),
        );
    }
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    final art = _art;
    if (art == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(art.author.isEmpty ? '阅读' : art.author,
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: Icon(
              art.favorite == 1 ? Icons.star : Icons.star_border,
              color: art.favorite == 1 ? Colors.amber : null,
            ),
            onPressed: _toggleFav,
          ),
          IconButton(
            icon: Badge(
              isLabelVisible: _hls.isNotEmpty,
              label: Text('${_hls.length}'),
              child: const Icon(Icons.border_color_outlined),
            ),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
          IconButton(icon: const Icon(Icons.ios_share), onPressed: _export),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'cat') _pickCategory();
              if (v == 'orig') _openOriginal();
              if (v == 'del') _delete();
            },
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'cat', child: Text('移动到分类')),
              PopupMenuItem(value: 'orig', child: Text('在浏览器打开原文')),
              PopupMenuItem(
                  value: 'del',
                  child: Text('删除', style: TextStyle(color: Colors.red))),
            ],
          ),
        ],
      ),
      endDrawer: Drawer(
        child: Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB)))),
            child: Text('本文标记（${_hls.length}）',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          ),
          Expanded(
            child: _hls.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('还没有标记\n\n在正文中长按并拖选文字，\n弹出菜单里选颜色即可高亮',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade500, height: 1.8)),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _hls.length,
                    itemBuilder: (ctx, i) {
                      final h = _hls[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _jumpTo(h),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            border: Border.all(color: const Color(0xFFE5E7EB)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        width: 12,
                                        height: 12,
                                        margin: const EdgeInsets.only(top: 4, right: 8),
                                        decoration: BoxDecoration(
                                          color: _hlColors[h.color] ??
                                              const Color(0x66F2C94C),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(h.text,
                                            maxLines: 4,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 13.5, height: 1.6)),
                                      ),
                                    ]),
                                if (h.note.isNotEmpty)
                                  Container(
                                    width: double.infinity,
                                    margin: const EdgeInsets.only(top: 8),
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF6F7F8),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(h.note,
                                        style: const TextStyle(
                                            fontSize: 12.5,
                                            height: 1.6,
                                            color: Colors.black87)),
                                  ),
                              ]),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        itemCount: _blocks.length + 2,
        itemBuilder: (ctx, idx) {
          if (idx == 0) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(art.title,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700, height: 1.45)),
              const SizedBox(height: 10),
              Row(children: [
                if (art.author.isNotEmpty)
                  Text('✍️ ${art.author}',
                      style: const TextStyle(fontSize: 12.5, color: Colors.grey)),
                if (art.author.isNotEmpty && art.publishTime.isNotEmpty)
                  const Text('  ·  ',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey)),
                if (art.publishTime.isNotEmpty)
                  Text(art.publishTime,
                      style: const TextStyle(fontSize: 12.5, color: Colors.grey)),
                if (art.url.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _openOriginal,
                    child: const Text('查看原文 ↗',
                        style: TextStyle(
                            fontSize: 12.5, color: Color(0xFF0F7BFF))),
                  ),
                ],
              ]),
              const Divider(height: 28),
            ]);
          }
          if (idx == 1) return const SizedBox.shrink();
          return _buildBlock(idx - 2);
        },
      ),
    );
  }
}

class _Run {
  final String text;
  final TextStyle style;
  final String? href;
  _Run(this.text, this.style, this.href);
}
