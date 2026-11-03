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
