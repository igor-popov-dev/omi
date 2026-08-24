import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:omi/utils/theme/omi_tokens.dart';

/// Semantic icon names shared by both themes.
///
/// Add new members here (append-only) instead of reaching for `Icons.*` or
/// `FontAwesomeIcons.*` directly in a migrated screen.
enum OmiIcon {
  check,
  close,
  checkCircle,
  chevronRight,
  chevronLeft,
  info,
  errorCircle,
  search,
  copy,
  trash,
  edit,
  plus,
  settings,
  bell,
  user,
  brain,
  tasks,
  rewind,
  apps,
  chat,
  sparkles,
  lock,
  star,
  gift,
  keyboard,
  waveform,
  creditCard,
  chart,
  arrowUpRight,
  refresh,

  // Added by T3 for the two adoption sites (bottom navigation + settings drawer).
  home,
  bluetooth,
  shield,
  code,
  integrations,
  cloud,
  palette,
  envelope,
  book,
  signOut,

  // T7: settings + apps screens.
  chevronDown,
  chevronUp,
  arrowLeft,
  arrowRight,
  warning,
  externalLink,
  key,
  clock,
  mic,
  globe,
  download,
  eye,
  eyeOff,
  help,
  share,
  dollar,
  calendar,
  phone,
  lightbulb,
  chip,
  play,
  pause,
  language,
  document,
  users,
  crown,
}

/// Classic glyph: either a Material [IconData] or a FontAwesome [FaIconData].
///
/// The two are kept apart on purpose — `FaIcon` renders differently from
/// `Icon` (directionality and duotone handling), so a Classic row that used
/// `FaIcon` before must keep using `FaIcon` to stay pixel-identical.
@immutable
class _ClassicGlyph {
  final IconData? material;
  final FaIconData? fa;

  const _ClassicGlyph.material(IconData icon)
      : material = icon,
        fa = null;

  const _ClassicGlyph.fa(FaIconData icon)
      : material = null,
        fa = icon;
}

/// Glass theme: thin monochrome Lucide outlines, the cross-platform stand-in
/// for the SF Symbols used by the macOS desktop design system.
const Map<OmiIcon, IconData> _lucide = {
  OmiIcon.check: LucideIcons.check,
  OmiIcon.close: LucideIcons.x,
  OmiIcon.checkCircle: LucideIcons.checkCircle,
  OmiIcon.chevronRight: LucideIcons.chevronRight,
  OmiIcon.chevronLeft: LucideIcons.chevronLeft,
  OmiIcon.info: LucideIcons.info,
  OmiIcon.errorCircle: LucideIcons.alertCircle,
  OmiIcon.search: LucideIcons.search,
  OmiIcon.copy: LucideIcons.copy,
  OmiIcon.trash: LucideIcons.trash2,
  OmiIcon.edit: LucideIcons.pencil,
  OmiIcon.plus: LucideIcons.plus,
  OmiIcon.settings: LucideIcons.settings,
  OmiIcon.bell: LucideIcons.bell,
  OmiIcon.user: LucideIcons.user,
  OmiIcon.brain: LucideIcons.brain,
  OmiIcon.tasks: LucideIcons.listChecks,
  OmiIcon.rewind: LucideIcons.history,
  OmiIcon.apps: LucideIcons.puzzle,
  OmiIcon.chat: LucideIcons.messagesSquare,
  OmiIcon.sparkles: LucideIcons.sparkles,
  OmiIcon.lock: LucideIcons.lock,
  OmiIcon.star: LucideIcons.star,
  OmiIcon.gift: LucideIcons.gift,
  OmiIcon.keyboard: LucideIcons.keyboard,
  OmiIcon.waveform: LucideIcons.audioLines,
  OmiIcon.creditCard: LucideIcons.creditCard,
  OmiIcon.chart: LucideIcons.barChart3,
  OmiIcon.arrowUpRight: LucideIcons.arrowUpRight,
  OmiIcon.refresh: LucideIcons.refreshCw,
  OmiIcon.home: LucideIcons.house,
  OmiIcon.bluetooth: LucideIcons.bluetooth,
  OmiIcon.shield: LucideIcons.shieldHalf,
  OmiIcon.code: LucideIcons.code,
  OmiIcon.integrations: LucideIcons.network,
  OmiIcon.cloud: LucideIcons.cloud,
  OmiIcon.palette: LucideIcons.palette,
  OmiIcon.envelope: LucideIcons.mail,
  OmiIcon.book: LucideIcons.bookOpen,
  OmiIcon.signOut: LucideIcons.logOut,
  // T7: settings + apps screens.
  OmiIcon.chevronDown: LucideIcons.chevronDown,
  OmiIcon.chevronUp: LucideIcons.chevronUp,
  OmiIcon.arrowLeft: LucideIcons.arrowLeft,
  OmiIcon.arrowRight: LucideIcons.arrowRight,
  OmiIcon.warning: LucideIcons.triangleAlert,
  OmiIcon.externalLink: LucideIcons.externalLink,
  OmiIcon.key: LucideIcons.keyRound,
  OmiIcon.clock: LucideIcons.clock,
  OmiIcon.mic: LucideIcons.mic,
  OmiIcon.globe: LucideIcons.globe,
  OmiIcon.download: LucideIcons.download,
  OmiIcon.eye: LucideIcons.eye,
  OmiIcon.eyeOff: LucideIcons.eyeOff,
  OmiIcon.help: LucideIcons.circleHelp,
  OmiIcon.share: LucideIcons.share2,
  OmiIcon.dollar: LucideIcons.dollarSign,
  OmiIcon.calendar: LucideIcons.calendarDays,
  OmiIcon.phone: LucideIcons.phone,
  OmiIcon.lightbulb: LucideIcons.lightbulb,
  OmiIcon.chip: LucideIcons.cpu,
  OmiIcon.play: LucideIcons.play,
  OmiIcon.pause: LucideIcons.pause,
  OmiIcon.language: LucideIcons.languages,
  OmiIcon.document: LucideIcons.fileText,
  OmiIcon.users: LucideIcons.users,
  OmiIcon.crown: LucideIcons.crown,
};

/// Classic theme: the glyphs the app draws today, unchanged.
const Map<OmiIcon, _ClassicGlyph> _classic = {
  OmiIcon.check: _ClassicGlyph.material(Icons.check),
  OmiIcon.close: _ClassicGlyph.material(Icons.close),
  OmiIcon.checkCircle: _ClassicGlyph.material(Icons.check_circle),
  OmiIcon.chevronRight: _ClassicGlyph.material(Icons.chevron_right),
  OmiIcon.chevronLeft: _ClassicGlyph.material(Icons.arrow_back_ios_new),
  OmiIcon.info: _ClassicGlyph.material(Icons.info_outline),
  OmiIcon.errorCircle: _ClassicGlyph.material(Icons.error_outline),
  OmiIcon.search: _ClassicGlyph.material(Icons.search),
  OmiIcon.copy: _ClassicGlyph.material(Icons.copy),
  OmiIcon.trash: _ClassicGlyph.material(Icons.delete),
  OmiIcon.edit: _ClassicGlyph.fa(FontAwesomeIcons.pen),
  OmiIcon.plus: _ClassicGlyph.material(Icons.add),
  OmiIcon.settings: _ClassicGlyph.fa(FontAwesomeIcons.gear),
  OmiIcon.bell: _ClassicGlyph.fa(FontAwesomeIcons.solidBell),
  OmiIcon.user: _ClassicGlyph.fa(FontAwesomeIcons.solidUser),
  OmiIcon.brain: _ClassicGlyph.fa(FontAwesomeIcons.brain),
  OmiIcon.tasks: _ClassicGlyph.fa(FontAwesomeIcons.listCheck),
  OmiIcon.rewind: _ClassicGlyph.material(Icons.history),
  OmiIcon.apps: _ClassicGlyph.fa(FontAwesomeIcons.puzzlePiece),
  OmiIcon.chat: _ClassicGlyph.fa(FontAwesomeIcons.comments),
  OmiIcon.sparkles: _ClassicGlyph.material(Icons.auto_awesome),
  OmiIcon.lock: _ClassicGlyph.material(Icons.lock_outline),
  OmiIcon.star: _ClassicGlyph.fa(FontAwesomeIcons.solidStar),
  OmiIcon.gift: _ClassicGlyph.fa(FontAwesomeIcons.gift),
  OmiIcon.keyboard: _ClassicGlyph.material(Icons.keyboard),
  OmiIcon.waveform: _ClassicGlyph.material(Icons.graphic_eq),
  OmiIcon.creditCard: _ClassicGlyph.material(Icons.credit_card),
  OmiIcon.chart: _ClassicGlyph.fa(FontAwesomeIcons.chartLine),
  OmiIcon.arrowUpRight: _ClassicGlyph.material(Icons.arrow_outward),
  OmiIcon.refresh: _ClassicGlyph.material(Icons.refresh),
  OmiIcon.home: _ClassicGlyph.fa(FontAwesomeIcons.house),
  OmiIcon.bluetooth: _ClassicGlyph.fa(FontAwesomeIcons.bluetooth),
  OmiIcon.shield: _ClassicGlyph.fa(FontAwesomeIcons.shieldHalved),
  OmiIcon.code: _ClassicGlyph.fa(FontAwesomeIcons.code),
  OmiIcon.integrations: _ClassicGlyph.fa(FontAwesomeIcons.networkWired),
  OmiIcon.cloud: _ClassicGlyph.fa(FontAwesomeIcons.solidCloud),
  OmiIcon.palette: _ClassicGlyph.fa(FontAwesomeIcons.palette),
  OmiIcon.envelope: _ClassicGlyph.fa(FontAwesomeIcons.solidEnvelope),
  OmiIcon.book: _ClassicGlyph.fa(FontAwesomeIcons.book),
  OmiIcon.signOut: _ClassicGlyph.fa(FontAwesomeIcons.rightFromBracket),
  // T7: settings + apps screens.
  OmiIcon.chevronDown: _ClassicGlyph.material(Icons.keyboard_arrow_down),
  OmiIcon.chevronUp: _ClassicGlyph.material(Icons.keyboard_arrow_up),
  OmiIcon.arrowLeft: _ClassicGlyph.material(Icons.arrow_back),
  OmiIcon.arrowRight: _ClassicGlyph.material(Icons.arrow_forward),
  OmiIcon.warning: _ClassicGlyph.material(Icons.warning_amber_rounded),
  OmiIcon.externalLink: _ClassicGlyph.material(Icons.open_in_new),
  OmiIcon.key: _ClassicGlyph.material(Icons.key),
  OmiIcon.clock: _ClassicGlyph.fa(FontAwesomeIcons.clock),
  OmiIcon.mic: _ClassicGlyph.fa(FontAwesomeIcons.microphone),
  OmiIcon.globe: _ClassicGlyph.fa(FontAwesomeIcons.globe),
  OmiIcon.download: _ClassicGlyph.fa(FontAwesomeIcons.download),
  OmiIcon.eye: _ClassicGlyph.material(Icons.visibility),
  OmiIcon.eyeOff: _ClassicGlyph.material(Icons.visibility_off),
  OmiIcon.help: _ClassicGlyph.material(Icons.question_mark),
  OmiIcon.share: _ClassicGlyph.material(Icons.share_outlined),
  OmiIcon.dollar: _ClassicGlyph.fa(FontAwesomeIcons.dollarSign),
  OmiIcon.calendar: _ClassicGlyph.fa(FontAwesomeIcons.calendarDay),
  OmiIcon.phone: _ClassicGlyph.fa(FontAwesomeIcons.phone),
  OmiIcon.lightbulb: _ClassicGlyph.fa(FontAwesomeIcons.solidLightbulb),
  OmiIcon.chip: _ClassicGlyph.fa(FontAwesomeIcons.microchip),
  OmiIcon.play: _ClassicGlyph.material(Icons.play_arrow),
  OmiIcon.pause: _ClassicGlyph.material(Icons.pause),
  OmiIcon.language: _ClassicGlyph.material(Icons.language),
  OmiIcon.document: _ClassicGlyph.material(Icons.description),
  OmiIcon.users: _ClassicGlyph.material(Icons.people),
  OmiIcon.crown: _ClassicGlyph.fa(FontAwesomeIcons.crown),
};

/// Theme-aware icon.
///
/// Draws a thin Lucide outline under the Glass theme and the app's existing
/// Material / FontAwesome glyph under Classic, so Classic stays pixel-identical.
///
/// Color resolution (single rule for every call site):
/// `color` → `IconTheme.of(context).color` → `context.omi.textSecondary`.
/// The explicit `color` argument always wins; the IconTheme step keeps the
/// widget interchangeable with a bare `Icon` inside buttons and app bars; the
/// token is the last resort so an icon is never invisible on either background.
class OmiIconWidget extends StatelessWidget {
  const OmiIconWidget({super.key, required this.icon, this.size = 20, this.color, this.semanticLabel});

  /// Semantic icon to draw.
  final OmiIcon icon;

  /// Glyph size in logical pixels. Same meaning as `Icon.size`.
  final double size;

  /// Explicit tint. See the class docs for the fallback chain.
  final Color? color;

  /// Optional semantics label, forwarded to the underlying icon widget.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? IconTheme.of(context).color ?? context.omi.textSecondary;

    if (context.omi.isGlass) {
      return Icon(_lucide[icon], size: size, color: resolved, semanticLabel: semanticLabel);
    }

    final glyph = _classic[icon]!;
    if (glyph.fa != null) {
      return FaIcon(glyph.fa, size: size, color: resolved, semanticLabel: semanticLabel);
    }
    return Icon(glyph.material, size: size, color: resolved, semanticLabel: semanticLabel);
  }
}
