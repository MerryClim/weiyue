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
    if (q.isNotE
