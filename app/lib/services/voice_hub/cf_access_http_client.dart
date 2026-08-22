// A minimal `http.Client` decorator that stamps the same two Cloudflare
// Access headers `buildHeaders` (backend/http/shared.dart:131-132) already
// adds to every other authenticated Omi API call — no-op (adds nothing)
// unless the build sets OMI_CF_ACCESS_CLIENT_ID/_SECRET, exactly like that
// call site.
//
// Why this exists here rather than reusing something from `backend/http/`:
// this app has no general-purpose CF-Access-*intercepting* `http.Client`
// anywhere — `buildHeaders` is a header-builder consumed by `makeApiCall`
// and friends, which construct their own `http.Request` per call. There is
// nothing to inject for `AskClaudeBridgeClient`, which needs a real
// `http.Client` because it streams an SSE response
// (`httpClient.send(request)` in `ask_claude_tool.dart`). This fixes the
// `bridgeHttpClient` gap that `voice_hub_production.dart` previously left
// as a required parameter with no production default.
import 'package:http/http.dart' as http;

import 'package:omi/env/env.dart';

class CfAccessHttpClient extends http.BaseClient {
  final http.Client _inner;

  CfAccessHttpClient([http.Client? inner]) : _inner = inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (Env.cfAccessClientId.isNotEmpty) {
      request.headers['CF-Access-Client-Id'] = Env.cfAccessClientId;
    }
    if (Env.cfAccessClientSecret.isNotEmpty) {
      request.headers['CF-Access-Client-Secret'] = Env.cfAccessClientSecret;
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
