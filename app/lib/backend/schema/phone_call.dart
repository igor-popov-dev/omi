import 'package:omi/backend/schema/gen/phone_calls_wire.g.dart' as wire;

enum PhoneCallDirection { incoming, outgoing }

enum PhoneCallState { idle, connecting, ringing, active, ended, failed }

// Phase 4 SSOT: VerifiedPhoneNumber was a pure 1:1 field-mapping wrapper around
// GeneratedPhoneNumberResponse (identical fields + fromJson + toJson). Replaced
// with a typedef. PhoneCallToken and PhoneCallError stay hand-written: PhoneCallToken
// derives a computed expiresAt, PhoneCallError parses a Twilio event map — neither is
// a thin wrapper.
typedef VerifiedPhoneNumber = wire.GeneratedPhoneNumberResponse;

class PhoneCallToken {
  final String accessToken;
  final int ttl;
  final String identity;
  final DateTime expiresAt;

  PhoneCallToken({required this.accessToken, required this.ttl, required this.identity})
      : expiresAt = DateTime.now().add(Duration(seconds: ttl));

  factory PhoneCallToken.fromJson(Map<String, dynamic> json) {
    return PhoneCallToken.fromGenerated(wire.GeneratedTokenResponse.fromJson(json));
  }

  factory PhoneCallToken.fromGenerated(wire.GeneratedTokenResponse generated) {
    return PhoneCallToken(accessToken: generated.accessToken, ttl: generated.ttl, identity: generated.identity);
  }

  wire.GeneratedTokenResponse toGenerated() {
    return wire.GeneratedTokenResponse(accessToken: accessToken, ttl: ttl, identity: identity);
  }
}

/// Answer of `POST v1/phone/token` on a Voximplant deployment.
///
/// The endpoint answers twice per call: without a key it reports where to connect
/// ([hash] is null), with the key it repeats that and adds the login hash. Twilio
/// deployments answer with [PhoneCallToken] instead — the shape is how the app tells them
/// apart, so that switching providers is a server-side change.
class VoximplantLogin {
  final String user;
  final String node;
  final int ttl;
  final String? hash;

  const VoximplantLogin({required this.user, required this.node, required this.ttl, this.hash});

  static VoximplantLogin? fromJson(Map<String, dynamic> json) {
    if (json['provider'] != 'voximplant') return null;
    final user = json['user'];
    final node = json['node'];
    if (user is! String || node is! String || user.isEmpty || node.isEmpty) return null;
    final hash = json['hash'];
    return VoximplantLogin(
      user: user,
      node: node,
      ttl: json['ttl'] is int ? json['ttl'] as int : 0,
      hash: hash is String && hash.isNotEmpty ? hash : null,
    );
  }
}

class PhoneCallError {
  final String code;
  final String message;

  PhoneCallError({required this.code, required this.message});

  factory PhoneCallError.fromEvent(Map event) {
    return PhoneCallError(
      code: event['code'] as String? ?? 'UNKNOWN',
      message: event['message'] as String? ?? 'An unknown error occurred',
    );
  }

  @override
  String toString() => 'PhoneCallError($code: $message)';
}
