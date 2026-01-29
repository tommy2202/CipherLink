import 'package:flutter/material.dart';

class TrustedDeviceBadge extends StatelessWidget {
  const TrustedDeviceBadge({super.key, required this.isTrusted});

  factory TrustedDeviceBadge.forFingerprint({
    Key? key,
    required String fingerprint,
    required Set<String> trustedFingerprints,
  }) {
    return TrustedDeviceBadge(
      key: key,
      isTrusted: trustedFingerprints.contains(fingerprint),
    );
  }

  final bool isTrusted;

  @override
  Widget build(BuildContext context) {
    if (isTrusted) {
      return const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text(
          'Seen before',
          style: TextStyle(color: Colors.green),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.only(top: 4),
      child: Text(
        'New device',
        style: TextStyle(color: Colors.orange),
      ),
    );
  }
}
