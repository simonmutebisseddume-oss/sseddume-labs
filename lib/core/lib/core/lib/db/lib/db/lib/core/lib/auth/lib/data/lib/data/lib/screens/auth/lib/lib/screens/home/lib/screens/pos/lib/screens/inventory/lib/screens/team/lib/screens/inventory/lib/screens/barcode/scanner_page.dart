import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen scanner used for checkout, stock-in and "scan to find".
///
/// [onCode] receives each distinct scan and returns a short message to show ("Added: Sugar 1 kg"),
/// or null. With [continuous] the camera stays open so a cashier can scan a whole basket; otherwise the
/// page closes after the first scan and returns the code.
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key, required this.title, this.onCode, this.continuous = true});
  final String title;
  final Future<String?> Function(String code)? onCode;
  final bool continuous;

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final _ctl = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    detectionTimeoutMs: 400,
    facing: CameraFacing.back,
    formats: const [
      BarcodeFormat.qrCode,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
    ],
  );

  String? _last;
  DateTime _lastAt = DateTime(2000);
  String? _msg;
  bool _busy = false;

  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_busy) return;
    final code = cap.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (code == null) return;
    final now = DateTime.now();
    // Ignore the same code re-read within 1.5s (holding the phone still), but allow a second
    // unit of the same item a moment later.
    if (code == _last && now.difference(_lastAt) < const Duration(milliseconds: 1500)) return;
    _last = code;
    _lastAt = now;
    _busy = true;
    HapticFeedback.mediumImpact();
    try {
      if (!widget.continuous) {
        if (mounted) Navigator.pop(context, code);
        return;
      }
      final m = await widget.onCode?.call(code);
      if (mounted) setState(() => _msg = m ?? code);
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text(widget.title),
          actions: [
            // Torch matters in dim shops and storerooms.
            ValueListenableBuilder<MobileScannerState>(
              valueListenable: _ctl,
              builder: (_, state, _) => IconButton(
                tooltip: 'Torch',
                icon: Icon(state.torchState == TorchState.on ? Icons.flash_on : Icons.flash_off),
                onPressed: _ctl.toggleTorch,
              ),
            ),
            IconButton(
              tooltip: 'Flip camera',
              icon: const Icon(Icons.cameraswitch_outlined),
              onPressed: _ctl.switchCamera,
            ),
          ],
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(controller: _ctl, onDetect: _onDetect),
            Center(
              child: Container(
                width: 260,
                height: 180,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFF00A884), width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            if (_msg != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 32,
                child: Material(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      _msg!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}
