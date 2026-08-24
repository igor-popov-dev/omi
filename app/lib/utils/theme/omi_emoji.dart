import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:omi/utils/folders/folder_icon_mapper.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

/// Family of the bundled monochrome Noto Emoji font (`assets/fonts`, SIL OFL).
///
/// Used as the Glass fallback for emoji that have no icon in [emojiToLucide]:
/// arbitrary emoji arrive from the backend (conversation category, daily
/// summary), so the map can never be complete.
const String kOmiEmojiFontFamily = 'Noto Emoji';

/// Emoji rendered the way the current theme wants it.
///
/// * Classic — the usual colored system emoji, byte-for-byte the previous look.
/// * Glass — a thin monochrome Lucide icon when the emoji is in [emojiToLucide],
///   otherwise the same character drawn with the monochrome Noto Emoji font.
///
/// Only the rendering changes: which emoji a conversation, folder or goal
/// carries is decided (and stored) exactly where it was before.
class OmiEmoji extends StatelessWidget {
  const OmiEmoji(this.emoji, {super.key, this.size = 20, this.color});

  /// The emoji character, e.g. `'🧠'`. May be a ZWJ sequence (`'🧑‍💻'`) or carry
  /// a variation selector (`'❤️'`) — it is matched as a whole string.
  final String emoji;

  /// Font size in Classic, icon size in Glass.
  final double size;

  /// Overrides the Glass tint (`textSecondary` by default).
  final Color? color;

  /// Lucide glyph for [emoji], or null when the emoji is not mapped.
  static IconData? lucideFor(String emoji) => emojiToLucide[emoji];

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    if (!t.isGlass) {
      return Text(emoji, style: TextStyle(fontSize: size, color: color));
    }
    final tint = color ?? t.textSecondary;
    final mapped = emojiToLucide[emoji];
    if (mapped != null) {
      return Icon(mapped, size: size, color: tint);
    }
    return Text(
      emoji,
      style: TextStyle(fontFamily: kOmiEmojiFontFamily, fontSize: size, color: tint),
    );
  }
}

/// Folder icon (folders store their icon as an emoji string).
///
/// Classic keeps the FontAwesome glyph the app has always drawn; Glass draws the
/// matching thin Lucide glyph instead. The color stays the caller's — folders are
/// user-colored on purpose.
class OmiFolderIcon extends StatelessWidget {
  const OmiFolderIcon(this.icon, {super.key, required this.size, this.color});

  /// Folder icon string (an emoji), null for folders without one.
  final String? icon;

  final double size;

  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (!context.omi.isGlass) {
      return FaIcon(folderIconToFa(icon), size: size, color: color);
    }
    return Icon(emojiToLucide[icon] ?? LucideIcons.folder, size: size, color: color);
  }
}

/// Emoji → Lucide glyph. Keys are the emoji actually used by the app:
///
/// * folder icons — `utils/folders/folder_icon_mapper.dart`
/// * goal emoji (picker + keyword classifier) — `pages/conversations/widgets/goals_widget.dart`
/// * category / summary defaults — `backend/schema/structured.dart`, `daily_summary.dart`
///
/// Append-only: adding a key never changes Classic, and Glass only stops falling
/// back to the Noto Emoji outline for that one character. Keys must be copied
/// verbatim from the source (variation selectors and ZWJ sequences included).
const Map<String, IconData> emojiToLucide = {
  // Folders (folder_icon_mapper.dart)
  '📁': LucideIcons.folder,
  '💼': LucideIcons.briefcase,
  '🏠': LucideIcons.home,
  '📚': LucideIcons.bookOpen,
  '👨‍👩‍👧‍👦': LucideIcons.users,
  '👤': LucideIcons.user,
  '👥': LucideIcons.users,
  '❤️': LucideIcons.heart,
  '🎮': LucideIcons.gamepad2,
  '✈️': LucideIcons.plane,
  '🏥': LucideIcons.hospital,
  '🛒': LucideIcons.shoppingCart,
  '💰': LucideIcons.wallet,
  '🎵': LucideIcons.music,
  '🎨': LucideIcons.palette,
  '📝': LucideIcons.pencil,
  '💬': LucideIcons.messageCircle,
  '🌎': LucideIcons.globe,
  '🛠️': LucideIcons.wrench,
  '🍔': LucideIcons.hamburger,
  '🏆': LucideIcons.trophy,
  '🔒': LucideIcons.lock,
  '⭐': LucideIcons.star,
  '🕐': LucideIcons.clock,
  '📊': LucideIcons.barChart3,

  // Goals — picker (goals_widget.dart)
  '🎯': LucideIcons.target,
  '💪': LucideIcons.dumbbell,
  '🏃': LucideIcons.footprints,
  '🧘': LucideIcons.personStanding,
  '💡': LucideIcons.lightbulb,
  '🔥': LucideIcons.flame,
  '🚀': LucideIcons.rocket,
  '💎': LucideIcons.gem,
  '📈': LucideIcons.trendingUp,
  '🌱': LucideIcons.sprout,
  '⏰': LucideIcons.alarmClock,

  // Goals — keyword classifier (goals_widget.dart)
  '⚖️': LucideIcons.scale,
  '😴': LucideIcons.moon,
  '💧': LucideIcons.droplet,
  '🎓': LucideIcons.graduationCap,
  '💻': LucideIcons.laptop,
  '🗣️': LucideIcons.speech,
  '✍️': LucideIcons.penLine,
  '🎬': LucideIcons.clapperboard,
  '📸': LucideIcons.camera,
  '✅': LucideIcons.check,
  '🏦': LucideIcons.landmark,
  '👨‍👩‍👧': LucideIcons.users,
  '💕': LucideIcons.heart,

  // Conversation category / daily summary defaults
  '🧠': LucideIcons.brain,
  '😎': LucideIcons.smile,
  '🧑‍💻': LucideIcons.code,
  '📅': LucideIcons.calendar,
};
