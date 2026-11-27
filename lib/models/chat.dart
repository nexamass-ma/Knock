import 'dart:typed_data';

import 'quote.dart';

enum Speaker { user, knock }

sealed class ChatContent {
  const ChatContent();
}

class TextContent extends ChatContent {
  const TextContent(this.text);
  final String text;
}

class ImageContent extends ChatContent {
  const ImageContent(this.bytes, this.label);
  final Uint8List bytes;
  final String label;
}

/// KNOCK asks the user to upload a gift card photo.
class UploadRequestContent extends ChatContent {
  const UploadRequestContent(this.title, this.detail);
  final String title;
  final String detail;
}

class ScanResultContent extends ChatContent {
  const ScanResultContent(this.result);
  final GiftCardScanResult result;
}

class QuoteContent extends ChatContent {
  const QuoteContent(this.quote);
  final Quote quote;
}

class ReceiptContent extends ChatContent {
  const ReceiptContent(this.receipt);
  final TransactionReceipt receipt;
}

class NoticeContent extends ChatContent {
  const NoticeContent(this.text, {this.isError = false});
  final String text;
  final bool isError;
}

class ChatMessage {
  ChatMessage(this.speaker, this.content, {List<String>? replies})
    : id = '${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
      quickReplies = replies ?? const [],
      at = DateTime.now();

  static int _seq = 0;

  final String id;
  final Speaker speaker;
  final ChatContent content;
  final List<String> quickReplies;
  final DateTime at;
}

class GiftCardScanResult {
  const GiftCardScanResult({
    required this.brandId,
    required this.brandName,
    required this.faceValueUsd,
    required this.cardType,
    required this.region,
    required this.confidence,
  });
  final String brandId;
  final String brandName;
  final int faceValueUsd;
  final String cardType;
  final String region;
  final double confidence;
}
