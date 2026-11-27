import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import '../../api/api.dart';
import '../../core/format.dart';
import '../../design/widgets/kit.dart';

/// Builds a PDF receipt for a transaction straight from backend data.
Future<List<int>> buildReceiptPdf(Json t) async {
  final doc = pw.Document(title: 'Knock receipt ${t['reference']}', author: 'Knock');
  final d = (t['details'] as Map?) ?? const {};
  final rows = <(String, String)>[
    ('Reference', t['reference'] as String),
    ('Transaction ID', t['id'] as String),
    ('Type', F.txnType(t['type'] as String)),
    ('Description', '${t['title']}${t['subtitle'] == null ? '' : ' · ${t['subtitle']}'}'),
    ('Amount', F.ngnExact(t['amount'] as int).replaceAll('₦', 'NGN ')),
    ('Fee', F.ngnExact(t['fee'] as int? ?? 0).replaceAll('₦', 'NGN ')),
    ('Status', F.status(t['status'] as String)),
    ('Date', F.dateTime(t['createdAt'] as String)),
    if (d['settlement'] != null) ('Settlement', d['settlement'].toString()),
    if (d['rateKobo'] != null) ('Rate', F.rate(d['rateKobo'] as int, d['currency'] as String).replaceAll('₦', 'NGN ')),
  ];
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a5,
    build: (c) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Knock', style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold, color: PdfColor.fromInt(0xFF00B03C))),
        pw.SizedBox(height: 4),
        pw.Text('Transaction receipt', style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700)),
        pw.SizedBox(height: 18),
        for (final (k, v) in rows)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 5),
            child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
              pw.SizedBox(width: 110, child: pw.Text(k, style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700))),
              pw.Expanded(child: pw.Text(v, style: const pw.TextStyle(fontSize: 10))),
            ]),
          ),
        pw.Spacer(),
        pw.Divider(color: PdfColors.grey400),
        pw.Text('SANDBOX RECEIPT. Prototype only, no real money moved. Questions? +44 7575 895007', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
      ],
    ),
  ));
  return doc.save();
}

Future<void> shareReceipt(BuildContext context, Json t) async {
  try {
    final bytes = await buildReceiptPdf(t);
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(Uint8List.fromList(bytes), mimeType: 'application/pdf', name: 'Knock-${t['reference']}.pdf')],
      fileNameOverrides: ['Knock-${t['reference']}.pdf'],
      subject: 'Knock receipt ${t['reference']}',
    ));
  } catch (e) {
    if (context.mounted) toast(context, 'Could not share the receipt on this device.', error: true);
  }
}

Future<void> shareText(BuildContext context, String text, {String? subject}) async {
  try {
    await SharePlus.instance.share(ShareParams(text: text, subject: subject));
  } catch (_) {
    if (context.mounted) toast(context, 'Sharing is not available here. The link was copied instead.');
  }
}
