// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

Future<void> exportMiniRecords(String name, String json) async {
  final url = html.Url.createObjectUrlFromBlob(
    html.Blob([json], 'application/json'),
  );
  final a = html.AnchorElement(href: url)..download = name;
  html.document.body!.append(a);
  a.click();
  a.remove();
  Future.delayed(
    const Duration(seconds: 5),
    () => html.Url.revokeObjectUrl(url),
  );
}
