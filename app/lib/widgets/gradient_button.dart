import 'package:flutter/material.dart';

import 'package:gradient_borders/gradient_borders.dart';
import 'package:omi/utils/theme/omi_tokens.dart';

class GradientButton extends StatelessWidget {
  final String title;
  final VoidCallback onPressed;
  const GradientButton({super.key, required this.title, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final t = context.omi;
    return Container(
      decoration: BoxDecoration(
        border: const GradientBoxBorder(
          gradient: LinearGradient(
            colors: [
              Color.fromARGB(127, 208, 208, 208),
              Color.fromARGB(127, 188, 99, 121),
              Color.fromARGB(127, 86, 101, 182),
              Color.fromARGB(127, 126, 190, 236),
            ],
          ),
          width: 2,
        ),
        borderRadius: BorderRadius.circular(t.rowRadius),
      ),
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: const Color.fromARGB(255, 17, 17, 17),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(t.rowRadius)),
        ),
        child: Container(
          width: double.infinity,
          height: 45,
          alignment: Alignment.center,
          child: Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w400,
              fontSize: 18,
              color: Color.fromARGB(255, 255, 255, 255),
            ),
          ),
        ),
      ),
    );
  }
}
