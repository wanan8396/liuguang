import 'package:flutter/material.dart';

class BrandIcon extends StatelessWidget {
  const BrandIcon({super.key, this.size = 58});
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/brand/liuguang-mark.png',
    width: size,
    height: size,
    semanticLabel: '流光',
  );
}
