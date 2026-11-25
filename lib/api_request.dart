import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;

class SyncProblem implements Exception {
  final String code, message;
  const SyncProblem(this.code, this.message);
  bool get transient => const {
    'network_timeout',
    'network_unavailable',
    'rate_limited',
    'server_error',
  }.contains(code);
  @override
  String toString() => message;
}

Duration? retryAfter(String? header, DateTime now) {
  if (header == null) return null;
  final seconds = int.tryParse(header);
  if (seconds != null) {
    return seconds < 0 ? null : Duration(seconds: min(seconds, 30));
  }
  try {
    final duration = HttpDate.parse(header).difference(now);
    return duration.isNegative
        ? Duration.zero
        : Duration(milliseconds: min(30000, duration.inMilliseconds));
  } on HttpException {
    return null;
  } on FormatException {
    return null;
  }
}

Future<http.Response> getFromApi(
  http.Client client,
  Uri uri, {
  void Function()? beforeAttempt,
  void Function(int)? received,
  Future<void> Function(Duration) delay = Future<void>.delayed,
  Duration timeout = const Duration(seconds: 60),
}) async {
  for (var attempt = 0; ; attempt++) {
    beforeAttempt?.call();
    Duration? requestedDelay;
    late SyncProblem error;
    try {
      final response = await client.get(uri).timeout(timeout);
      received?.call(response.bodyBytes.length);
      if (response.statusCode == 200) return response;
      if (response.statusCode == 429) {
        error = const SyncProblem('rate_limited', '공식 API 요청 한도에 도달했습니다.');
      } else if (response.statusCode >= 500 && response.statusCode < 600) {
        error = const SyncProblem('server_error', '공식 API 서버가 응답을 처리하지 못했습니다.');
      } else {
        throw SyncProblem(
          'invalid_response',
          '공식 API 요청이 거부되었습니다 (HTTP ${response.statusCode}).',
        );
      }
      requestedDelay = retryAfter(
        response.headers['retry-after'],
        DateTime.now().toUtc(),
      );
    } on TimeoutException {
      error = const SyncProblem('network_timeout', '공식 API 응답 시간이 초과되었습니다.');
    } on SocketException {
      error = const SyncProblem('network_unavailable', '공식 API에 연결할 수 없습니다.');
    } on http.ClientException {
      error = const SyncProblem('network_unavailable', '공식 API에 연결할 수 없습니다.');
    }
    if (attempt >= 3) throw error;
    await delay(
      requestedDelay ??
          Duration(milliseconds: 500 * (1 << attempt) + Random().nextInt(200)),
    );
  }
}
