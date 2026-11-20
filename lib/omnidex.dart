import 'dart:convert';
import 'package:http/http.dart' as http;

enum ValidationStatus { valid, invalid, unknown }

typedef ValidationResult = ({ValidationStatus status, String detail});

Future<ValidationResult> validateOmnidex(
  String text,
  http.Client client,
) async {
  try {
    final response = await client
        .post(
          Uri.https('api.gatcg.com', '/omnidex/decklist-validator'),
          headers: {'Content-Type': 'application/json; charset=utf-8'},
          body: utf8.encode(jsonEncode({'raw': text, 'format': 'STANDARD'})),
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      return (
        status: ValidationStatus.unknown,
        detail: '공식 서버 응답 HTTP ${response.statusCode}. 다시 시도하세요.',
      );
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map || body['valid'] is! bool || body['errors'] is! List) {
      throw const FormatException();
    }
    final errors = body['errors'] as List;
    if (body['valid'] == true && errors.isEmpty) {
      return (
        status: ValidationStatus.valid,
        detail: '공식 Standard 덱 검증을 통과했습니다.',
      );
    }
    if (body['valid'] != false) throw const FormatException();
    final messages = [
      for (final error in errors.whereType<Map>())
        [
          if (error['line'] != null) "${error['line']}행",
          error['deck'],
          error['card'],
          error['code'],
          error['message'],
        ].nonNulls.join(' · '),
    ];
    return (
      status: ValidationStatus.invalid,
      detail: messages.isEmpty ? '공식 서버가 덱을 무효로 판정했습니다.' : messages.join('\n'),
    );
  } on FormatException {
    return (status: ValidationStatus.unknown, detail: '공식 서버의 응답을 읽을 수 없습니다.');
  } on Exception {
    return (
      status: ValidationStatus.unknown,
      detail: '서버에 연결할 수 없습니다. 네트워크를 확인하고 다시 시도하세요.',
    );
  }
}
