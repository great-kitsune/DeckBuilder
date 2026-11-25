import 'catalog.dart';
import 'package:sqlite3/sqlite3.dart';

const phaseLabels = {
  'checking': '기존 데이터 확인',
  'fetching_index': '공식 카드 목록 확인',
  'fetching_changes': '카드 페이지 조회',
  'fetching_details': '상세 카드 조회',
  'validating': '무결성 검증',
  'applying': '데이터 반영',
  'finished': '종료',
};
const statusLabels = {
  'queued': '대기',
  'running': '진행 중',
  'paused': '일시중단',
  'interrupted': '중단',
  'completed': '완료',
  'cancelled': '취소',
  'failed': '실패',
};
const modeLabels = {
  'initial': '카드 데이터 설치',
  'incremental': '변경분 업데이트',
  'full': '전체 데이터 재검사',
};
String jobLabel(Row job) {
  final status = job['status'];
  if (status == 'completed') {
    final empty = [
      'added_cards',
      'changed_cards',
      'added_editions',
      'changed_editions',
      'removed_cards',
    ].every((k) => job[k] == 0);
    return empty && job['mode'] == SyncMode.incremental.name
        ? '이미 최신 카드 데이터입니다'
        : '카드 데이터 갱신 완료';
  }
  final total = job['total'];
  final detail = job['error_message'];
  return [
    statusLabels[status],
    phaseLabels[job['phase']],
    if (total != null) "${job['completed']} / $total",
    ?detail,
  ].join(' · ');
}
