// lib/features/checkout/screens/qris_display_screen.dart
import 'package:crclib/catalog.dart'; // Pastikan crclib di pubspec
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert'; // Untuk utf8.encode
import 'package:aplikasir_mobile/helper/db_helper.dart';
import 'package:aplikasir_mobile/model/transaction_model.dart';
import 'package:aplikasir_mobile/model/product_model.dart'; // Jika update stok di sini
import 'checkout_success_screen.dart';

class QrisDisplayScreen extends StatefulWidget {
  final double totalAmount;
  final int userId;
  final Map<int, int> cartQuantities;
  final List<Product> cartProducts;
  final int? transactionIdToUpdate; // ID Hutang yang akan dibayar (opsional)

  const QrisDisplayScreen({
    super.key,
    required this.totalAmount,
    required this.userId,
    required this.cartQuantities,
    required this.cartProducts,
    this.transactionIdToUpdate,
  });

  @override
  State<QrisDisplayScreen> createState() => _QrisDisplayScreenState();
}

class _QrisDisplayScreenState extends State<QrisDisplayScreen> {
  final NumberFormat currencyFormatter =
      NumberFormat.currency(locale: 'id_ID', symbol: 'Rp ', decimalDigits: 0);
  final Color _primaryColor = Colors.blue.shade700;

  String? _rawQrisTemplate;
  String? qrData; // Payload QRIS dinamis
  bool _isQrisLoading = true;
  String? _qrisError;
  bool _isProcessing = false; // Loading untuk simpan transaksi

  static const String qrisDataKey = 'raw_qris_data'; // Pastikan key ini sama dengan di QrisSetupScreen

  @override
  void initState() {
    super.initState();
    _initializeAndGenerateQris();
  }

  Future<void> _initializeAndGenerateQris() async {
    if (!mounted) return;
    setState(() {
      _isQrisLoading = true;
      _qrisError = null;
      qrData = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      _rawQrisTemplate = prefs.getString(qrisDataKey);
      if (_rawQrisTemplate == null || _rawQrisTemplate!.isEmpty) {
        throw Exception("Data QRIS belum diatur. Silakan atur di menu Kelola > QRIS.");
      }
      _generateDynamicQrisDataFromStringManipulation();
    } catch (e) {
      if (mounted) {
        setState(() {
          _qrisError = e.toString().replaceFirst("Exception: ", "");
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isQrisLoading = false);
      }
    }
  }

  void _generateDynamicQrisDataFromStringManipulation() {
    // ... (Logika generate QRIS SAMA seperti sebelumnya) ...
    // Pastikan ini diadaptasi dari logika PHP yang sudah ada di file Anda
    if (_rawQrisTemplate == null) {
      if (mounted) setState(() => _qrisError = "Template QRIS tidak ditemukan.");
      return;
    }
    try {
      if (_rawQrisTemplate!.length <= 4) throw Exception("Template QRIS tidak valid (terlalu pendek).");
      String qrisWithoutCrc = _rawQrisTemplate!.substring(0, _rawQrisTemplate!.length - 4);
      String payloadStep1 = qrisWithoutCrc.replaceFirst('010211', '010212');

      const String countryCodeTag = '58';
      int insertPos = payloadStep1.indexOf(countryCodeTag);

      if (insertPos == -1 || insertPos % 2 != 0 || payloadStep1.length < insertPos + 4) {
        const String merchantNameTag = '59';
        insertPos = payloadStep1.indexOf(merchantNameTag);
        if (insertPos == -1 || insertPos % 2 != 0 || payloadStep1.length < insertPos + 4) {
          throw Exception("Tag '58' atau '59' tidak ditemukan/valid dalam template QRIS.");
        }
      }

      String amountValue = widget.totalAmount.toInt().toString();
      if (amountValue.isEmpty || widget.totalAmount < 0) amountValue = '0';
      String amountLength = amountValue.length.toString().padLeft(2, '0');
      String amountTag = '54$amountLength$amountValue';

      String payloadBeforeCrc = payloadStep1.substring(0, insertPos) + amountTag + payloadStep1.substring(insertPos);

      List<int> bytes = utf8.encode(payloadBeforeCrc);
      var crcCalculator = Crc16(); // Default adalah CRC-16/CCITT-FALSE
      var crcValue = crcCalculator.convert(bytes);
      String crcString = crcValue.toRadixString(16).toUpperCase().padLeft(4, '0');

      final String finalPayload = payloadBeforeCrc + '6304' + crcString;

      if (mounted) {
        setState(() {
          qrData = finalPayload;
          _qrisError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _qrisError = "Gagal memproses QRIS: ${e.toString().replaceFirst("Exception: ", "")}";
          qrData = null;
        });
      }
    }
  }

  void _showSnackbar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.poppins()),
        backgroundColor: isError ? Colors.redAccent : Colors.green,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<void> _confirmManualPayment() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      bool isDebtPayment = widget.transactionIdToUpdate != null;
      List<Map<String, dynamic>> detailItems = [];
      double totalModal = 0;

      if (!isDebtPayment) {
        widget.cartProducts.forEach((product) {
          final quantity = widget.cartQuantities[product.id] ?? 0;
          if (quantity > 0) {
            detailItems.add({
              'product_id': product.id,
              'nama_produk': product.namaProduk,
              'kode_produk': product.kodeProduk,
              'harga_jual': product.hargaJual,
              'harga_modal': product.hargaModal,
              'quantity': quantity,
              'subtotal': product.hargaJual * quantity,
            });
            totalModal += product.hargaModal * quantity;
          }
        });
      } else {
        detailItems = [{
          'paid_debt_transaction_id': widget.transactionIdToUpdate,
          'paid_amount': widget.totalAmount
        }];
        totalModal = 0;
      }

      final transaction = TransactionModel(
        idPengguna: widget.userId,
        tanggalTransaksi: DateTime.now(),
        totalBelanja: widget.totalAmount,
        totalModal: totalModal,
        metodePembayaran: isDebtPayment ? 'Pembayaran Kredit QRIS' : 'QRIS',
        statusPembayaran: 'Lunas',
        idPelanggan: null,
        detailItems: detailItems,
        jumlahBayar: widget.totalAmount,
        jumlahKembali: 0,
        idTransaksiHutang: widget.transactionIdToUpdate,
      );

      final transactionId = await DatabaseHelper.instance.insertTransaction(transaction);

      if (isDebtPayment) {
        if (mounted) {
          Navigator.pop(context, true); // Sinyal sukses ke DebtDetailScreen
        }
        return;
      }
      
      if (!isDebtPayment) {
           for (var item in detailItems) {
            await DatabaseHelper.instance.updateProductStock(item['product_id'], item['quantity']);
          }
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => CheckoutSuccessScreen(
            transactionId: transactionId,
            userId: widget.userId,
            paymentMethod: 'QRIS', // Atau metode yang sesuai
            changeAmount: null,
          ),
        ),
      );
    } catch (e) {
      print("Error processing QRIS confirmation: $e");
      if (mounted) {
        _showSnackbar("Terjadi kesalahan: ${e.toString()}", isError: true);
        setState(() => _isProcessing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Pembayaran QRIS', style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: _primaryColor)),
        backgroundColor: Colors.white,
        foregroundColor: _primaryColor,
        elevation: 1.0,
        shadowColor: Colors.black26,
        surfaceTintColor: Colors.white,
        centerTitle: true,
      ),
      backgroundColor: const Color(0xFFF7F8FC),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text("Scan QR Code Berikut", style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text("Total Pembayaran: ${currencyFormatter.format(widget.totalAmount)}", style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w500, color: _primaryColor), textAlign: TextAlign.center),
            const SizedBox(height: 15),
            Text("(Aplikasi pembayaran akan otomatis mendeteksi jumlah ini)", style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade600), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Container( // QR Code Display Area
              height: 250,
              width: 250,
              alignment: Alignment.center,
              child: _isQrisLoading
                  ? const Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircularProgressIndicator(), SizedBox(height: 15), Text("Memuat QRIS...")])
                  : _qrisError != null
                      ? Container(
                          padding: const EdgeInsets.all(15.0),
                          decoration: BoxDecoration(border: Border.all(color: Colors.red.shade200), borderRadius: BorderRadius.circular(8), color: Colors.red.shade50),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Icon(Icons.error_outline, color: Colors.red.shade700, size: 40),
                            const SizedBox(height: 10),
                            Text(_qrisError!, style: GoogleFonts.poppins(color: Colors.red.shade800, fontSize: 14), textAlign: TextAlign.center),
                          ]))
                      : qrData != null
                          ? Container( // Actual QR Image
                              padding: const EdgeInsets.all(15),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.grey.withOpacity(0.3), spreadRadius: 1, blurRadius: 5, offset: const Offset(0, 2))]),
                              child: QrImageView(
                                data: qrData!,
                                version: QrVersions.auto,
                                size: 220.0,
                                gapless: false,
                                errorCorrectionLevel: QrErrorCorrectLevel.M,
                                errorStateBuilder: (cxt, err) => Center(child: Text("Gagal membuat QR Code.", textAlign: TextAlign.center, style: GoogleFonts.poppins(color: Colors.red))),
                              ),
                            )
                          : Center(child: Text("Gagal memuat data QRIS.", style: GoogleFonts.poppins(color: Colors.orange.shade800))),
            ),
            const SizedBox(height: 30),
            const Spacer(),
            SizedBox( // Tombol Konfirmasi Manual
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: _isProcessing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check_circle_outline),
                label: Text(_isProcessing ? "Memproses..." : "Pembayaran Diterima (Manual)", style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
                onPressed: _isQrisLoading || _qrisError != null || _isProcessing ? null : _confirmManualPayment,
                style: ElevatedButton.styleFrom(backgroundColor: (_isQrisLoading || _qrisError != null) ? Colors.grey : Colors.green.shade600, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox( // Tombol Batal
              width: double.infinity,
              child: TextButton(
                child: Text("Batal", style: GoogleFonts.poppins(color: Colors.red.shade600)),
                onPressed: _isProcessing ? null : () => Navigator.pop(context, false), // Kirim 'false' jika batal
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 10)),
              ),
            )
          ],
        ),
      ),
    );
  }
}