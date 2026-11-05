import 'package:flutter/material.dart';

/// Tantyahin's mark — the user-supplied magenta carabao roundel
/// bundled at `assets/logo.jpg`, used as-is: the top bar shows it
/// through [CarabaoLogo] and `test/carabao_icon_test.dart` bakes it
/// into `windows/runner/resources/app_icon.ico`.
const kCarabaoPink = Color(0xFFED00B8);

class CarabaoLogo extends StatelessWidget {
  final double size;
  const CarabaoLogo({super.key, this.size = 38});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: ClipOval(
      child: Image.asset('assets/logo.jpg', fit: BoxFit.cover),
    ),
  );
}
