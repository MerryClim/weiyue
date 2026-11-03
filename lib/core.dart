// 微阅核心：数据模型 / 本地数据库 / 微信文章抓取与解析 / 高亮分段算法 / Markdown 导出
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

// ---------------- 小工具 ----------------
String escHtml(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String escAttr(String s) => escHtml(s).replaceAll('"', '&quot;');

// ---------------- 模型 ----------------
class Article {
  int? id;
  final String articleKey;
  String title;
  String author;
  String url;
  String cover;
  String publishTime;
  String blocksJson;
  String contentText;
  int? categoryId;
  int favorite;
  String createdAt;

  Article({
    this.id,
    required this.articleKey,
    required this.title,
    this.author = '',
    this.url = '',
    this.cover = '',
    this.publishTime = '',
    required this.blocksJson,
    required this.contentText,
    this.categoryId,
    this.favorite = 0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'article_key': articleKey,
        'title': title,
        'author': author,
        'source': '微信公众号',
        'url': url,
        'cover': cover,
        'publish_time': publishTime,
        'blocks_json': blocksJson,
        'content_text': contentText,
        'category_id': categoryId,
        'favorite': favorite,
        'created_at': createdAt,
      };

  factory Article.fromMap(Map<String, dynamic> m) => Article(
        id: m['id'] as int?,
        articleKey: (m['article_key'] ?? '') as String,
        title: (m['title'] ?? '') as String,
        author: (m['author'] ?? '') as String,
        url: (m['url'] ?? '') as String,
        cover: (m['cover'] ?? '') as String,
        publishTime: (m['publish_time'] ?? '') as String,
        blocksJson: (m['blocks_json'] ?? '[]') as String,
        contentText: (m['content_text'] ?? '') as String,
        categoryId: m['category_id'] as int?,
        favorite: (m['favorite'] ?? 0) as int,
        createdAt: (m['created_at'] ?? '') as String,
      );
}

class Category {
  final int id;
  final String name;
  int count;
  Category(this.id, this.name, [this.count = 0]);
  factory Category.fromMap(Map<String, dynamic> m) =>
      Category(m['id'] as int, (m['name'] ?? '') as String, (m['count'] ?? 0) as int);
}

class Highlight {
  int? id;
  final int articleId;
  final int start;
  final int end;
  final String text;
  String note;
  final String color;

  Highlight({
    this.id,
    required this.articleId,
    required this.start,
    required this.end,
    required this.text,
    this.note = '',
    this.color = 'yellow',
  });

  Map<String, dynamic> toMap() => {
        'article_id': articleId,
        'start': start,
        'end': end,
        'text': text,
        'note': note,
        'color': color,
        'created_at': DateTime.now().toIso8601String(),
      };

  factory Highlight.fromMap(Map<String, dynamic> m) => Highlight(
        id: m['id'] as int?,
        articleId: m['article_id'] as int,
        start: m['start'] as int,
        end: m['end'] as int,
        text: (m['text'] ?? '') as String,
        note: (m['note'] ?? '') as String,
        color: (m['color'] ?? 'yellow') as String,
      );
}

/// 正文块：p / h1..h6 / quote / li / pre / img / video
class Block {
  final String type;
  final String html; // 文本类块的行内 html
  final String src; // li: 'ul'|'ol'；img: 图片地址

  Block(this.type, this.html, [this.src = '']);

  String get text => hp.parseFragment(html).text ?? '';

  Map<String, dynamic> toJson() => {'t': type, 'h': html, 's': src};

  static Block fromJson(Map<String, dynamic> j) =>
      Block((j['t'] ?? 'p') as String, (j['h'] ?? '') as String, (j['s'] ?? '') as String);
}

List<Block> decodeBlocks(String blocksJson) {
  try {
    final list = jsonDecode(blocksJson) as List;
    return list.map((e) => Block.fromJson(e as Map<String, dynamic>)).toList();
  } catch (_) {
    return [];
  }
}

// ---------------- 数据库 ----------------
class DB {
  DB._();
  static Database? _db;

  static Future<Database> get db async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'weiyue.db');
    _db = await openDatabase(
      path,
      version: 1,
      onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      onCreate: (d, v) async {
        await d.execute('''
          CREATE TABLE categories(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL)''');
        await d.execute('''
          CREATE TABLE articles(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            article_key TEXT UNIQUE,
            title TEXT NOT NULL,
            author TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT '',
            url TEXT NOT NULL DEFAULT '',
            cover TEXT NOT NULL DEFAULT '',
            publish_time TEXT NOT NULL DEFAULT '',
            blocks_json TEXT NOT NULL,
            content_text TEXT NOT NULL,
            category_id INTEGER,
            favorite INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            FOREIGN KEY(category_id) REFERENCES categories(id) ON DELETE SET NULL)''');
        await d.execute('''
          CREATE TABLE highlights(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            article_id INTEGER NOT NULL,
            start INTEGER NOT NULL,
            end INTEGER NOT NULL,
            text TEXT NOT NULL,
            note TEXT NOT NULL DEFAULT '',
            color TEXT NOT NULL DEFAULT 'yellow',
            created_at TEXT NOT NULL,
            FOREIGN KEY(article_id) REFERENCES articles(id) ON DELETE CASCADE)''');
        await d.execute('CREATE INDEX idx_hl_article ON highlights(article_id)');
      },
    );
    return _db!;
  }

  // 分类
  static Future<List<Category>> categories() async {
    final d = await db;
    final rows = await d.rawQuery('''
      SELECT c.id, c.name, COUNT(a.id) AS count
      FROM categories c LEFT JOIN articles a ON a.category_id = c.id
      GROUP BY c.id ORDER BY c.created_at, c.id''');
    return rows.map(Category.fromMap).toList();
  }

  static Future<int> addCategory(String name) async {
    final d = await db;
    return d.insert('categories',
        {'name': name, 'created_at': DateTime.now().toIso8601String()});
  }

  static Future<void> renameCategory(int id, String name) async {
    final d = await db;
    await d.update('categories', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteCategory(int id) async {
    final d = await db;
    await d.delete('categories', where: 'id = ?', whereArgs: [id]);
  }

  // 文章
  static Future<List<Article>> articles(
      {String q = '', int? categoryId, bool favOnly = false}) async {
    final d = await db;
    final where = <String>[];
    final args = <Object>[];
    if (q.isNotEmpty) {
      where.add('(title LIKE ? OR author LIKE ? OR content_text LIKE ?)');
      args.addAll(['%$q%', '%$q%', '%$q%']);
    }
    if (categoryId != null) {
      where.add('category_id = ?');
      args.add(categoryId);
    }
    if (favOnly) where.add('favorite = 1');
    final rows = await d.query(
      'articles',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(Article.fromMap).toList();
  }

  static Future<int> insertArticle(Article a) async {
    final d = await db;
    return d.insert('articles', a.toMap());
  }

  static Future<Article?> article(int id) async {
    final d = await db;
    final rows = await d.query('articles', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Article.fromMap(rows.first);
  }

  static Future<Article?> findByKey(String key) async {
    final d = await db;
    final rows =
        await d.query('articles', where: 'article_key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return Article.fromMap(rows.first);
  }

  static Future<void> updateArticle(int id, Map<String, dynamic> fields) async {
    final d = await db;
    await d.update('articles', fields, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteArticle(int id) async {
    final d = await db;
    await d.delete('articles', where: 'id = ?', whereArgs: [id]);
  }

  // 标记
  static Future<List<Highlight>> highlights(int articleId) async {
    final d = await db;
    final rows = await d.query('highlights',
        where: 'article_id = ?', whereArgs: [articleId], orderBy: 'start');
    return rows.map(Highlight.fromMap).toList();
  }

  static Future<Highlight> addHighlight(Highlight h) async {
    final d = await db;
    final id = await d.insert('highlights', h.toMap());
    return Highlight(
        id: id,
        articleId: h.articleId,
        start: h.start,
        end: h.end,
        text: h.text,
        note: h.note,
        color: h.color);
  }

  static Future<void> updateHighlight(int id, Map<String, dynamic> fields) async {
    final d = await db;
    await d.update('highlights', fields, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> deleteHighlight(int id) async {
    final d = await db;
    await d.delete('highlights', where: 'id = ?', whereArgs: [id]);
  }
}

// ---------------- 微信文章抓取 ----------------
class FetchError implements Exception {
  final String message;
  FetchError(this.message);
  @override
  String toString() => message;
}

const _ua =
    'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

const _skipTags = {
  'script', 'style', 'svg', 'button', 'input', 'textarea', 'form',
  'link', 'meta', 'title', 'noscript', 'video', 'canvas', 'audio', 'template',
};

bool _looksLikeAd(dom.Element el) {
  final cls = (el.attributes['class'] ?? '').toLowerCase();
  final id = (el.attributes['id'] ?? '').toLowerCase();
  const keys = [
    'advert', 'reward', 'qrcode', 'qr_code', 'js_ad', 'rich_media_tool',
    'rich_media_area_extra', 'profile', 'mpda', 'purchase', 'promotion',
  ];
  for (final k in keys) {
    if (cls.contains(k) || id.contains(k)) return true;
  }
  return false;
}

String? _imgSrc(dom.Element img) {
  var src = img.attributes['data-src'] ?? img.attributes['src'] ?? '';
  if (src.startsWith('//')) src = 'https:$src';
  if (!src.startsWith('http')) return null;
  return src;
}

/// 把元素转成只含行内标签的 html（b/i/a/br/code）
String _inlineHtml(dom.Element el) {
  final buf = StringBuffer();
  for (final node in el.nodes) {
    if (node is dom.Text) {
      buf.write(escHtml(node.text));
    } else if (node is dom.Element) {
      final tag = node.localName ?? '';
      if (tag == 'br') {
        buf.write('\n');
      } else if (tag == 'a') {
        final href = node.attributes['href'] ?? '';
        if (href.startsWith('http')) {
          buf.write('<a href="${escAttr(href)}">${_inlineHtml(node)}</a>');
        } else {
          buf.write(_inlineHtml(node));
        }
      } else if (tag == 'b' || tag == 'strong') {
        buf.write('<b>${_inlineHtml(node)}</b>');
      } else if (tag == 'i' || tag == 'em') {
        buf.write('<i>${_inlineHtml(node)}</i>');
      } else if (tag == 'code') {
        buf.write('<code>${_inlineHtml(node)}</code>');
      } else if (tag == 'img') {
        // 行内图片单独成块处理，这里丢弃
      } else {
        buf.write(_inlineHtml(node));
      }
    }
  }
  return buf.toString();
}

void _walk(dom.Element el, List<Block> blocks, String listType) {
  for (final node in el.nodes) {
    if (node is dom.Text) {
      final t = node.text.trim();
      if (t.isNotEmpty) blocks.add(Block('p', escHtml(t)));
      continue;
    }
    if (node is! dom.Element) continue;
    final tag = (node.localName ?? '').toLowerCase();
    if (_skipTags.contains(tag) || tag.startsWith('mp-') || _looksLikeAd(node)) {
      continue;
    }
    if (tag == 'img') {
      final src = _imgSrc(node);
      if (src != null) blocks.add(Block('img', '', src));
    } else if (tag == 'iframe') {
      blocks.add(Block('video', '🎥 本文包含视频，请在原文中观看'));
    } else if (tag == 'p') {
      final h = _inlineHtml(node);
      if ((hp.parseFragment(h).text ?? '').trim().isNotEmpty) {
        blocks.add(Block('p', h));
      } else {
        for (final im in node.querySelectorAll('img')) {
          final src = _imgSrc(im);
          if (src != null) blocks.add(Block('img', '', src));
        }
      }
    } else if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
      final h = _inlineHtml(node);
      if ((hp.parseFragment(h).text ?? '').trim().isNotEmpty) blocks.add(Block(tag, h));
    } else if (tag == 'blockquote') {
      final h = _inlineHtml(node);
      if ((hp.parseFragment(h).text ?? '').trim().isNotEmpty) blocks.add(Block('quote', h));
    } else if (tag == 'pre') {
      if (node.text.trim().isNotEmpty) blocks.add(Block('pre', escHtml(node.text)));
    } else if (tag == 'ul' || tag == 'ol') {
      for (final child in node.children) {
        if (child.localName == 'li') {
          final h = _inlineHtml(child);
          if ((hp.parseFragment(h).text ?? '').trim().isNotEmpty) blocks.add(Block('li', h, tag));
        } else {
          _walk(child, blocks, tag);
        }
      }
    } else if (tag == 'li') {
      final h = _inlineHtml(node);
      if ((hp.parseFragment(h).text ?? '').trim().isNotEmpty) {
        blocks.add(Block('li', h, listType.isEmpty ? 'ul' : listType));
      }
    } else {
      _walk(node, blocks, listType);
    }
  }
}

Future<Article> fetchWechatArticle(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.host.toLowerCase().endsWith('weixin.qq.com')) {
    throw FetchError('仅支持 mp.weixin.qq.com 的公众号文章链接');
  }
  final resp = await http.get(uri, headers: {
    'User-Agent': _ua,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    'Referer': 'https://mp.weixin.qq.com/',
  }).timeout(const Duration(seconds: 25));
  if (resp.statusCode != 200) {
    throw FetchError('请求失败（${resp.statusCode}），请稍后重试');
  }
  final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
  if (!text.contains('js_content')) {
    if (text.contains('环境异常') || text.contains('验证')) {
      throw FetchError('微信要求安全验证：请先在微信里正常打开一次这篇文章，再回来重试');
    }
    throw FetchError('未获取到文章内容，链接可能无效或文章已被删除');
  }
  final doc = hp.parse(text);
  final content = doc.querySelector('#js_content');
  if (content == null) throw FetchError('页面中没有找到正文');

  String title = '';
  for (final sel in ['#activity-name', '.rich_media_title']) {
    final el = doc.querySelector(sel);
    if (el != null && el.text.trim().isNotEmpty) {
      title = el.text.trim().replaceAll('\u200b', '');
      break;
    }
  }
  if (title.isEmpty) {
    for (final m in doc.querySelectorAll('meta')) {
      if (m.attributes['property'] == 'og:title') {
        title = (m.attributes['content'] ?? '').trim();
        if (title.isNotEmpty) break;
      }
    }
  }
  if (title.isEmpty) title = '未命名文章';

  String author = '';
  for (final sel in ['#js_author_name', '#js_name', '.rich_media_meta_nickname']) {
    final el = doc.querySelector(sel);
    if (el != null && el.text.trim().isNotEmpty) {
      author = el.text.trim();
      break;
    }
  }

  String pubTime = '';
  final pt = doc.querySelector('#publish_time');
  if (pt != null) pubTime = pt.text.trim();
  if (pubTime.isEmpty) {
    final m = RegExp("var\\s+ct\\s*=\\s*['\"](\\d{10})['\"]").firstMatch(text);
    if (m != null) {
      final ts = int.tryParse(m.group(1)!);
      if (ts != null) {
        final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000);
        pubTime = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      }
    }
  }

  String cover = '';
  for (final m in doc.querySelectorAll('meta')) {
    if (m.attributes['property'] == 'og:image') {
      var c = m.attributes['content'] ?? '';
      if (c.startsWith('//')) c = 'https:$c';
      if (c.startsWith('http')) cover = c;
      break;
    }
  }

  final blocks = <Block>[];
  _walk(content, blocks, '');
  if (blocks.isEmpty) throw FetchError('正文内容为空，无法导入');
  final contentText = blocks
      .where((b) => b.text.trim().isNotEmpty)
      .map((b) => b.text)
      .join('\n\n');

  final key = RegExp(r'/s/([0-9A-Za-z_\-]{3,})').firstMatch(url)?.group(1) ??
      Uri.parse(url).queryParameters['sn'] ??
      'manual-${DateTime.now().millisecondsSinceEpoch}';

  return Article(
    id: null,
    articleKey: key,
    title: title,
    author: author,
    url: url,
    cover: cover,
    publishTime: pubTime,
    blocksJson: jsonEncode(blocks.map((b) => b.toJson()).toList()),
    contentText: contentText,
    categoryId: null,
    favorite: 0,
    createdAt: DateTime.now().toIso8601String(),
  );
}

// ---------------- 高亮分段算法（纯函数，可单测） ----------------
class Seg {
  final int from;
  final int to;
  final Highlight? hl;
  Seg(this.from, this.to, this.hl);
}

/// 把长度为 len 的文本按高亮区间（本段内偏移）切成片段
List<Seg> splitText(int len, List<Highlight> hls) {
  var segs = <Seg>[Seg(0, len, null)];
  for (final hl in hls) {
    final s = hl.start < 0 ? 0 : hl.start;
    final e = hl.end > len ? len : hl.end;
    if (s >= e) continue;
    final next = <Seg>[];
    for (final seg in segs) {
      if (e <= seg.from || s >= seg.to) {
        next.add(seg);
        continue;
      }
      if (s > seg.from) next.add(Seg(seg.from, s, seg.hl));
      next.add(Seg(s > seg.from ? s : seg.from, e < seg.to ? e : seg.to, hl));
      if (e < seg.to) next.add(Seg(e, seg.to, seg.hl));
    }
    segs = next;
  }
  return segs.where((x) => x.to > x.from).toList();
}

// ---------------- Markdown 导出 ----------------
String _inlineMd(String html) {
  final frag = hp.parseFragment(html);
  final buf = StringBuffer();
  void walk(dom.Node node, {bool strong = false, bool em = false, bool code = false}) {
    if (node is dom.Text) {
      var t = node.text;
      if (code) {
        t = '`$t`';
      } else {
        if (em) t = '*$t*';
        if (strong) t = '**$t**';
      }
      buf.write(t);
    } else if (node is dom.Element) {
      final tag = node.localName ?? '';
      var s2 = strong, e2 = em, c2 = code;
      if (tag == 'b' || tag == 'strong') s2 = true;
      if (tag == 'i' || tag == 'em') e2 = true;
      if (tag == 'code') c2 = true;
      if (tag == 'a') {
        final href = node.attributes['href'] ?? '';
        buf.write('[');
        for (final c in node.nodes) {
          walk(c, strong: s2, em: e2, code: c2);
        }
        buf.write(']($href)');
      } else {
        for (final c in node.nodes) {
          walk(c, strong: s2, em: e2, code: c2);
        }
      }
    }
  }

  for (final n in frag.nodes) {
    walk(n);
  }
  return buf.toString();
}

String exportMarkdown(Article a, List<Block> blocks) {
  final lines = <String>['# ${a.title}', ''];
  final meta = <String>[];
  if (a.author.isNotEmpty) meta.add('作者：${a.author}');
  if (a.publishTime.isNotEmpty) meta.add('发布时间：${a.publishTime}');
  if (a.url.isNotEmpty) meta.add('原文链接：${a.url}');
  lines.add(meta.join('  \n'));
  lines.add('---');
  int olCount = 0;
  for (final b in blocks) {
    switch (b.type) {
      case 'img':
        lines.add('![](${b.src})');
        break;
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        lines.add('${'#' * int.parse(b.type.substring(1))} ${_inlineMd(b.html)}');
        break;
      case 'quote':
        lines.add('> ${_inlineMd(b.html)}');
        break;
      case 'pre':
        lines.add('```\n${b.text}\n```');
        break;
      case 'li':
        if (b.src == 'ol') {
          olCount++;
          lines.add('$olCount. ${_inlineMd(b.html)}');
        } else {
          olCount = 0;
          lines.add('- ${_inlineMd(b.html)}');
        }
        break;
      case 'video':
        lines.add('> 🎥 本文包含视频，请到原文观看');
        break;
      default:
        lines.add(_inlineMd(b.html));
        break;
    }
    lines.add('');
  }
  return lines.join('\n');
}
