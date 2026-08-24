import 'package:flutter/material.dart';

import 'package:webview_flutter/webview_flutter.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class PageWebView extends StatefulWidget {
  final String url;
  final String title;

  const PageWebView({super.key, required this.url, required this.title});

  @override
  State<PageWebView> createState() => _PageWebViewState();
}

class _PageWebViewState extends State<PageWebView> {
  late WebViewController webViewController;
  int progress = 0;

  @override
  initState() {
    webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int p) {
            if (mounted) {
              setState(() {
                progress = p;
              });
            }
          },
          onPageStarted: (String url) {},
          onPageFinished: (String url) {},
          onHttpError: (HttpResponseError error) {},
          onWebResourceError: (WebResourceError error) {},
          onNavigationRequest: (NavigationRequest request) {
            if (request.url != widget.url) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title), backgroundColor: context.omi.bgPrimary),
      backgroundColor: context.omi.bgPrimary,
      body: progress != 100
          ? Center(child: CircularProgressIndicator(color: t.textPrimary))
          : WebViewWidget(controller: webViewController),
    );
  }
}
