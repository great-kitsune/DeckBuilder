part of 'sync.dart';

Never invalidData(String message) =>
    throw SyncProblem('invalid_response', message);

bool validId(dynamic value) =>
    value is String && value.isNotEmpty && value == value.trim();

void validatePrinting(dynamic e, String card) {
  if (e is! Json ||
      !validId(e['uuid']) ||
      (e['card_id'] != null && e['card_id'] != card) ||
      e['set'] is! Json ||
      !validId(e['set']['prefix']) ||
      !validId(e['collector_number'])) {
    invalidData('인쇄판 식별자, 카드 연결 또는 세트 정보가 잘못되었습니다.');
  }
}

void validateCard(dynamic raw) {
  if (raw is! Json ||
      !validId(raw['uuid']) ||
      raw['name'] is! String ||
      (raw['name'] as String).trim().isEmpty ||
      raw['editions'] is! List ||
      (raw['editions'] as List).isEmpty) {
    invalidData('카드의 이름, UUID 또는 인쇄판이 누락되었습니다.');
  }
  final editions = <String>{};
  for (final e in raw['editions']) {
    validatePrinting(e, raw['uuid']);
    if (!editions.add(e['uuid'])) invalidData('중복된 인쇄판 UUID입니다.');
    final orientations = e['other_orientations'];
    if (orientations != null && orientations is! List) {
      invalidData('양면 카드 형식이 잘못되었습니다.');
    }
    final faces = <String>{};
    for (final face in orientations ?? []) {
      if (face is! Json ||
          !validId(face['uuid']) ||
          face['uuid'] == raw['uuid'] ||
          !validId(face['name'])) {
        invalidData('양면 카드 식별자가 잘못되었습니다.');
      }
      validatePrinting(face['edition'], face['uuid']);
      if (!faces.add(face['edition']['uuid']) ||
          (face['edition_id'] != null &&
              face['edition_id'] != face['edition']['uuid'])) {
        invalidData('양면 인쇄판 연결이 잘못되었습니다.');
      }
    }
  }
}

void validatePage(Json data, int page, int pages, List rows) {
  final total = data['total_cards'];
  if (data['page'] != page ||
      data['total_pages'] != pages ||
      rows.length > 50 ||
      (data.containsKey('page_size') && data['page_size'] != 50) ||
      (data.containsKey('has_more') && data['has_more'] != (page < pages)) ||
      (data.containsKey('paginated_cards_count') &&
          data['paginated_cards_count'] != rows.length) ||
      (total != null &&
          (total is! int ||
              total < 0 ||
              (total / 50).ceil() != pages ||
              rows.length !=
                  (page == pages
                      ? total - (page - 1) * 50
                      : pages == 0
                      ? 0
                      : 50)))) {
    throw const SyncProblem('pagination_mismatch', '페이지 경계 또는 전체 수가 응답과 다릅니다.');
  }
}

SyncProblem classifySyncError(Object error) {
  if (error is SyncProblem) return error;
  if (error is SqliteException) {
    return switch (error.resultCode & 255) {
      13 => const SyncProblem('storage_full', '저장 공간을 확보한 후 다시 시도하세요.'),
      11 || 26 => const SyncProblem(
        'database_corrupt',
        'DB를 읽을 수 없습니다. 데이터 관리에서 백업 복원을 확인하세요.',
      ),
      19 => const SyncProblem('invalid_response', '카드 식별자 또는 참조가 충돌했습니다.'),
      _ => const SyncProblem('database_error', 'DB 반영에 실패했습니다. 기존 데이터는 유지됩니다.'),
    };
  }
  if (error is FileSystemException &&
      [28, 112].contains(error.osError?.errorCode)) {
    return const SyncProblem('storage_full', '저장 공간이 부족합니다.');
  }
  if (error is FormatException && error.message.contains('더 새로운 DB')) {
    return const SyncProblem('schema_unsupported', '더 새로운 DB입니다. 앱 버전을 확인하세요.');
  }
  if (error is SyncCancelled) {
    return const SyncProblem('cancelled', '다운로드를 취소했습니다.');
  }
  return const SyncProblem('invalid_response', '공식 데이터 구조를 검증할 수 없습니다.');
}
