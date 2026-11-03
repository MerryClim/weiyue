// 微阅 - 微信公众号文章本地阅读器
// 入口 + 首页（列表 / 搜索 / 分类筛选 / 导入 / 粘贴导入 / 分类管理）
import 'dart:convert';

import 'package:flutter/material.dart';

import 'core.dart';
import 'reader.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WeiyueApp());
}

class WeiyueApp extends StatelessWidget {
  const WeiyueApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '微阅',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF07C160)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF4F5F7),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Article> _articles = [];
  List<Category> _categories = [];
  int? _filterCat;
  bool _favOnly = false;
  String _q = '';
  bool _searching = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final arts = await DB.articles(q: _q, categoryId: _filterCat, favOnly: _favOnly);
      final cats = await DB.categories();
      if (!mounted) return;
      setState(() {
        _articles = arts;
        _categories = cats;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取数据失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _openArticle(int id) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderScreen(articleId: id)));
    await _refresh();
  }

  // ---------------- 导入 ----------------
  Future<void> _importUrl() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入文章'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 3,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '粘贴公众号文章链接\n如 https://mp.weixin.qq.com/s/…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('导入')),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('正在抓取文章…'),
            ]),
          ),
        ),
      ),
    );
    try {
      final art = await fetchWechatArticle(url);
      if (!mounted) return;
      Navigator.pop(context); // 关闭 loading
      final exist = await DB.findByKey(art.articleKey);
      if (exist != null) {
        _toast('这篇文章已经在阅读库中');
        await _openArticle(exist.id!);
        return;
      }
      final id = await DB.insertArticle(art);
      await _refresh();
      await _openArticle(id);
    } on FetchError catch (e) {
      if (mounted) {
        Navigator.pop(context);
        _toast(e.message);
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        _toast('导入失败：$e');
      }
    }
  }

  // ---------------- 卡片操作 ----------------
  Future<void> _toggleStar(Article a) async {
    final v = a.favorite == 1 ? 0 : 1;
    await DB.updateArticle(a.id!, {'favorite': v});
    await _refresh();
  }

  void _showArticleActions(Article a) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Icon(a.favorite == 1 ? Icons.star_border : Icons.star),
            title: Text(a.favorite == 1 ? '取消收藏' : '收藏'),
            onTap: () async {
              Navigator.pop(ctx);
              await _toggleStar(a);
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('移动到分类'),
            onTap: () async {
              Navigator.pop(ctx);
              await _pickCategory(a);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('删除', style: TextStyle(color: Colors.red)),
            onTap: () async {
              Navigator.pop(ctx);
              final ok = await _confirm('删除这篇文章？标记和笔记会一并删除。');
              if (!ok) return;
              await DB.deleteArticle(a.id!);
              await _refresh();
              _toast('已删除');
            },
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }

  Future<bool> _confirm(String msg) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _pickCategory(Article a) async {
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
            for (final c in _categories)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(c.name),
                trailing: a.categoryId == c.id ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(ctx, c.id),
              ),
            const SizedBox(height: 8),
          ],
   
