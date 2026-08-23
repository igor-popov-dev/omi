import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:omi/services/voice_hub/cf_access_http_client.dart';

void main() {
  group('CfAccessHttpClient', () {
    test('adds no CF-Access headers when the build has no dart-defines set', () async {
      http.BaseRequest? captured;
      final inner = MockClient((request) async {
        captured = request;
        return http.Response('ok', 200);
      });
      final client = CfAccessHttpClient(inner);

      await client.get(Uri.parse('https://omi-bridge.example/ask'));

      expect(captured!.headers.containsKey('CF-Access-Client-Id'), isFalse);
      expect(captured!.headers.containsKey('CF-Access-Client-Secret'), isFalse);
    });

    test('forwards the request body and method to the inner client unchanged', () async {
      http.BaseRequest? captured;
      final inner = MockClient((request) async {
        captured = request;
        return http.Response('ok', 200);
      });
      final client = CfAccessHttpClient(inner);

      final request = http.Request('POST', Uri.parse('https://omi-bridge.example/ask'))
        ..headers['Content-Type'] = 'application/json'
        ..body = '{"question":"hi"}';
      await client.send(request);

      expect(captured!.method, 'POST');
      expect((captured! as http.Request).body, '{"question":"hi"}');
      expect(captured!.headers['Content-Type'], 'application/json');
    });
  });
}
