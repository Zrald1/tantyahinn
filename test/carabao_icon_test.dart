import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Bakes `assets/logo.jpg` (the user-supplied magenta carabao
/// roundel, used as-is) into `windows/runner/resources/app_icon.ico`
/// as a classic 3.00-format icon (BITMAPINFOHEADER + BGRA XOR bitmap
/// + AND mask) — the PNG-in-ICO shortcut rc.exe rejects with "not in
/// 3.00 format". Regenerate after replacing the asset:
/// `flutter test test/carabao_icon_test.dart`. Crops to the magenta
/// bounding box so the roundel fills the icon, then asserts the mark
/// carries real magenta area over a white field.
void main() {
  test('logo.jpg writes app_icon.ico', () {
    final src = img.decodeJpg(File('assets/logo.jpg').readAsBytesSync());
    expect(src, isNotNull);
    final im = src!;

    // magenta bounding box — the roundel's outer ring is the mark's
    // furthest extent, so the bbox crops the white margin off
    var x0 = im.width, y0 = im.height, x1 = 0, y1 = 0, magenta = 0;
    for (var y = 0; y < im.height; y++) {
      for (var x = 0; x < im.width; x++) {
        final p = im.getPixel(x, y);
        if (p.r > 180 && p.b > 130 && p.g < 110) {
          magenta++;
          if (x < x0) x0 = x;
          if (x > x1) x1 = x;
          if (y < y0) y0 = y;
          if (y > y1) y1 = y;
        }
      }
    }
    expect(magenta, greaterThan(20000), reason: 'magenta mark missing');
    var white = 0;
    for (var y = 0; y < im.height; y += 7) {
      for (var x = 0; x < im.width; x += 7) {
        final p = im.getPixel(x, y);
        if (p.r > 240 && p.g > 240 && p.b > 240) white++;
      }
    }
    expect(white, greaterThan(4000), reason: 'white field missing');

    final side = math.min(
      math.max(x1 - x0, y1 - y0) + 4, // square + 2px pad each way
      math.min(im.width, im.height),
    );
    final cx = (x0 + x1 + 1) / 2, cy = (y0 + y1 + 1) / 2;
    final sx = (cx - side / 2).round().clamp(0, im.width - side);
    final sy = (cy - side / 2).round().clamp(0, im.height - side);
    final n = 256; // icon side, px
    final icon = img.copyResize(
      img.copyCrop(im, x: sx, y: sy, width: side, height: side),
      width: n,
      height: n,
      interpolation: img.Interpolation.cubic,
    );

    Directory('test/out').createSync(recursive: true);
    File('test/out/carabao.png').writeAsBytesSync(img.encodePng(icon));

    // BMP payload: bottom-up BGRA XOR + 1bpp AND (fully opaque)
    final xorLen = n * n * 4, andLen = n * 32;
    final bmp = Uint8List(xorLen + andLen);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final s = icon.getPixel(x, n - 1 - y);
        final d = (y * n + x) * 4;
        bmp[d] = s.b.toInt();
        bmp[d + 1] = s.g.toInt();
        bmp[d + 2] = s.r.toInt();
        bmp[d + 3] = 255;
      }
    }
    // ICO + BITMAPINFOHEADER are little-endian on disk (ByteData
    // defaults to big) — a big-endian header fails rc.exe RC2175
    final hdr = ByteData(62)
      ..setUint16(0, 0, Endian.little) // reserved
      ..setUint16(2, 1, Endian.little) // type: icon
      ..setUint16(4, 1, Endian.little) // image count
      ..setUint8(6, 0) // width 256 -> stored as 0
      ..setUint8(7, 0) // height 256 -> 0
      ..setUint8(8, 0) // palette
      ..setUint8(9, 0) // reserved
      ..setUint16(10, 1, Endian.little) // planes
      ..setUint16(12, 32, Endian.little) // bpp
      ..setUint32(14, 40 + bmp.length, Endian.little)
      ..setUint32(18, 22, Endian.little) // data offset
      // BITMAPINFOHEADER — biHeight is 2x (XOR + AND stacked)
      ..setUint32(22, 40, Endian.little)
      ..setInt32(26, n, Endian.little)
      ..setInt32(30, n * 2, Endian.little)
      ..setUint16(34, 1, Endian.little)
      ..setUint16(36, 32, Endian.little)
      ..setUint32(38, 0, Endian.little)
      ..setUint32(42, bmp.length, Endian.little)
      ..setInt32(46, 0, Endian.little)
      ..setInt32(50, 0, Endian.little)
      ..setUint32(54, 0, Endian.little)
      ..setUint32(58, 0, Endian.little);
    final ico = File('windows/runner/resources/app_icon.ico')
      ..writeAsBytesSync([...hdr.buffer.asUint8List(), ...bmp]);
    expect(ico.lengthSync(), 22 + 40 + bmp.length);
  });
}
