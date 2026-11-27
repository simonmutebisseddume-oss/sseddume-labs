import 'dart:typed_data';

import 'package:barcode/barcode.dart' show Barcode;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/util.dart';
import '../../data/repos.dart';

enum LabelSheet { a4, thermal }

class LabelItem {
  LabelItem({required this.name, required this.priceText, required this.code});
  final String name;
  final String priceText;
  final String code;

  factory LabelItem.fromProduct(Product p) {
    final u = p.defaultUnit;
    return LabelItem(
      name: p.name,
      priceText: '${fmtUgx(u.price)} / ${u.name}',
      code: p.barcode ?? '',
    );
  }
}

pw.Widget _label(String business, LabelItem l, double w, double h, bool qr) {
  final encoded = l.code.trim().isEmpty ? 'NO-CODE' : l.code.trim();
  return pw.Container(
    width: w,
    height: h,
    padding: const pw.EdgeInsets.all(4),
    decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.3, color: PdfColors.grey500)),
    child: pw.Column(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text(business, maxLines: 1, style: pw.TextStyle(fontSize: 6.5, color: PdfColors.grey700)),
        pw.Text(l.name, maxLines: 1, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        pw.Text(l.priceText, maxLines: 1, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        pw.Expanded(
          child: pw.Padding(
            padding: const pw.EdgeInsets.only(top: 2),
            child: pw.BarcodeWidget(
              barcode: qr ? Barcode.qrCode() : Barcode.code128(),
              data: encoded,
              drawText: !qr,
              textStyle: const pw.TextStyle(fontSize: 6),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Builds a printable PDF: [copies] stickers per item.
Future<Uint8List> buildLabelsPdf({
  required String businessName,
  required List<LabelItem> items,
  required int copies,
  required LabelSheet sheet,
  required bool qr,
}) async {
  final doc = pw.Document(title: '$businessName labels', author: AppConfig.platformName);
  final safeCopies = copies.clamp(1, 99);
  final all = [
    for (final i in items)
      for (var c = 0; c < safeCopies; c++) i,
  ];

  if (sheet == LabelSheet.thermal) {
    // One 50x30 mm sticker per page for thermal label printers.
    final fmt = PdfPageFormat(50 * PdfPageFormat.mm, 30 * PdfPageFormat.mm, marginAll: 1.5 * PdfPageFormat.mm);
    for (final l in all) {
      doc.addPage(
        pw.Page(
          pageFormat: fmt,
          build: (_) => _label(businessName, l, fmt.availableWidth, fmt.availableHeight, qr),
        ),
      );
    }
  } else {
    // A4 sheet of 70 x 36 mm stickers.
    const w = 70 * PdfPageFormat.mm;
    const h = 36 * PdfPageFormat.mm;
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.copyWith(
          marginLeft: 0,
          marginRight: 0,
          marginTop: 8 * PdfPageFormat.mm,
          marginBottom: 8 * PdfPageFormat.mm,
        ),
        build: (_) => [
          pw.Wrap(children: [for (final l in all) _label(businessName, l, w, h, qr)]),
        ],
      ),
    );
  }
  return doc.save();
}

/// Preview + print/share page for sticker sheets.
class LabelsPage extends StatefulWidget {
  const LabelsPage({super.key, required this.businessName, required this.items});
  final String businessName;
  final List<LabelItem> items;
  @override
  State<LabelsPage> createState() => _LabelsPageState();
}

class _LabelsPageState extends State<LabelsPage> {
  LabelSheet _sheet = LabelSheet.a4;
  bool _qr = false;
  int _copies = 1;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Print labels')),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SegmentedButton<LabelSheet>(
                    segments: const [
                      ButtonSegment(value: LabelSheet.a4, label: Text('A4 sheet')),
                      ButtonSegment(value: LabelSheet.thermal, label: Text('Thermal 50×30')),
                    ],
                    selected: {_sheet},
                    onSelectionChanged: (s) => setState(() => _sheet = s.first),
                  ),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Barcode')),
                      ButtonSegment(value: true, label: Text('QR')),
                    ],
                    selected: {_qr},
                    onSelectionChanged: (s) => setState(() => _qr = s.first),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Copies'),
                      IconButton(
                        onPressed: _copies > 1 ? () => setState(() => _copies--) : null,
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('$_copies'),
                      IconButton(
                        onPressed: _copies < 99 ? () => setState(() => _copies++) : null,
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: PdfPreview(
                key: ValueKey('$_sheet$_qr$_copies'),
                build: (_) => buildLabelsPdf(
                  businessName: widget.businessName,
                  items: widget.items,
                  copies: _copies,
                  sheet: _sheet,
                  qr: _qr,
                ),
                canChangePageFormat: false,
                canChangeOrientation: false,
                canDebug: false,
                pdfFileName: 'labels.pdf',
              ),
            ),
          ],
        ),
      );
}
