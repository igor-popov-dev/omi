import 'package:flutter/material.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class CollapsibleSection extends StatefulWidget {
  final Widget title;
  final List<Widget> children;

  const CollapsibleSection({super.key, required this.title, required this.children});

  @override
  State<CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<CollapsibleSection> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              _isExpanded = !_isExpanded;
            });
          },
          child: Row(
            children: [
              Expanded(child: widget.title),
              Icon(_isExpanded ? Icons.expand_less : Icons.expand_more, color: t.textPrimary.withValues(alpha: 0.6)),
            ],
          ),
        ),
        if (_isExpanded) ...widget.children,
      ],
    );
  }
}
