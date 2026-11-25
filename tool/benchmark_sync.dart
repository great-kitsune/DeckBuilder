// Replay one captured /cards/all response and numbered search pages without
// contacting the API. Use a new benchmark directory, never an installed DB.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';

void monitor((String, SendPort) args) async {
  final (path, port) = args;
  final stop = ReceivePort();
  var done = false;
  stop.listen((_) {
    done = true;
  });
  port.send(stop.sendPort);
  var peak = 0;
  while (!done) {
    var total = 0;
    try {
      for (final e in Directory(path).listSync()) {
        if (e is Directory && e.path.contains('.sync-')) {
          for (final f in e.listSync()) {
            if (f is File) total += f.lengthSync();
          }
        } else if (e is File && e.path.endsWith('.incoming')) {
          total += e.lengthSync();
        }
      }
    } on FileSystemException {
      /* Worker may unlink a stage between list and stat. */
    }
    if (total > peak) peak = total;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  stop.close();
  port.send(peak);
}

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    throw ArgumentError(
      'index.json pages_directory new_benchmark_directory seed|full|incremental',
    );
  }
  final [index, pages, root, mode] = args;
  final seed = File('$root/seed.sqlite');
  if (mode == 'seed' && seed.existsSync()) {
    throw StateError('Use a new benchmark directory.');
  }
  final work = Directory(root)..createSync(recursive: true);
  final trial = work.createTempSync('run-');
  final path = mode == 'seed' ? seed.path : '${trial.path}/trial.sqlite';
  if (mode != 'seed') {
    if (!['full', 'incremental'].contains(mode) || !seed.existsSync()) {
      throw ArgumentError('Seed the benchmark first.');
    }
    final origin = sqlite3.open(seed.path, mode: OpenMode.readOnly);
    try {
      origin.execute('VACUUM INTO ?', [path]);
    } finally {
      origin.close();
    }
  }
  var requests = 0, bytes = 0, details = 0;
  final client = MockClient((request) async {
    final uri = request.url;
    late List<int> body;
    if (uri.path == '/cards/all') {
      body = await File(index).readAsBytes();
    } else if (uri.path == '/cards/search') {
      if (uri.queryParameters.keys.any((k) => k.endsWith('update'))) {
        body = utf8.encode(
          '{"page":1,"total_pages":0,"total_cards":0,"data":[]}',
        );
      } else {
        body = await File(
          '$pages/${uri.queryParameters['page']}.json',
        ).readAsBytes();
      }
    } else {
      details++;
      throw StateError('Missing detail fixture at ${uri.path}');
    }
    requests++;
    bytes += body.length;
    return http.Response.bytes(body, 200);
  });
  final port = ReceivePort();
  final messages = port.asBroadcastStream();
  final ready = messages.first;
  await Isolate.spawn(monitor, (File(path).parent.path, port.sendPort));
  final stop = await ready as SendPort;
  final clock = Stopwatch()..start();
  try {
    await updateCatalog(
      path,
      (_) {},
      client: client,
      mode: mode == 'seed' ? SyncMode.initial : SyncMode.values.byName(mode),
    );
    clock.stop();
    final peak = messages.first;
    stop.send(true);
    final db = Catalog(sqlite3.open(path));
    try {
      final job = db.syncHistory.first;
      stdout.writeln(
        jsonEncode({
          'mode': mode,
          'cards': db.db
              .select('SELECT count(*) n FROM cards WHERE active=1')
              .single['n'],
          'requests': requests,
          'response_bytes': bytes,
          'detail_requests': details,
          'changed_cards': job['changed_cards'],
          'elapsed_ms': clock.elapsedMilliseconds,
          'apply_ms': job['apply_ms'],
          'peak_stage_bytes_sampled': await peak,
          'peak_process_rss': ProcessInfo.maxRss,
        }),
      );
    } finally {
      db.db.close();
    }
  } finally {
    stop.send(true);
    port.close();
    client.close();
    trial.deleteSync(recursive: true);
  }
}
