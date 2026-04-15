import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';
import 'api_client.dart';

class PdfViewerPage extends StatefulWidget {
  final String url;
  final String fileName;
  const PdfViewerPage({super.key, required this.url, required this.fileName});

  @override
  State<PdfViewerPage> createState() => _PdfViewerPageState();
}

class _PdfViewerPageState extends State<PdfViewerPage> {
  PdfController? _controller;
  bool _loading = true;
  String? _error;
  int _currentPage = 1;
  int _totalPages = 0;

  @override
  void initState() {
    super.initState();
    _loadPdf();
  }

  Future<void> _loadPdf() async {
    try {
      final response = await ApiClient.get(Uri.parse(widget.url));
      if (response.statusCode == 200) {
        setState(() {
          _controller = PdfController(
            document: PdfDocument.openData(response.bodyBytes),
          );
          _loading = false;
        });
      } else {
        setState(() {
          _error = 'PDF를 불러올 수 없습니다 (${response.statusCode})';
          _loading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'PDF 로딩 오류: $e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[200],
      appBar: AppBar(
        title: Text(widget.fileName, style: const TextStyle(fontSize: 14)),
        actions: [
          if (!_loading && _error == null && _totalPages > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(
                  '$_currentPage / $_totalPages',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(_error!, textAlign: TextAlign.center),
                    ],
                  ),
                )
              : PdfView(
                  controller: _controller!,
                  onDocumentLoaded: (doc) {
                    setState(() => _totalPages = doc.pagesCount);
                  },
                  onPageChanged: (page) {
                    setState(() => _currentPage = page);
                  },
                ),
    );
  }
}
