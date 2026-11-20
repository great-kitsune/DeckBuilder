# DeckBuilder

Grand Archive Utility의 첫 구현은 Windows·Android에서 사용하는 오프라인 카드 DB와 검색이다. Flutter 3.38.7 및 Dart 3.10으로 개발했다.

## 실행

Flutter와 대상 플랫폼 도구를 설치한 환경에서 실행한다.

```sh
flutter pub get
flutter run -d windows
```

Android는 `flutter devices`에 표시된 기기 ID로 `flutter run -d <기기-ID>`를 실행한다. 테스트는 `flutter test`, 정적 분석은 `flutter analyze`로 실행한다.

## 사용 방법

- 홈 또는 설정에서 **데이터베이스 다운로드**를 누르고 확인한다. 같은 버튼으로 갱신할 수 있다. 공식 목록과 페이지 결과를 UUID로 대조하고 누락된 상세를 개별 조회한다. 임시 SQLite DB 검증이 끝나면 한 트랜잭션으로 적용한다.
- **카드 검색**에서 이름·효과와 필터를 조합한다. 그룹 내 연산은 각각 AND/OR를 선택하고 그룹 간에는 AND를 적용한다. 세트·희귀도는 동일한 후보 인쇄판 집합에서 평가한다. 에디션별 보기로 해당 인쇄판을 확인할 수 있다.
- 카드 상세에서 열람한 공식 이미지는 기기에 캐시한다. 설정에서 캐시 용량을 확인하거나 삭제할 수 있다. 텍스트 검색에는 이미지가 필요하지 않다.
- **스포일러 추가**에서 공개된 정보와 이미지를 등록한다. 공식 데이터와 영문명 또는 세트·수집 번호가 고유하게 일치하면 자동 교체하고 로컬 ID와 공식 UUID의 연결을 보존한다. 후보가 충돌하면 상세 화면에서 선택한다.

공식 데이터는 [Grand Archive Index API](https://api-docs.gatcg.com/)에서 사용자의 요청으로 내려받는다.
