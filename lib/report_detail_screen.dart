import 'package:flutter/material.dart';

import 'models/tracking_models.dart';
import 'reports_repository.dart';

/// Visit report detail / edit (design screen 08). Stub — the read-only UI and
/// editing land in the next steps.
class ReportDetailScreen extends StatefulWidget {
  final String reportId;

  const ReportDetailScreen({super.key, required this.reportId});

  @override
  State<ReportDetailScreen> createState() => _ReportDetailScreenState();
}

class _ReportDetailScreenState extends State<ReportDetailScreen> {
  ReportDetail? _detail;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ReportsRepository.instance.reportDetail(widget.reportId);
      if (mounted) setState(() => _detail = d);
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(d?.customerName ?? '')),
      body: _error
          ? const Center(child: Icon(Icons.error_outline))
          : d == null
              ? const Center(child: CircularProgressIndicator())
              : const Center(child: Text('detail — step 2')),
    );
  }
}
