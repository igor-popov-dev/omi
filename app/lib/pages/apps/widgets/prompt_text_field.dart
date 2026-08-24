import 'package:flutter/material.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class PromptTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  const PromptTextField({super.key, required this.controller, required this.label, required this.hint});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;

    return Padding(
      padding: const EdgeInsets.only(left: 2.0, right: 2.0, top: 10, bottom: 6),
      child: TextFormField(
        maxLines: null,
        minLines: 4,
        controller: controller,
        validator: (value) {
          if (value == null || value.isEmpty) {
            return 'Please provide a prompt';
          }
          return null;
        },
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintMaxLines: 4,
          labelStyle: TextStyle(color: t.textSecondary),
          hintStyle: TextStyle(color: t.textSecondary, fontSize: 14),
          floatingLabelStyle: TextStyle(color: t.textSecondary),
          alignLabelWithHint: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 16.0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12.0),
            borderSide: BorderSide(color: t.hairline, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12.0),
            borderSide: BorderSide(color: t.hairline, width: 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12.0),
            borderSide: BorderSide(color: t.textSecondary, width: 1),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12.0),
            borderSide: BorderSide(color: t.error, width: 1),
          ),
          filled: false,
        ),
      ),
    );
  }
}
