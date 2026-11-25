part of 'catalog.dart';

class SyncCounts {
  final int addedCards, changedCards, addedEditions, changedEditions, removedCards;
  const SyncCounts(this.addedCards,this.changedCards,this.addedEditions,this.changedEditions,this.removedCards);
  bool get unchanged => addedCards+changedCards+addedEditions+changedEditions+removedCards==0;
}

extension CatalogDelta on Catalog {
  // Called inside the publication transaction, with the validated stage attached.
  SyncCounts countIncoming(bool full){
    int count(String sql)=>db.select('SELECT count(*) n FROM $sql').single['n'] as int;
    const cards='incoming.cards s LEFT JOIN main.cards c ON c.id=s.id';
    const prints='incoming.editions s LEFT JOIN main.editions e ON e.id=s.id';
    const differentCard="""EXISTS(SELECT 1 FROM incoming.install_manifest i
      LEFT JOIN main.install_manifest m USING(kind,id)
      WHERE i.kind='card' AND i.id=s.id AND i.digest IS NOT m.digest)""";
    final changedEditions=count('$prints WHERE e.id IS NOT NULL AND (e.payload<>s.payload OR e.position<>s.position)');
    final retired=count('main.editions e JOIN incoming.cards c ON c.id=e.card WHERE NOT EXISTS(SELECT 1 FROM incoming.editions s WHERE s.id=e.id)');
    return SyncCounts(count('$cards WHERE c.active IS NOT 1'), count('$cards WHERE c.active=1 AND $differentCard'),
      count('$prints WHERE e.id IS NULL'),changedEditions+retired,
      full?count('main.cards c WHERE c.active=1 AND NOT EXISTS(SELECT 1 FROM incoming.cards s WHERE s.id=c.id)'):0);
  }

  void publishIncremental(String path,void Function(SyncCounts) finish){
    db.execute('ATTACH DATABASE ? AS incoming',[path]);
    try{
      transaction((){
        final counts=countIncoming(false);
        // An Edition UUID may never move between card UUIDs.
        if(db.select('SELECT 1 FROM incoming.editions s JOIN main.editions e USING(id) WHERE e.card<>s.card LIMIT 1').isNotEmpty){
          throw const FormatException('인쇄판의 카드 소유자가 변경되었습니다.');
        }
        db.execute("""
          INSERT OR REPLACE INTO retired_editions SELECT e.id,e.card,e.payload FROM main.editions e
            JOIN incoming.cards c ON c.id=e.card WHERE NOT EXISTS(SELECT 1 FROM incoming.editions s WHERE s.id=e.id);
          DELETE FROM install_manifest WHERE kind='edition' AND id IN
            (SELECT e.id FROM main.editions e JOIN incoming.cards c ON c.id=e.card WHERE NOT EXISTS(SELECT 1 FROM incoming.editions s WHERE s.id=e.id));
          DELETE FROM editions WHERE card IN (SELECT id FROM incoming.cards) AND id NOT IN(SELECT id FROM incoming.editions);
          DELETE FROM retired_editions WHERE id IN(SELECT id FROM incoming.editions);
          INSERT INTO cards SELECT * FROM incoming.cards WHERE true ON CONFLICT(id) DO UPDATE SET
            name=excluded.name,norm=excluded.norm,active=1,effect=excluded.effect,payload=excluded.payload
            WHERE cards.active<>1 OR cards.payload<>excluded.payload;
          DELETE FROM tags WHERE card IN(SELECT id FROM incoming.cards)
            AND (card,kind,value) NOT IN(SELECT card,kind,value FROM incoming.tags);
          INSERT OR IGNORE INTO tags SELECT * FROM incoming.tags;
          INSERT INTO editions SELECT * FROM incoming.editions WHERE true ON CONFLICT(id) DO UPDATE SET
            set_code=excluded.set_code, number=excluded.number, rarity=excluded.rarity,
            position=excluded.position,payload=excluded.payload
            WHERE editions.payload<>excluded.payload OR editions.position<>excluded.position;
          INSERT INTO install_manifest SELECT * FROM incoming.install_manifest WHERE true ON CONFLICT(kind,id)
            DO UPDATE SET digest=excluded.digest WHERE install_manifest.digest<>excluded.digest;
        """);
        if(!counts.unchanged){reconcileSpoilers();setMetadata('updated',syncNow());}
        finish(counts);
      });
    }finally{db.execute('DETACH DATABASE incoming');}
  }
}
