import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_static/shelf_static.dart';
import 'package:sqflite/sqflite.dart';

class LocalEnvironment {
 LocalEnvironment._(); static final instance=LocalEnvironment._();
 Directory? root; HttpServer? _server; Database? database; final List<String> logs=[]; int port=8080;
 bool get webRunning=>_server!=null; bool get sqliteReady=>database!=null;
 Future<void> initialize() async { if(root!=null)return; final docs=await getApplicationDocumentsDirectory(); root=Directory(p.join(docs.path,'PALLSQL')); for(final d in ['htdocs','projects','database','backups','logs','config','tmp']) { await Directory(p.join(root!.path,d)).create(recursive:true); } final index=File(p.join(root!.path,'htdocs','index.html')); if(!await index.exists()) await index.writeAsString('<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>PALLSQL</title></head><body style="font:16px sans-serif;background:#090b0a;color:#a3ff12;padding:2rem"><h1>PALLSQL is ready</h1><p>Your local project is being served from htdocs.</p></body></html>'); database=await openDatabase(p.join(root!.path,'database','default.db'),version:1,onCreate:(db,v)=>db.execute('CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, created_at TEXT NOT NULL)')); log('INFO','APP','Workspace initialized'); }
 Future<void> startServer({int? requestedPort}) async { await initialize(); if(webRunning)return; final wanted=requestedPort??port; final handler=Pipeline().addMiddleware(logRequests()).addHandler((request) async { final relative=request.url.path; if(relative.split('/').any((part)=>part=='..')) return Response.forbidden('Path traversal blocked'); final normalized=relative.isEmpty?'index.html':relative; final base=p.normalize(root!.path+'/htdocs'); final target=p.normalize(p.join(base, Uri.decodeComponent(normalized))); if(target!=base && !p.isWithin(base,target)) return Response.forbidden('Path traversal blocked'); var file=File(target); if(await file.exists() && await file.stat().then((s)=>s.type==FileSystemEntityType.directory)) file=File(p.join(target,'index.html')); if(!await file.exists()) return Response.notFound('Not found'); log('INFO','WEB','${request.method} /$relative'); return createStaticHandler(base, defaultDocument:'index.html')(request); });
 try { _server=await io.serve(handler,InternetAddress.loopbackIPv4,wanted,shared:false); port=_server!.port; log('INFO','WEB','Listening on 127.0.0.1:$port'); } on SocketException catch(e) { log('ERROR','WEB','Could not bind port $wanted: $e'); rethrow; } }
 Future<void> stopServer() async { final s=_server; if(s==null)return; _server=null; await s.close(force:true); log('INFO','WEB','Server stopped'); }
 Future<List<FileSystemEntity>> listFiles(String relative) async { await initialize(); final base=p.join(root!.path,'htdocs'); final path=p.normalize(p.join(base,relative)); if(!p.isWithin(base,path) && path!=base) throw const FileSystemException('Path outside document root'); return Directory(path).list(followLinks:false).toList(); }
 Future<void> createFile(String name,{bool directory=false}) async { await initialize(); if(name.trim().isEmpty||p.isAbsolute(name)||name.split(RegExp(r'[/\\]')).contains('..')) throw const FormatException('Invalid file name'); final path=p.join(root!.path,'htdocs',name); final entity=directory?Directory(path):File(path); if(directory){await (entity as Directory).create(recursive:true);}else{await (entity as File).create(recursive:true);} log('INFO','FILES','Created $name'); }
 Future<List<Map<String,Object?>>> query(String sql) async { await initialize(); final trimmed=sql.trim(); if(trimmed.isEmpty) throw const FormatException('Enter a SQL statement'); final db=database!; final verb=trimmed.split(RegExp(r'\s+')).first.toUpperCase(); try { if(['SELECT','PRAGMA','EXPLAIN','WITH'].contains(verb)) return await db.rawQuery(trimmed); await db.execute(trimmed); return []; } catch(e){log('ERROR','DATABASE','SQL failed: $e'); rethrow;} }
 void log(String level,String service,String message){final line='${DateTime.now().toIso8601String()}  $level  $service  $message'; logs.insert(0,line); if(logs.length>300)logs.removeLast(); }
}
