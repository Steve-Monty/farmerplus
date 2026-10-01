import 'package:flutter/widgets.dart';

Future<String> verifyMiniSignature(
  String signed,
  String signature,
  String key,
) => throw UnsupportedError('Downloaded apps require the FarmerPlus PWA.');

class RemoteFrame extends StatelessWidget {
  final String html;
  final Future<String> Function(String) onRequest;
  final Listenable changes;
  const RemoteFrame({
    super.key,
    required this.html,
    required this.onRequest,
    required this.changes,
  });
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Open this app in the FarmerPlus PWA.'));
}
