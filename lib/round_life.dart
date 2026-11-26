import 'package:sqlite3/sqlite3.dart';
import 'catalog.dart';

extension RoundLife on Catalog {
  Row? life(String id, int game) => db.select(
    'SELECT * FROM round_life WHERE round_id=? AND game_number=?',
    [id, game],
  ).firstOrNull;
  void startLife(String id, int game, int one, int two) {
    transaction(() {
      if (game != 1 && event(round(id)['tournament_id'])['format'] == 'bo1') {
        throw StateError('BO1은 한 세트입니다.');
      }
      db.execute(
        'INSERT INTO round_life(round_id,game_number,life1,life2,player,turn) VALUES(?,?,?,?,1,1) ON CONFLICT(round_id,game_number) DO NOTHING',
        [id, game, one, two],
      );
    });
  }

  void adjustLife(
    String id,
    int game,
    int player,
    int value, {
    bool absolute = false,
  }) {
    final column = switch (player) {
      1 => 'life1',
      2 => 'life2',
      _ => throw ArgumentError.value(player),
    };
    db.execute(
      'UPDATE round_life SET previous_life1=life1,previous_life2=life2,$column=${absolute ? '?' : '$column+?'} WHERE round_id=? AND game_number=?',
      [value, id, game],
    );
  }

  void undoLife(String id, int game) => db.execute(
    'UPDATE round_life SET life1=previous_life1,life2=previous_life2,previous_life1=NULL,previous_life2=NULL WHERE round_id=? AND game_number=? AND previous_life1 IS NOT NULL AND previous_life2 IS NOT NULL',
    [id, game],
  );
  void nextTurn(String id, int game) => db.execute(
    'UPDATE round_life SET player=3-player,turn=turn+1 WHERE round_id=? AND game_number=?',
    [id, game],
  );
  void switchPlayer(String id, int game) => db.execute(
    'UPDATE round_life SET player=3-player WHERE round_id=? AND game_number=?',
    [id, game],
  );
  void setTurn(String id, int game, int value) => db.execute(
    'UPDATE round_life SET turn=? WHERE round_id=? AND game_number=?',
    [value, id, game],
  );
}
