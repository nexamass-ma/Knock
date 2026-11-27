import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../api/api.dart';
import '../../app/app_controller.dart';
import '../tokens.dart';
import 'states.dart';
import 'surfaces.dart';

export 'states.dart';
export 'surfaces.dart';

// ---------------------------------------------------------------------------
// Navigation with a soft spring transition.

Future<T?> go<T>(BuildContext context, Widget page, {bool replace = false}) {
  final route = KRoute<T>(page);
  return replace ? Navigator.of(context).pushReplacement(route) : Navigator.of(context).push(route);
}

class KRoute<T> extends PageRouteBuilder<T> {
  KRoute(Widget page)
    : super(
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => page,
        transitionsBuilder: (_, a, s, child) {
          final curved = CurvedAnimation(parent: a, curve: const _Spring(), reverseCurve: Curves.easeInCubic);
          return FadeTransition(
            opacity: CurvedAnimation(parent: a, curve: const Interval(0, 0.7, curve: Curves.easeOut)),
            child: SlideTransition(
              position: Tween(begin: const Offset(0.06, 0), end: Offset.zero).animate(curved),
              child: FadeTransition(
                opacity: Tween<double>(begin: 1, end: 0.6).animate(s),
                child: child,
              ),
            ),
          );
        },
      );
}

/// Critically damped spring with a hint of overshoot.
class _Spring extends Curve {
  const _Spring();
  @override
  double transformInternal(double t) {
    const damping = 7.0;
    return 1 - (1 + damping * t) * _exp(-damping * t) + 0.02 * _sin(t * 3.14159);
  }

  static double _exp(double x) {
    var r = 1.0, term = 1.0;
    for (var i = 1; i < 30; i++) {
      term *= x / i;
      r += term;
    }
    return r;
  }

  static double _sin(double x) => x - x * x * x / 6 + x * x * x * x * x / 120;
}

// ---------------------------------------------------------------------------
// Page scaffold

class KPage extends StatelessWidget {
  const KPage({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.bottom,
    this.padding = const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 32),
    this.onRefresh,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final List<Widget>? actions;
  final Widget? bottom;
  final EdgeInsets padding;
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    Widget list = ListView(
      padding: padding,
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      children: [
        if (subtitle != null) ...[Text(subtitle!, style: KnockText.caption), const SizedBox(height: 16)],
        ...children,
      ],
    );
    if (onRefresh != null) list = RefreshIndicator(onRefresh: onRefresh!, color: KnockColors.green, child: list);
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: SafeArea(top: false, child: list),
      bottomNavigationBar: bottom == null
          ? null
          : SafeArea(
              child: Padding(padding: const EdgeInsets.fromLTRB(KnockSpace.gutter, 8, KnockSpace.gutter, 12), child: bottom),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inputs

class KField extends StatefulWidget {
  const KField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.error,
    this.helper,
    this.password = false,
    this.keyboard,
    this.onChanged,
    this.prefix,
    this.suffix,
    this.autofill,
    this.maxLength,
    this.formatters,
    this.textInputAction,
    this.onSubmitted,
    this.maxLines = 1,
    this.enabled = true,
    this.capitalization = TextCapitalization.none,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? error;
  final String? helper;
  final bool password;
  final TextInputType? keyboard;
  final ValueChanged<String>? onChanged;
  final Widget? prefix;
  final Widget? suffix;
  final Iterable<String>? autofill;
  final int? maxLength;
  final List<TextInputFormatter>? formatters;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final int maxLines;
  final bool enabled;
  final TextCapitalization capitalization;
  final bool autofocus;

  @override
  State<KField> createState() => _KFieldState();
}

class _KFieldState extends State<KField> {
  bool _hidden = true;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label, style: KnockText.caption.copyWith(color: KnockColors.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          TextField(
            controller: widget.controller,
            obscureText: widget.password && _hidden,
            keyboardType: widget.keyboard,
            onChanged: widget.onChanged,
            autofillHints: widget.autofill,
            maxLength: widget.maxLength,
            inputFormatters: widget.formatters,
            textInputAction: widget.textInputAction,
            onSubmitted: widget.onSubmitted,
            maxLines: widget.password ? 1 : widget.maxLines,
            enabled: widget.enabled,
            textCapitalization: widget.capitalization,
            autofocus: widget.autofocus,
            style: KnockText.body,
            decoration: InputDecoration(
              hintText: widget.hint,
              counterText: '',
              prefixIcon: widget.prefix,
              errorText: widget.error,
              errorMaxLines: 3,
              enabledBorder: widget.error == null
                  ? null
                  : OutlineInputBorder(borderRadius: BorderRadius.circular(KnockRadius.md), borderSide: const BorderSide(color: KnockColors.loss)),
              suffixIcon: widget.password
                  ? IconButton(
                      tooltip: _hidden ? 'Show password' : 'Hide password',
                      icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: KnockColors.textSecondary),
                      onPressed: () => setState(() => _hidden = !_hidden),
                    )
                  : widget.suffix,
            ),
          ),
          if (widget.helper != null && widget.error == null) ...[
            const SizedBox(height: 6),
            Text(widget.helper!, style: KnockText.micro.copyWith(fontWeight: FontWeight.w400)),
          ],
        ],
      ),
    );
  }
}

class Choice<T> {
  const Choice(this.value, this.label, {this.icon, this.subtitle});
  final T value;
  final String label;
  final IconData? icon;
  final String? subtitle;
}

/// Wrap of selectable chips.
class ChoiceWrap<T> extends StatelessWidget {
  const ChoiceWrap({super.key, required this.choices, required this.selected, required this.onSelected});
  final List<Choice<T>> choices;
  final T? selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in choices)
          Semantics(
            selected: c.value == selected,
            button: true,
            child: GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                onSelected(c.value);
              },
              child: AnimatedContainer(
                duration: KnockMotion.base,
                curve: KnockMotion.curve,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: c.value == selected ? KnockColors.greenSoft : KnockColors.surfaceRaised,
                  borderRadius: BorderRadius.circular(KnockRadius.pill),
                  border: Border.all(color: c.value == selected ? KnockColors.green : KnockColors.stroke),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (c.icon != null) ...[
                      Icon(c.icon, size: 16, color: c.value == selected ? KnockColors.greenBright : KnockColors.textSecondary),
                      const SizedBox(width: 6),
                    ],
                    Text(c.label, style: KnockText.caption.copyWith(color: c.value == selected ? KnockColors.textPrimary : KnockColors.textSecondary, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Rows, chips, progress

class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.trailing,
    this.onTap,
    this.danger = false,
    this.iconColor,
    this.dense = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool danger;
  final Color? iconColor;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = danger ? KnockColors.loss : (iconColor ?? KnockColors.textPrimary);
    return Semantics(
      button: onTap != null,
      child: InkWell(
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        borderRadius: BorderRadius.circular(KnockRadius.md),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: dense ? 10 : 14, horizontal: 4),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 14)]
              else if (icon != null) ...[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(color: (danger ? KnockColors.loss : KnockColors.surfaceHigh).withValues(alpha: danger ? 0.12 : 1), borderRadius: BorderRadius.circular(12)),
                  child: Icon(icon, size: 20, color: color),
                ),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: KnockText.bodyStrong.copyWith(color: danger ? KnockColors.loss : null), maxLines: 2, overflow: TextOverflow.ellipsis),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: KnockText.caption, maxLines: 3, overflow: TextOverflow.ellipsis),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!]
              else if (onTap != null) const Icon(Icons.chevron_right_rounded, color: KnockColors.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.label});
  final String status;
  final String? label;

  static Color colorOf(String s) => switch (s) {
        'successful' || 'completed' || 'verified' || 'qualified' || 'delivered' || 'opened' || 'redeemed' || 'resolved' || 'credited' || 'available' || 'live' || 'claimed' => KnockColors.greenBright,
        'failed' || 'reversed' || 'rejected' || 'expired' || 'blocked' || 'action_needed' || 'action_required' => KnockColors.loss,
        'cancelled' || 'closed' || 'ended' || 'not_started' || 'traded' => KnockColors.textSecondary,
        _ => KnockColors.orange,
      };

  @override
  Widget build(BuildContext context) {
    final text = label ?? _label(status);
    return Tag(text, color: colorOf(status));
  }

  static String _label(String s) {
    final t = s.replaceAll('_', ' ');
    return t.isEmpty ? t : t[0].toUpperCase() + t.substring(1);
  }
}

class KProgress extends StatelessWidget {
  const KProgress(this.value, {super.key, this.height = 8, this.color = KnockColors.green});
  final double value;
  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      value: '${(value * 100).round()} percent',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: value.clamp(0, 1)),
          duration: KnockMotion.slow,
          curve: KnockMotion.curve,
          builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: height, color: color, backgroundColor: KnockColors.surfaceHigh),
        ),
      ),
    );
  }
}

class KeyValue extends StatelessWidget {
  const KeyValue(this.k, this.v, {super.key, this.strong = false, this.copy = false, this.valueColor});
  final String k;
  final String v;
  final bool strong;
  final bool copy;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 150), child: Text(k, style: KnockText.caption)),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(v, textAlign: TextAlign.right, style: (strong ? KnockText.bodyStrong : KnockText.body).copyWith(color: valueColor)),
            ),
          ),
          if (copy)
            InkResponse(
              radius: 18,
              onTap: () {
                Clipboard.setData(ClipboardData(text: v));
                toast(context, 'Copied');
              },
              child: const Padding(padding: EdgeInsets.only(left: 8, top: 2), child: Icon(Icons.copy_rounded, size: 16, color: KnockColors.textSecondary)),
            ),
        ],
      ),
    );
  }
}

class Note extends StatelessWidget {
  const Note(this.text, {super.key, this.icon = Icons.info_outline_rounded, this.color = KnockColors.textSecondary, this.action, this.onAction});
  final String text;
  final IconData icon;
  final Color color;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(KnockRadius.md), border: Border.all(color: color.withValues(alpha: 0.2))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: KnockText.caption.copyWith(color: KnockColors.textPrimary)),
                if (action != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: GestureDetector(onTap: onAction, child: Text(action!, style: KnockText.caption.copyWith(color: KnockColors.greenBright, fontWeight: FontWeight.w700))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small orange pill that marks sandbox data and actions.
class SandboxPill extends StatelessWidget {
  const SandboxPill({super.key, this.label = 'SANDBOX'});
  final String label;
  @override
  Widget build(BuildContext context) =>
      Semantics(label: 'Sandbox, not live', child: Tag(label, color: KnockColors.orange, icon: Icons.science_outlined));
}

// ---------------------------------------------------------------------------
// Feedback

void toast(BuildContext context, String message, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  if (error) HapticFeedback.heavyImpact();
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [
        Icon(error ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded, color: error ? KnockColors.loss : KnockColors.greenBright, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(message, style: KnockText.body)),
      ]),
    ));
}

/// Shows an API error. Tier errors offer the upgrade path directly.
void showApiError(BuildContext context, Object e, {VoidCallback? onUpgrade}) {
  if (e is ApiError && (e.code == 'tier_required' || (e.code == 'limit' && e.details?['tier'] != null))) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.verified_user_outlined, color: KnockColors.greenBright, size: 32),
              const SizedBox(height: 12),
              Text('A quick verification step', style: KnockText.title),
              const SizedBox(height: 8),
              Text(e.message, style: KnockText.body.copyWith(color: KnockColors.textSecondary)),
              const SizedBox(height: 20),
              KnockButton(
                label: 'Verify now',
                onPressed: () {
                  Navigator.pop(c);
                  (onUpgrade ?? () => _openVerification(context))();
                },
              ),
              const SizedBox(height: 8),
              KnockButton(label: 'Not now', style: KnockButtonStyle.ghost, onPressed: () => Navigator.pop(c)),
            ],
          ),
        ),
      ),
    );
    return;
  }
  toast(context, e is ApiError ? e.message : 'Something went wrong. Please try again.', error: true);
}

/// Set by the shell so any screen can open verification.
void Function(BuildContext)? openVerificationHook;
void _openVerification(BuildContext context) => openVerificationHook?.call(context);

// ---------------------------------------------------------------------------
// Data loading

/// Loads data from the API with skeleton, error and retry states. When
/// [live] is true it refetches whenever the backend reports a change.
class ApiView extends StatefulWidget {
  const ApiView({super.key, required this.load, required this.builder, this.live = true, this.skeleton, this.empty});
  final Future<Json> Function(KnockApi api) load;
  final Widget Function(BuildContext context, Json data, Future<void> Function() reload) builder;
  final bool live;
  final Widget? skeleton;
  final bool Function(Json)? empty;

  @override
  State<ApiView> createState() => ApiViewState();
}

class ApiViewState extends State<ApiView> {
  Json? _data;
  Object? _error;
  int _version = -1;
  bool _loading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context, listen: widget.live);
    if (app.dataVersion != _version) {
      _version = app.dataVersion;
      reload();
    }
  }

  Future<void> reload() async {
    if (_loading) return;
    _loading = true;
    try {
      final d = await widget.load(context.api);
      if (!mounted) return;
      setState(() {
        _data = d;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_data == null && _error != null) {
      return ErrorState(message: _error is ApiError ? (_error as ApiError).message : 'Please try again.', onRetry: () {
        setState(() => _error = null);
        reload();
      });
    }
    if (_data == null) return widget.skeleton ?? const SkeletonList();
    return AnimatedSwitcher(
      duration: KnockMotion.base,
      child: KeyedSubtree(key: const ValueKey('data'), child: widget.builder(context, _data!, reload)),
    );
  }
}

/// Ticking countdown driven by a server-provided number of seconds.
class Countdown extends StatefulWidget {
  const Countdown({super.key, required this.seconds, required this.builder, this.onDone});
  final int seconds;
  final Widget Function(int left) builder;
  final VoidCallback? onDone;

  @override
  State<Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<Countdown> {
  late DateTime _end;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _end = DateTime.now().add(Duration(seconds: widget.seconds));
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_left <= 0) {
        _t?.cancel();
        widget.onDone?.call();
      }
    });
  }

  @override
  void didUpdateWidget(Countdown old) {
    super.didUpdateWidget(old);
    if (old.seconds != widget.seconds) _end = DateTime.now().add(Duration(seconds: widget.seconds));
  }

  int get _left => _end.difference(DateTime.now()).inSeconds.clamp(0, 1 << 30);

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_left);
}

// ---------------------------------------------------------------------------
// Visual helpers

class BrandBadge extends StatelessWidget {
  const BrandBadge({super.key, required this.glyph, required this.color, this.size = 44});
  final String glyph;
  final int color;
  final double size;

  @override
  Widget build(BuildContext context) => GlyphAvatar(glyph: glyph, tint: Color(color), size: size);
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 40, this.highlight = false});
  final String name;
  final double size;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final initials = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).map((p) => p[0].toUpperCase()).take(2).join();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: highlight ? const LinearGradient(colors: [KnockColors.green, KnockColors.greenBright]) : null,
        color: highlight ? null : KnockColors.surfaceHigh,
      ),
      child: Text(initials.isEmpty ? '?' : initials, style: TextStyle(fontSize: size * 0.38, fontWeight: FontWeight.w700, color: highlight ? KnockColors.onGreen : KnockColors.textPrimary)),
    );
  }
}

/// The licensed customer-care photograph used across support surfaces.
/// Photo: LumenSoft Technologies on Unsplash (Unsplash License).
class SupportPhoto extends StatelessWidget {
  const SupportPhoto({super.key, this.height = 180, this.radius = KnockRadius.lg});
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: Image.asset(
          'assets/support/support_agent.jpg',
          fit: BoxFit.cover,
          alignment: const Alignment(0, -0.4),
          semanticLabel: 'A Knock customer care specialist wearing a headset',
          errorBuilder: (_, _, _) => Container(
            decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFFF4F5F7), Color(0xFFDDE6E0)])),
            child: const Center(child: Icon(Icons.support_agent_rounded, size: 64, color: Color(0xFF0A4A23))),
          ),
        ),
      ),
    );
  }
}

/// Animated tick or cross for success and failure moments.
class ResultBurst extends StatelessWidget {
  const ResultBurst({super.key, this.success = true, this.size = 96});
  final bool success;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = success ? KnockColors.green : KnockColors.loss;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: Curves.elasticOut,
      builder: (_, v, _) => Transform.scale(
        scale: 0.4 + 0.6 * v,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.16),
            boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35 * v), blurRadius: 40 * v)],
          ),
          child: Icon(success ? Icons.check_rounded : Icons.close_rounded, color: success ? KnockColors.greenBright : KnockColors.loss, size: size * 0.5),
        ),
      ),
    );
  }
}

Future<bool> confirm(BuildContext context, {required String title, required String message, String yes = 'Continue', String no = 'Cancel', bool danger = false}) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    builder: (c) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: KnockText.title),
            const SizedBox(height: 8),
            Text(message, style: KnockText.body.copyWith(color: KnockColors.textSecondary)),
            const SizedBox(height: 20),
            DangerAwareButton(label: yes, danger: danger, onPressed: () => Navigator.pop(c, true)),
            const SizedBox(height: 8),
            KnockButton(label: no, style: KnockButtonStyle.ghost, onPressed: () => Navigator.pop(c, false)),
          ],
        ),
      ),
    ),
  );
  return r == true;
}

class DangerAwareButton extends StatelessWidget {
  const DangerAwareButton({super.key, required this.label, required this.onPressed, this.danger = false, this.loading = false});
  final String label;
  final VoidCallback? onPressed;
  final bool danger;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (!danger) return KnockButton(label: label, onPressed: onPressed, loading: loading);
    return Opacity(
      opacity: onPressed == null ? 0.45 : 1,
      child: Material(
        color: KnockColors.loss,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onPressed == null || loading
              ? null
              : () {
                  HapticFeedback.mediumImpact();
                  onPressed!();
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 15),
            child: Center(
              heightFactor: 1,
              child: loading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(label, style: KnockText.bodyStrong.copyWith(color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing, this.top = 24});
  final String text;
  final Widget? trailing;
  final double top;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: top, bottom: 10),
    child: Row(children: [Expanded(child: Text(text, style: KnockText.headline)), ?trailing]),
  );
}
