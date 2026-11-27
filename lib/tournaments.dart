part of 'catalog.dart';

const matchResults = {'win': '승리', 'loss': '패배', 'draw': '무승부'};
const cutStages = {'top16': '16강', 'top8': '8강', 'top4': '4강', 'final': '결승'};
const placements = {
  'full_swiss': '풀스위스 종료',
  'swiss_eliminated': '스위스 탈락',
  'top16': '16강',
  'top8': '8강',
  'top4': '4강',
  'runner_up': '준우승',
  'champion': '우승',
};

void createTournamentSchema(Database db) {
  db.execute("""
 CREATE TABLE IF NOT EXISTS tournaments(
 id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL CHECK(trim(name)<>''), event_date TEXT NOT NULL,
 format TEXT NOT NULL CHECK(format IN ('bo1','bo3')), deck_id INTEGER REFERENCES decks(id) ON DELETE SET NULL,
 deck_snapshot TEXT CHECK(deck_snapshot IS NULL OR json_valid(deck_snapshot)), notes TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('active','completed')), final_placement TEXT CHECK(final_placement IN
 ('full_swiss','swiss_eliminated','top16','top8','top4','runner_up','champion')),
 created_at TEXT NOT NULL, updated_at TEXT NOT NULL, finished_at TEXT,
 CHECK(status <> 'completed' OR (final_placement IS NOT NULL AND finished_at IS NOT NULL)));
 CREATE TABLE IF NOT EXISTS tournament_rounds(
 id TEXT PRIMARY KEY NOT NULL,tournament_id TEXT NOT NULL REFERENCES tournaments(id) ON DELETE CASCADE,
 round_number INTEGER NOT NULL CHECK(round_number>0),stage TEXT NOT NULL,
 top_cut_stage TEXT, opponent_name TEXT NOT NULL, opponent_champion TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('draft','completed')),
 result TEXT CHECK(result IN ('win','loss','draw')), notes TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 UNIQUE(tournament_id,round_number), CHECK(status <> 'completed' OR result IS NOT NULL),
 CHECK((stage='swiss' AND top_cut_stage IS NULL) OR
 (stage='top_cut' AND top_cut_stage IS NOT NULL AND top_cut_stage IN ('top16','top8','top4','final'))));
 CREATE TABLE IF NOT EXISTS round_games(round_id TEXT NOT NULL REFERENCES tournament_rounds(id) ON DELETE CASCADE,
 game_number INTEGER NOT NULL CHECK(game_number BETWEEN 1 AND 3),
 result TEXT NOT NULL CHECK(result IN ('win','loss','draw')),created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
 PRIMARY KEY(round_id,game_number));
 CREATE TABLE IF NOT EXISTS round_life(round_id TEXT NOT NULL REFERENCES tournament_rounds(id) ON DELETE CASCADE,
 game_number INTEGER NOT NULL CHECK(game_number BETWEEN 1 AND 3),life1 INTEGER NOT NULL,life2 INTEGER NOT NULL,
 player INTEGER NOT NULL CHECK(player IN (1,2)),turn INTEGER NOT NULL CHECK(turn>=1),
 previous_life1 INTEGER,previous_life2 INTEGER, PRIMARY KEY(round_id,game_number));
 CREATE TRIGGER IF NOT EXISTS tournament_format_lock BEFORE UPDATE OF format ON tournaments
 WHEN NEW.format<>OLD.format AND EXISTS(SELECT 1 FROM tournament_rounds WHERE tournament_id=OLD.id)
 BEGIN SELECT RAISE(ABORT,'라운드를 삭제한 뒤 유형을 변경하세요.'); END;
 """);
}

String eventDay(DateTime value) => value.toIso8601String().split('T').first;

const _eventScores = """
 SELECT t.*,count(CASE WHEN r.result='win' THEN 1 END) wins,
 count(CASE WHEN r.result='loss' THEN 1 END) losses,
 count(CASE WHEN r.result='draw' THEN 1 END) draws
 FROM tournaments t LEFT JOIN tournament_rounds r ON t.id=r.tournament_id
 AND r.status='completed' AND r.stage='swiss'
 """;

String eventScore(Map row) =>
    "${placements[row['final_placement']] ?? '최종 성적 미지정'} / ${row['wins']}-${row['losses']}-${row['draws']}";

extension TournamentRecords on Catalog {
  List<Row> get events => db.select(
    '$_eventScores GROUP BY t.id ORDER BY t.event_date DESC,t.created_at DESC,t.id',
  );
  Row event(String id) =>
      db.select('$_eventScores WHERE t.id=? GROUP BY t.id', [id]).single;

  void setPlacement(String id, String placement, {bool finish = false}) {
    final now = syncNow();
    db.execute(
      """UPDATE tournaments SET final_placement=?,updated_at=?,
      status=CASE WHEN ? THEN 'completed' ELSE status END,
      finished_at=CASE WHEN ? THEN coalesce(finished_at,?) ELSE finished_at END WHERE id=?""",
      [placement, now, finish ? 1 : 0, finish ? 1 : 0, now, id],
    );
  }

  List<Row> rounds(String id) => db.select(
    """SELECT r.*, g1.result game1, g2.result game2, g3.result game3
       FROM tournament_rounds r
       LEFT JOIN round_games g1 ON g1.round_id=r.id AND g1.game_number=1
       LEFT JOIN round_games g2 ON g2.round_id=r.id AND g2.game_number=2
       LEFT JOIN round_games g3 ON g3.round_id=r.id AND g3.game_number=3
       WHERE r.tournament_id=? ORDER BY r.round_number""",
    [id],
  );
  Row round(String id) =>
      db.select('SELECT * FROM tournament_rounds WHERE id=?', [id]).single;
  String saveEvent({
    String? id,
    required String name,
    required String date,
    required String format,
    int? deck,
    String notes = '',
    bool forgetDeck = false,
  }) {
    final key = id ?? newUuid();
    final now = syncNow();
    transaction(() {
      final old = id == null ? null : event(id);
      String? snapshot = old?['deck_snapshot'];
      if (deck != null && (old == null || deck != old['deck_id'])) {
        final title = db.select('SELECT name FROM decks WHERE id=?', [
          deck,
        ]).single['name'];
        snapshot = jsonEncode({
          'name': title,
          'entries': [
            for (final e in deckEntries(deck))
              {
                'card': e.card,
                'name': e.name,
                'edition': e.edition,
                'zone': e.zone.name,
                'quantity': e.quantity,
              },
          ],
        });
      } else if (forgetDeck) {
        snapshot = null;
      }
      if (old == null) {
        db.execute(
          "INSERT INTO tournaments(id,name,event_date,format,deck_id,deck_snapshot,notes,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,'active',?,?)",
          [key, name.trim(), date, format, deck, snapshot, notes, now, now],
        );
      } else {
        db.execute(
          'UPDATE tournaments SET name=?,event_date=?,format=?,deck_id=?,deck_snapshot=?,notes=?,updated_at=? WHERE id=?',
          [name.trim(), date, format, deck, snapshot, notes, now, key],
        );
      }
    });
    return key;
  }

  void deleteEvent(String id) =>
      transaction(() => db.execute('DELETE FROM tournaments WHERE id=?', [id]));
  void deleteRound(String id) => transaction(
    () => db.execute('DELETE FROM tournament_rounds WHERE id=?', [id]),
  );
  String addRound(String eventId) {
    final key = newUuid(), now = syncNow();
    transaction(
      () => db.execute(
        """INSERT INTO tournament_rounds(id,tournament_id,round_number,stage,opponent_name,opponent_champion,status,notes,created_at,updated_at)
     SELECT ?,?,coalesce(max(round_number),0)+1,'swiss','','','draft','',?,? FROM tournament_rounds WHERE tournament_id=?""",
        [key, eventId, now, now, eventId],
      ),
    );
    return key;
  }

  List<String?> games(String roundId) {
    final slots = List<String?>.filled(3, null);
    for (final row in db.select(
      'SELECT game_number,result FROM round_games WHERE round_id=?',
      [roundId],
    )) {
      slots[(row['game_number'] as int) - 1] = row['result'];
    }
    return slots;
  }

  void saveRound(
    String id, {
    required String stage,
    String? cut,
    String opponent = '',
    String champion = '',
    String notes = '',
    required bool complete,
    String? result,
    List<String?>? sets,
  }) {
    transaction(() {
      final r = round(id);
      if (event(r['tournament_id'])['format'] == 'bo3') {
        final scores = sets ?? games(id);
        result = bo3Preview(scores);
        if (complete && result == null) throw StateError('1세트 결과가 필요합니다.');
        final now = syncNow();
        for (final (index, value) in scores.indexed) {
          if (value == null) {
            db.execute(
              'DELETE FROM round_games WHERE round_id=? AND game_number=?',
              [id, index + 1],
            );
          } else {
            db.execute(
              """INSERT INTO round_games VALUES(?,?,?,?,?) ON CONFLICT(round_id,game_number)
              DO UPDATE SET result=excluded.result,updated_at=excluded.updated_at WHERE result<>excluded.result""",
              [id, index + 1, value, now, now],
            );
          }
        }
      } else if (sets != null) {
        throw StateError('BO1에는 세트를 기록할 수 없습니다.');
      }
      if (complete && result == null) throw StateError('라운드 결과가 필요합니다.');
      db.execute(
        'UPDATE tournament_rounds SET stage=?,top_cut_stage=?,opponent_name=?,opponent_champion=?,notes=?,status=?,result=?,updated_at=? WHERE id=?',
        [
          stage,
          stage == 'swiss' ? null : cut,
          opponent,
          champion,
          notes,
          complete ? 'completed' : 'draft',
          result,
          syncNow(),
          id,
        ],
      );
    });
  }
}

String? snapshotName(Map row) {
  final value = row['deck_snapshot'];
  return value == null ? null : jsonDecode(value)['name'] as String?;
}

String roundResultLabel(String? result, {Iterable<String?> sets = const []}) {
  if (result == null) return '미기록';
  const marks = {'win': 'O', 'loss': 'X', 'draw': '-'};
  final sequence = sets.nonNulls.map((set) => marks[set]!).join();
  final label = matchResults[result]!;
  return sequence.isEmpty ? label : '$label($sequence)';
}

// Version 0.6 and earlier allowed a third game after a second-game draw.
bool hasLegacyThirdGame(List<String?> sets) =>
    sets.length == 3 && sets[1] == 'draw' && sets[2] != null;

bool canRecordSet(List<String?> sets, int index) =>
    sets.take(index).every((s) => s == 'win' || s == 'loss');

String? bo3Preview(List<String?> sets, {bool allowLegacyThirdGame = false}) {
  if (sets.length != 3 ||
      sets.nonNulls.any((v) => !matchResults.containsKey(v))) {
    throw StateError('잘못된 세트 결과입니다.');
  }
  if (sets[0] == null || sets[0] == 'draw') {
    if (sets[1] != null || sets[2] != null) {
      throw StateError('1세트 이후 기록을 확인하세요.');
    }
    return sets[0];
  }
  if (sets[2] != null && sets[1] == null) throw StateError('2세트 결과가 필요합니다.');
  if (!allowLegacyThirdGame && hasLegacyThirdGame(sets)) {
    throw StateError('무승부 이후 세트는 기록할 수 없습니다.');
  }
  final wins = sets.where((v) => v == 'win').length;
  final losses = sets.where((v) => v == 'loss').length;
  if (wins == losses) return 'draw';
  return wins > losses ? 'win' : 'loss';
}

List<String?> changeSet(List<String?> sets, int index, String? value) {
  if (!canRecordSet(sets, index)) {
    throw StateError('앞 세트를 먼저 기록하세요.');
  }
  final next = List<String?>.of(sets)..[index] = value;
  if (value == null || value == 'draw') {
    next.fillRange(index + 1, 3, null);
  }
  bo3Preview(next);
  return next;
}
