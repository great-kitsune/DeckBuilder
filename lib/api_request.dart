import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

Future<http.Response> getFromApi(http.Client client, Uri uri) async {
  for (var attempt = 0; ; attempt++) {
    try {
      final response = await client
          .get(uri)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode == 200) return response;
      if (response.statusCode != 429 && response.statusCode < 500) {
        throw FormatException('공식 API 오류 (HTTP ${response.statusCode}) · $uri');
      }
      throw HttpException('공식 API 오류 (HTTP ${response.statusCode})', uri: uri);
    } on Exception catch (error) {
      if (error is FormatException || attempt >= 2) rethrow;
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
    }
  }
}
