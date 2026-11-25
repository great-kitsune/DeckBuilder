import 'dart:convert';
import 'dart:io';
import 'package:deck_builder/catalog.dart';
import 'package:deck_builder/sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'catalog_test.dart' show card,edition;

class Fixture {
 final rows={for(var n=0;n<12;n++)'c$n':card('c$n','Card $n',prints:[edition('e$n','S','$n',1)])};
 final calls=<Uri>[];
 final changed=<String,List<String>>{};
 late final client=MockClient((req)async{
 final u=req.url;calls.add(u);dynamic data;
 if(u.path=='/cards/all'){
   data=[for(final id in rows.keys){'uuid':id,'slug':id}];
 }else if(u.path=='/cards/search'){
   final filter=u.queryParameters.keys.where((k)=>k.endsWith('update')).firstOrNull;
   final dataRows=filter==null?rows.values.toList():[for(final id in changed[filter]??<String>[])rows[id]];
   data={'page':1,'total_pages':dataRows.isEmpty?0:1,'data':dataRows};
 }else{data=rows[u.pathSegments.last];}
 return http.Response.bytes(utf8.encode(jsonEncode(data)),200);
 });
}
void main(){
 late Directory dir; late Catalog live;late Fixture f; late String path;
 Future<void> sync([SyncMode? mode])=>updateCatalog(path,(_){},mode:mode,client:f.client);
 setUp(()async{dir=Directory.systemTemp.createTempSync();path='${dir.path}/live';live=Catalog(sqlite3.open(path));f=Fixture();await sync();f.calls.clear();});
 tearDown((){live.db.close();dir.deleteSync(recursive:true);});
 test('no changes uses two independent filters, overlap and two indexes, no details',()async{
 final start=DateTime.parse(live.baseline!['last_successful_sync'] as String);
 final date=start.subtract(const Duration(days:2)).toIso8601String().substring(0,10);
 await sync();expect(f.calls.map((u)=>u.path),['/cards/all','/cards/search','/cards/search','/cards/all']);
 expect(f.calls[1].queryParameters['last_update'],date);expect(f.calls[2].queryParameters['edition_last_update'],date);
 expect(f.calls[1].queryParameters.containsKey('edition_last_update'),false);
 });
 test('union fetches one detail per UUID; added prints, graphics, retired prints match full state',()async{
 final id=live.createDeck('Keep');live.addToDeck(id,DeckZone.material,'c1','e1');
 final unchanged=live.db.select("SELECT payload FROM cards WHERE id='c7'").single['payload'];
 f.rows['c1']!['effect_raw']='different';f.rows['c1']!['editions']=[{...edition('new','X','1',2),'graphics':{'banner':[]},'image':'/cards/images/new.jpg'}];
 f.changed['last_update']=['c1'];f.changed['edition_last_update']=['c1'];
 f.rows['new']=card('new','New',prints:[edition('ne','S','5',2)]);
 await sync();expect(f.calls.where((u)=>u.path=='/cards/c1'),hasLength(1));
 expect(f.calls.where((u)=>u.path=='/cards/new'),hasLength(1));
 expect(live.db.select('SELECT id FROM retired_editions').single['id'],'e1');
 expect(live.deckEntries(id).single.edition,'e1');
 expect(live.db.select("SELECT payload FROM cards WHERE id='c7'").single['payload'],unchanged);
 f.calls.clear();f.rows['c1']!['editions'][0]['image']='/cards/images/v2.jpg';f.changed.remove('last_update');
 await sync();expect(f.calls.where((u)=>u.path=='/cards/c1'),hasLength(1));
 final snapshot=live.db.select('SELECT * FROM install_manifest ORDER BY kind,id').map((r)=>r.values.toList()).toList();
 await sync(SyncMode.full);expect(live.db.select('SELECT * FROM install_manifest ORDER BY kind,id').map((r)=>r.values.toList()),snapshot);
 });
 test('large change set falls back to full before fetching any detail',()async{
 f.changed['last_update']=['c1','c2','c3','c4'];await sync();
 expect(f.calls.where((u)=>u.path=='/cards/search' && !u.queryParameters.keys.any((k)=>k.endsWith('update'))),hasLength(1));
 });
}
