import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_scope.dart';
import '../../design/tokens.dart';
import '../../design/widgets/surfaces.dart';
import '../../models/catalog.dart';
import '../../models/chat.dart';
import '../../models/quote.dart';
import '../../state/assistant_controller.dart';
import '../../state/shell_controller.dart';
import '../auth/wordmark.dart';
import 'transaction_widgets.dart';

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  late ShellController _shell;
  late AssistantController _chat;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = context.app;
    _shell = app.shell;
    _chat = app.assistant;
    _shell.removeListener(_onShell);
    _shell.addListener(_onShell);
    _chat.removeListener(_onChat);
    _chat.addListener(_onChat);
  }

  @override
  void dispose() {
    _shell.removeListener(_onShell);
    _chat.removeListener(_onChat);
    _text.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onShell() {
    if (_shell.tab != AppTab.knock || _shell.pendingLaunch == null) return;
    final launch = _shell.takeLaunch()!;
    _chat.launch(launch.flow, fields: launch.fields);
  }

  void _onChat() {
    // Follow the conversation: scroll now, and again once quick replies
    // have animated in and shrunk the list.
    WidgetsBinding.instance.addPostFrameCallback((_) => _toBottom());
    Future<void>.delayed(KnockMotion.base + const Duration(milliseconds: 40), _toBottom);
  }

  void _toBottom() {
    if (!mounted || !_scroll.hasClients) return;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final target = _scroll.position.maxScrollExtent;
    if ((target - _scroll.offset).abs() < 2) return;
    if (reduce) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(target, duration: KnockMotion.slow, curve: KnockMotion.curve);
    }
  }

  void _send([String? value]) {
    final v = value ?? _text.text;
    if (v.trim().isEmpty) return;
    HapticFeedback.selectionClick();
    _chat.send(v);
    if (value == null) _text.clear();
  }

  Future<void> _attach() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined, color: KnockColors.green),
              title: const Text('Take a photo'),
              onTap: () => Navigator.of(ctx).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined, color: KnockColors.green),
              title: const Text('Choose from library'),
              onTap: () => Navigator.of(ctx).pop(ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null) return;
    await _pick(source);
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final file = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 85);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      await _chat.attachImage(bytes);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the camera or photos. Check permissions and try again.')),
      );
    }
  }

  Future<void> _confirm(Quote q) async {
    final proof = await showAuthorizeSheet(context, q);
    if (proof == null) return;
    await _chat.confirm(q, proof);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _chat,
      builder: (context, _) {
        final msgs = _chat.messages;
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                _Header(onClose: () => _shell.select(AppTab.home), onClear: msgs.isEmpty ? null : _chat.clear),
                Expanded(
                  child: msgs.isEmpty
                      ? _Welcome(starters: _chat.starters, onTap: _send)
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 12),
                          itemCount: msgs.length + (_chat.thinking ? 1 : 0),
                          itemBuilder: (context, i) {
                            if (i == msgs.length) return const _Typing();
                            final m = msgs[i];
                            final prevSame = i > 0 && msgs[i - 1].speaker == m.speaker;
                            return _MessageView(
                              key: ValueKey(m.id),
                              message: m,
                              showAvatar: !prevSame,
                              chat: _chat,
                              onConfirm: _confirm,
                              onPick: _pick,
                            );
                          },
                        ),
                ),
                _QuickReplies(replies: _chat.quickReplies, onTap: _send),
                _Composer(
                  controller: _text,
                  focus: _focus,
                  busy: _chat.thinking,
                  highlightAttach: _chat.awaitingImage,
                  onSend: _send,
                  onAttach: _attach,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose, this.onClear});
  final VoidCallback onClose;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back to home',
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 28),
          ),
          const Spacer(),
          Flexible(
            flex: 6,
            child: Column(
              children: [
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KnockMark(size: 22),
                    SizedBox(width: 8),
                    Text('KNOCK', style: KnockText.headline),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(color: KnockColors.green, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'Quotes from KNOCK servers',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: KnockText.micro.copyWith(fontWeight: FontWeight.w400),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Spacer(),
          IconButton(tooltip: 'New conversation', onPressed: onClear, icon: const Icon(Icons.edit_note_rounded)),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.starters, required this.onTap});
  final List<String> starters;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final name = context.app.session.firstName;
    return ListView(
      padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 24, KnockSpace.gutter, 16),
      children: [
        Center(
          child: Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const RadialGradient(colors: [Color(0x4400B03C), Color(0x0000B03C)]),
              border: Border.all(color: KnockColors.stroke),
            ),
            padding: const EdgeInsets.all(18),
            child: const KnockMark(size: 56),
          ),
        ),
        const SizedBox(height: 20),
        Text('What can I do for you, $name?', style: KnockText.title, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'Tell me in your own words. I fetch the price from KNOCK, you check it, and nothing moves until you confirm.',
          style: KnockText.caption,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 28),
        Text('TRY', style: KnockText.micro),
        const SizedBox(height: 10),
        for (final s in starters)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: KnockCard(
              onTap: () => onTap(s),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              radius: KnockRadius.md,
              child: Row(
                children: [
                  Expanded(child: Text(s, style: KnockText.body)),
                  const Icon(Icons.north_east_rounded, size: 16, color: KnockColors.textTertiary),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({
    super.key,
    required this.message,
    required this.showAvatar,
    required this.chat,
    required this.onConfirm,
    required this.onPick,
  });

  final ChatMessage message;
  final bool showAvatar;
  final AssistantController chat;
  final ValueChanged<Quote> onConfirm;
  final ValueChanged<ImageSource> onPick;

  @override
  Widget build(BuildContext context) {
    final mine = message.speaker == Speaker.user;
    final maxW = MediaQuery.sizeOf(context).width * (mine ? 0.75 : 0.86);

    final Widget body = switch (message.content) {
      TextContent(:final text) => _Bubble(text: text, mine: mine),
      ImageContent(:final bytes, :final label) => Semantics(
        label: label,
        image: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(KnockRadius.md),
          child: Image.memory(bytes, width: 200, height: 140, fit: BoxFit.cover),
        ),
      ),
      UploadRequestContent(:final title, :final detail) => _UploadCard(title: title, detail: detail, onPick: onPick),
      ScanResultContent(:final result) => _ScanCard(result: result),
      QuoteContent(:final quote) => QuoteCard(
        quote: quote,
        used: chat.usedQuotes.contains(quote.id),
        onConfirm: () => onConfirm(quote),
        onRefresh: () => chat.refreshQuote(quote),
      ),
      ReceiptContent(:final receipt) => ReceiptCard(receipt: receipt),
      NoticeContent(:final text, :final isError) => _Notice(text: text, isError: isError),
    };

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: KnockMotion.base,
      curve: KnockMotion.curve,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 10), child: child),
      ),
      child: Padding(
        padding: EdgeInsets.only(top: showAvatar ? 14 : 6),
        child: Row(
          mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!mine)
              SizedBox(
                width: 34,
                child: showAvatar
                    ? Container(
                        width: 28,
                        height: 28,
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: KnockColors.surfaceRaised,
                          shape: BoxShape.circle,
                          border: Border.all(color: KnockColors.stroke),
                        ),
                        child: const KnockMark(size: 20),
                      )
                    : null,
              ),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxW),
                child: body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.text, required this.mine});
  final String text;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    const r = Radius.circular(20);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: BoxDecoration(
        color: mine ? KnockColors.green : KnockColors.surfaceRaised,
        borderRadius: BorderRadius.only(
          topLeft: mine ? r : const Radius.circular(6),
          topRight: r,
          bottomLeft: r,
          bottomRight: mine ? const Radius.circular(6) : r,
        ),
      ),
      child: Text(text, style: KnockText.body.copyWith(color: mine ? KnockColors.onGreen : KnockColors.textPrimary)),
    );
  }
}

class _UploadCard extends StatelessWidget {
  const _UploadCard({required this.title, required this.detail, required this.onPick});
  final String title;
  final String detail;
  final ValueChanged<ImageSource> onPick;

  @override
  Widget build(BuildContext context) {
    return KnockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: KnockColors.orangeSoft, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.document_scanner_outlined, color: KnockColors.orange, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: KnockText.bodyStrong)),
            ],
          ),
          const SizedBox(height: 10),
          Text(detail, style: KnockText.caption),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: KnockButton(
                  label: 'Camera',
                  icon: Icons.photo_camera_outlined,
                  onPressed: () => onPick(ImageSource.camera),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: KnockButton(
                  label: 'Photos',
                  icon: Icons.photo_library_outlined,
                  style: KnockButtonStyle.secondary,
                  onPressed: () => onPick(ImageSource.gallery),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScanCard extends StatelessWidget {
  const _ScanCard({required this.result});
  final GiftCardScanResult result;

  @override
  Widget build(BuildContext context) {
    final brand = GiftCardCatalog.byId(result.brandId);
    return KnockCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.verified_outlined, size: 18, color: KnockColors.green),
              const SizedBox(width: 8),
              const Expanded(child: Text('Card identified', style: KnockText.bodyStrong)),
              const MockBadge(label: 'MOCK SCAN'),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              GlyphAvatar(glyph: brand?.glyph ?? '?', tint: brand?.tint ?? KnockColors.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${result.brandName} gift card', style: KnockText.bodyStrong),
                    Text('\$${result.faceValueUsd} · ${result.region} · ${result.cardType}', style: KnockText.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('Match confidence', style: KnockText.micro),
              const Spacer(),
              Text(
                '${(result.confidence * 100).round()}%',
                style: KnockText.micro.copyWith(color: KnockColors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: result.confidence,
              minHeight: 5,
              color: KnockColors.green,
              backgroundColor: KnockColors.surfaceHigh,
            ),
          ),
          const SizedBox(height: 12),
          Text('Is this right? Our partner verifies the card before any payout.', style: KnockText.caption),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.isError});
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final c = isError ? KnockColors.orange : KnockColors.textSecondary;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(KnockRadius.md),
          border: Border.all(color: c.withValues(alpha: 0.25)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(isError ? Icons.error_outline_rounded : Icons.info_outline_rounded, color: c, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: KnockText.body)),
          ],
        ),
      ),
    );
  }
}

class _Typing extends StatefulWidget {
  const _Typing();
  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'KNOCK is working',
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(left: 34, top: 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(color: KnockColors.surfaceRaised, borderRadius: BorderRadius.circular(18)),
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 2.5),
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: KnockColors.textSecondary.withValues(
                          alpha: 0.35 + 0.65 * (((_c.value * 3 - i) % 3) < 1 ? 1 - ((_c.value * 3 - i) % 1) : 0),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickReplies extends StatelessWidget {
  const _QuickReplies({required this.replies, required this.onTap});
  final List<String> replies;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: KnockMotion.base,
      curve: KnockMotion.curve,
      child: replies.isEmpty
          ? const SizedBox(width: double.infinity)
          : SizedBox(
              height: 46,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: KnockSpace.gutter, vertical: 4),
                itemCount: replies.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => ActionChip(
                  label: Text(replies[i]),
                  onPressed: () => onTap(replies[i]),
                  labelStyle: KnockText.caption.copyWith(color: KnockColors.textPrimary, fontWeight: FontWeight.w600),
                  backgroundColor: KnockColors.surfaceRaised,
                  side: const BorderSide(color: KnockColors.greenSoft),
                  shape: const StadiumBorder(),
                ),
              ),
            ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.busy,
    required this.highlightAttach,
    required this.onSend,
    required this.onAttach,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final bool highlightAttach;
  final void Function([String?]) onSend;
  final VoidCallback onAttach;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
          decoration: BoxDecoration(
            color: KnockColors.surface,
            borderRadius: BorderRadius.circular(KnockRadius.xl),
            border: Border.all(color: KnockColors.stroke),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Semantics(
                button: true,
                label: 'Attach a photo',
                excludeSemantics: true,
                child: IconButton(
                  onPressed: onAttach,
                  icon: Icon(
                    Icons.add_photo_alternate_outlined,
                    color: highlightAttach ? KnockColors.orange : KnockColors.textSecondary,
                  ),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focus,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  style: KnockText.body,
                  decoration: const InputDecoration(
                    hintText: 'Message KNOCK',
                    filled: false,
                    border: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                  ),
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, v, _) {
                  final enabled = v.text.trim().isNotEmpty && !busy;
                  return Semantics(
                    button: true,
                    enabled: enabled,
                    label: 'Send',
                    excludeSemantics: true,
                    child: AnimatedContainer(
                      duration: KnockMotion.fast,
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: enabled ? KnockColors.green : KnockColors.surfaceHigh,
                      ),
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        onPressed: enabled ? () => onSend() : null,
                        icon: Icon(
                          Icons.arrow_upward_rounded,
                          color: enabled ? KnockColors.onGreen : KnockColors.textTertiary,
                          size: 22,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
