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
        ),
      ),
    );
    if (sel == null) return;
    await DB.updateArticle(a.id!, {'category_id': sel == -1 ? null : sel});
    await _refresh();
  }

  // ---------------- 菜单 ----------------
  Future<void> _onMenu(String v) async {
    switch (v) {
      case 'paste':
        final id = await Navigator.push<int>(
            context, MaterialPageRoute(builder: (_) => const PasteScreen()));
        if (id != null) {
          await _refresh();
          await _openArticle(id);
        }
        break;
      case 'cats':
        await Navigator.push(context,
            MaterialPageRoute(builder: (_) => const CategoriesScreen()));
        await _refresh();
        break;
      case 'about':
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('关于微阅'),
            content: const Text('微阅 v1.0\n\n在手机上阅读、收藏和管理微信公众号文章。\n所有数据都保存在你的手机本地。'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('好的')),
            ],
          ),
        );
        break;
    }
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: '搜索标题 / 作者 / 正文', border: InputBorder.none),
                onChanged: (v) {
                  _q = v;
                  _refresh();
                },
              )
            : const Text('微阅', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() => _searching = !_searching);
              if (!_searching) {
                _q = '';
                _refresh();
              }
            },
          ),
          IconButton(icon: const Icon(Icons.add_link), onPressed: _importUrl),
          PopupMenuButton<String>(
            onSelected: _onMenu,
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: 'paste', child: Text('粘贴全文导入')),
              PopupMenuItem(value: 'cats', child: Text('管理分类')),
              PopupMenuItem(value: 'about', child: Text('关于微阅')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        _filterBar(),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _articles.isEmpty
                  ? _empty()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
                      itemCount: _articles.length,
                      itemBuilder: (ctx, i) {
                        final a = _articles[i];
                        final cat = _categories.where((c) => c.id == a.categoryId);
                        return _ArticleCard(
                          a: a,
                          catName: cat.isEmpty ? null : cat.first.name,
                          onTap: () => _openArticle(a.id!),
                          onLongPress: () => _showArticleActions(a),
                          onStar: () => _toggleStar(a),
                        );
                      },
                    ),
        ),
      ]),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF07C160),
        foregroundColor: Colors.white,
        onPressed: _importUrl,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _filterBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: const Text('全部'),
            selected: !_favOnly && _filterCat == null,
            onSelected: (_) {
              setState(() {
                _favOnly = false;
                _filterCat = null;
              });
              _refresh();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            label: const Text('⭐ 收藏'),
            selected: _favOnly,
            onSelected: (_) {
              setState(() {
                _favOnly = !_favOnly;
                _filterCat = null;
              });
              _refresh();
            },
          ),
        ),
        for (final c in _categories)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(c.name),
              selected: _filterCat == c.id,
              onSelected: (_) {
                setState(() {
                  _favOnly = false;
                  _filterCat = _filterCat == c.id ? null : c.id;
                });
                _refresh();
              },
            ),
          ),
      ]),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.newspaper, size: 52, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('还没有文章', style: TextStyle(fontSize: 16, color: Colors.grey.shade600)),
          const SizedBox(height: 6),
          Text('点右下角 + 粘贴文章链接导入',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
        ],
      ),
    );
  }
}

// ---------------- 文章卡片 ----------------
class _ArticleCard extends StatelessWidget {
  final Article a;
  final String? catName;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onStar;

  const _ArticleCard({
    required this.a,
    this.catName,
    required this.onTap,
    required this.onLongPress,
    required this.onStar,
  });

  @override
  Widget build(BuildContext context) {
    final excerpt =
        a.contentText.replaceAll(RegExp(r'\s+'), ' ').trim();
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            _cover(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.4)),
                const SizedBox(height: 4),
                Text(
                  [a.author, a.publishTime].where((s) => s.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                if (excerpt.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(excerpt,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600, height: 1.5)),
                ],
                if (catName != null) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                        color: const Color(0xFFE8F7EE),
                        borderRadius: BorderRadius.circular(99)),
                    child: Text(catName!,
                        style: const TextStyle(fontSize: 11, color: Color(0xFF059669))),
                  ),
                ],
              ]),
            ),
            IconButton(
              icon: Icon(
                a.favorite == 1 ? Icons.star : Icons.star_border,
                color: a.favorite == 1 ? Colors.amber : Colors.grey.shade400,
                size: 22,
              ),
              onPressed: onStar,
            ),
          ]),
        ),
      ),
    );
  }

  Widget _cover() {
    if (a.cover.isEmpty) {
      return Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
            color: const Color(0xFFF0F1F3), borderRadius: BorderRadius.circular(10)),
        child: const Icon(Icons.article_outlined, color: Colors.grey),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        a.cover,
        width: 60,
        height: 60,
        fit: BoxFit.cover,
        headers: const {'Referer': 'https://mp.weixin.qq.com/'},
        errorBuilder: (c, e, s) => Container(
          width: 60,
          height: 60,
          color: const Color(0xFFF0F1F3),
          child: const Icon(Icons.article_outlined, color: Colors.grey),
        ),
      ),
    );
  }
}

// ---------------- 粘贴全文导入（兜底） ----------------
class PasteScreen extends StatefulWidget {
  const PasteScreen({super.key});
  @override
  State<PasteScreen> createState() => _PasteScreenState();
}

class _PasteScreenState extends State<PasteScreen> {
  final _title = TextEditingController();
  final _author = TextEditingController();
  final _url = TextEditingController();
  final _text = TextEditingController();
  bool _saving = false;

  Future<void> _save() async {
    final paras = _text.text
        .split(RegExp(r'\n\s*\n'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (paras.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请粘贴正文内容')));
      return;
    }
    setState(() => _saving = true);
    final blocks = paras.map((p) => Block('p', escHtml(p))).toList();
    final art = Article(
      id: null,
      articleKey: 'manual-${DateTime.now().millisecondsSinceEpoch}',
      title: _title.text.trim().isEmpty ? '未命名文章' : _title.text.trim(),
      author: _author.text.trim(),
      url: _url.text.trim(),
      cover: '',
      publishTime: '',
      blocksJson: jsonEncode(blocks.map((b) => b.toJson()).toList()),
      contentText: paras.join('\n\n'),
      categoryId: null,
      favorite: 0,
      createdAt: DateTime.now().toIso8601String(),
    );
    final id = await DB.insertArticle(art);
    if (!mounted) return;
    Navigator.pop(context, id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('粘贴全文导入'),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : TextButton(onPressed: _save, child: const Text('导入')),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
            controller: _title,
            decoration: const InputDecoration(
                labelText: '标题', border: OutlineInputBorder(), isDense: true)),
        const SizedBox(height: 12),
        TextField(
            controller: _author,
            decoration: const InputDecoration(
                labelText: '作者 / 来源（可选）', border: OutlineInputBorder(), isDense: true)),
        const SizedBox(height: 12),
        TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
                labelText: '原文链接（可选）', border: OutlineInputBorder(), isDense: true)),
        const SizedBox(height: 12),
        TextField(
          controller: _text,
          maxLines: null,
          minLines: 12,
          decoration: const InputDecoration(
            labelText: '正文（段落之间用空行分隔）',
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 8),
        Text('提示：自动抓取失败时用这个兜底。先全选复制文章文字，到这里粘贴即可。',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
      ]),
    );
  }
}

// ---------------- 分类管理 ----------------
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});
  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  List<Category> _cats = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final cats = await DB.categories();
    if (!mounted) return;
    setState(() {
      _cats = cats;
      _loading = false;
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _add() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建分类'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：技术 / 生活 / 写作', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('创建')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await DB.addCategory(name);
      await _refresh();
    } catch (_) {
      _toast('分类「$name」已存在');
    }
  }

  Future<void> _rename(Category c) async {
    final ctrl = TextEditingController(text: c.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分类'),
        content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await DB.renameCategory(c.id, name);
      await _refresh();
    } catch (_) {
      _toast('分类「$name」已存在');
    }
  }

  Future<void> _delete(Category c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('删除分类「${c.name}」？\n分类下的文章会变为未分类，不会被删除。'),
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
    await DB.deleteCategory(c.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('管理分类')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF07C160),
        foregroundColor: Colors.white,
        onPressed: _add,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _cats.isEmpty
              ? Center(
                  child: Text('还没有分类\n点右下角 ＋ 新建',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade500, height: 1.8)))
              : ListView.builder(
                  itemCount: _cats.length,
                  itemBuilder: (ctx, i) {
                    final c = _cats[i];
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(c.name),
                      subtitle: Text('${c.count} 篇'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () => _rename(c)),
                        IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
                            onPressed: () => _delete(c)),
                      ]),
                    );
                  },
                ),
    );
  }
}
