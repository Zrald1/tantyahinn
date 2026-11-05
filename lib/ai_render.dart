// AI render enhancement via Meta's Muse Image (muse-image-1.0).
//
// Pipeline: our ray-traced PNG is the geometry anchor -> POST the
// image + a photoreal prompt to /v1/images/edits (OpenAI-compatible
// JSON body, no multipart needed) -> get back a photographic render.
// Pure Dart + dart:io so it works in the app AND in tests.
//
// API contract (dev.meta.ai/docs/image-generation):
//   POST https://api.meta.ai/v1/images/edits
//   Authorization: Bearer <key>
//   {"model":"muse-image-1.0","prompt":"...",
//    "images":[{"image_url":"data:image/png;base64,..."}],"n":1}
//   -> data[0].b64_json (WebP bytes, RIFF container)

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

const _kEditsUrl = 'https://api.meta.ai/v1/images/edits';
const _kChatUrl = 'https://api.meta.ai/v1/chat/completions';
const _kModel = 'muse-image-1.0';
const _kTextModel = 'muse-spark-1.3';

/// Default prompt tuned for architectural stills: keeps the traced
/// geometry as the layout anchor and only restyles surface/light.
/// Written in architectural-photography vocabulary (lens, light,
/// PBR materials, context) with an explicit avoid-list - the single
/// biggest quality lever for img2img realism.
const kAiRenderPrompt =
    'Transform this 3D architectural model render into a professional '
    'photorealistic architectural photograph, as shot by a high-end '
    'visualization studio with a full-frame camera and a 35mm '
    'tilt-shift lens. Keep the exact building geometry, proportions, '
    'wall layout, door and window positions and camera angle '
    'unchanged. Physically based materials: fine-grain plaster with '
    'subtle surface variation, reflective low-iron glass with sky '
    'reflections, real timber grain, crisp metal edges, weathered '
    'ground. Natural global illumination, soft contact shadows, '
    'accurate ambient occlusion, gentle depth of field, subtle '
    'atmospheric haze, realistic landscaping and sky, balanced '
    'exposure, true-to-life color, fine photographic detail. Avoid: '
    'cartoon or toy look, plastic surfaces, warped or extra '
    'geometry, added or missing doors/windows, text, watermark, '
    'oversaturation, blur.';

/// Enhances [png] with Muse Image and returns PNG bytes.
/// Throws a [StateError] with a user-readable message on failure
/// (bad key, network, empty result) - the caller keeps the base
/// render and shows the message.
Future<Uint8List> museEnhanceImage(
  Uint8List png, {
  required String apiKey,
  String? prompt,
}) async {
  final body = jsonEncode({
    'model': _kModel,
    'prompt': (prompt != null && prompt.trim().isNotEmpty)
        ? '${kAiRenderPrompt.trim()} Style: ${prompt.trim()}'
        : kAiRenderPrompt,
    'images': [
      {'image_url': 'data:image/png;base64,${base64Encode(png)}'},
    ],
    'n': 1,
  });
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final req = await client.postUrl(Uri.parse(_kEditsUrl));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    req.headers.contentType = ContentType.json;
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 180));
    final chunks = <int>[];
    await for (final c in res) {
      chunks.addAll(c);
    }
    final raw = Uint8List.fromList(chunks);
    if (res.statusCode != 200) {
      String msg = 'HTTP ${res.statusCode}';
      try {
        final j = jsonDecode(utf8.decode(raw));
        final e = j['error'];
        if (e is Map && e['message'] != null) msg = '${e['message']}';
      } catch (_) {}
      throw StateError('AI enhance failed: $msg');
    }
    final j = jsonDecode(utf8.decode(raw));
    final data = j['data'] as List?;
    final b64 = (data != null && data.isNotEmpty)
        ? data[0]['b64_json'] as String?
        : null;
    if (b64 == null) {
      throw StateError('AI enhance returned no image');
    }
    final out = base64Decode(b64);
    // Response is WebP (RIFF header) - convert to PNG so every
    // exported render is the same format the viewer/exporters know.
    if (out.length > 12 &&
        out[0] == 0x52 &&
        out[1] == 0x49 &&
        out[8] == 0x57 &&
        out[9] == 0x45) {
      final im = img.decodeWebP(out);
      if (im != null) {
        return Uint8List.fromList(img.encodePng(im));
      }
    }
    return out; // already a supported image format
  } on StateError {
    rethrow;
  } catch (e) {
    throw StateError('AI enhance failed: $e');
  } finally {
    client.close(force: true);
  }
}

/// Expands a short style hint into a detailed photoreal style
/// description with a Muse text model (muse-spark-1.3, ~$0.001).
/// Empty [hint] asks for a style that fits [envLabel]. When
/// [imagePng] is given the model SEES a preview render of the actual
/// building (verified: spark-1.3 takes OpenAI-style image_url parts)
/// so the style text is grounded in the real geometry, colors and
/// layout. Returns one polished sentence the caller puts back into
/// the hint field. Throws StateError with a readable message.
Future<String> museExpandStyle(
  String hint, {
  required String apiKey,
  String? envLabel,
  Uint8List? imagePng,
}) async {
  final user = (hint.trim().isEmpty)
      ? 'Suggest a photorealistic architectural render style for this '
          'building shown in a ${envLabel ?? 'daylight'} environment.'
      : 'Improve this architectural render style hint for the '
          'building in the image: "${hint.trim()}"';
  // multimodal content parts when a preview frame is attached,
  // plain text otherwise
  final Object userContent = imagePng == null
      ? user
      : [
          {'type': 'text', 'text': user},
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:image/png;base64,${base64Encode(imagePng)}',
            },
          },
        ];
  final body = jsonEncode({
    'model': _kTextModel,
    'messages': [
      {
        'role': 'system',
        'content': 'You expand short style hints into detailed '
            'photorealistic architectural-visualization style '
            'descriptions for an img2img render model. When an image '
            'is attached, ground the style in its actual building '
            'type, colors and materials. Cover materials, lighting, '
            'time of day, atmosphere and landscaping. Reply with ONE '
            'compact sentence of style guidance only - no preamble, '
            'no quotes, no bullets.',
      },
      {'role': 'user', 'content': userContent},
    ],
    // spark-1.3 is a reasoning model - without a minimal effort it
    // burns the whole token budget thinking and returns content:null
    'reasoning_effort': 'minimal',
    'max_tokens': 600,
    'temperature': 0.7,
  });
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(Uri.parse(_kChatUrl));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    req.headers.contentType = ContentType.json;
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 90));
    final chunks = <int>[];
    await for (final c in res) {
      chunks.addAll(c);
    }
    final raw = utf8.decode(chunks);
    if (res.statusCode != 200) {
      String msg = 'HTTP ${res.statusCode}';
      try {
        final e = (jsonDecode(raw)['error']);
        if (e is Map && e['message'] != null) msg = '${e['message']}';
      } catch (_) {}
      throw StateError('Style generate failed: $msg');
    }
    final j = jsonDecode(raw);
    final choices = j['choices'] as List?;
    String? text;
    if (choices != null && choices.isNotEmpty) {
      final msg = choices[0]['message'];
      if (msg is Map) text = msg['content'] as String?;
    }
    if (text == null || text.trim().isEmpty) {
      throw StateError('Style generate returned empty text');
    }
    return text.trim().replaceAll('"', '');
  } on StateError {
    rethrow;
  } catch (e) {
    throw StateError('Style generate failed: $e');
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _chatJson(
  String apiKey,
  List<Map<String, dynamic>> messages, {
  int maxTokens = 400,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final req = await client.postUrl(Uri.parse(_kChatUrl));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({
      'model': _kTextModel,
      'messages': messages,
      'reasoning_effort': 'minimal',
      'max_tokens': maxTokens,
      'temperature': 0.2,
    }));
    final res = await req.close().timeout(const Duration(seconds: 90));
    final raw = utf8.decode(await res.expand((c) => c).toList());
    if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  } finally {
    client.close(force: true);
  }
}

Map<String, dynamic> _imgPart(Uint8List png) => {
  'type': 'image_url',
  'image_url': {'url': 'data:image/png;base64,${base64Encode(png)}'},
};

String? _chatText(Map<String, dynamic> j) {
  final c = j['choices'] as List?;
  if (c == null || c.isEmpty) return null;
  final m = c[0]['message'];
  return m is Map ? (m['content'] as String?)?.trim() : null;
}

/// A vision judge's verdict on one candidate: 0-10 realism score and
/// a one-sentence list of the worst defects (empty when none).
class RenderVerdict {
  const RenderVerdict(this.score, this.fix);
  final double score;
  final String fix;
}

/// Scores [candidate] against the geometry [base] with Muse Spark
/// vision: realism, faithfulness to the base layout, and artifact
/// count. Never throws - a failed judge returns score 5 so the
/// pipeline still delivers a result.
Future<RenderVerdict> museJudgeRender(
  Uint8List base,
  Uint8List candidate, {
  required String apiKey,
}) async {
  try {
    final j = await _chatJson(apiKey, [
      {
        'role': 'system',
        'content': 'You are a strict architectural-visualization art '
            'director. Image 1 is the geometry reference, image 2 is a '
            'candidate photoreal render of it. Judge photographic '
            'realism, faithfulness to the reference layout (no added or '
            'missing doors/windows/walls, no warped geometry) and '
            'artifacts. Reply ONLY with JSON: {"score": <0-10 number>, '
            '"fix": "<one short sentence of the worst defects to '
            'correct, or empty>"}',
      },
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Image 1 reference, image 2 candidate.'},
          _imgPart(base),
          _imgPart(candidate),
        ],
      },
    ]);
    final t = _chatText(j) ?? '';
    final m = RegExp(r'\{[\s\S]*\}').firstMatch(t);
    if (m == null) return const RenderVerdict(5, '');
    final d = jsonDecode(m.group(0)!) as Map;
    return RenderVerdict(
      ((d['score'] ?? 5) as num).toDouble().clamp(0, 10).toDouble(),
      '${d['fix'] ?? ''}'.trim(),
    );
  } catch (_) {
    return const RenderVerdict(5, '');
  }
}

/// Professional pipeline: [candidates] parallel Muse Image edits ->
/// vision-judged -> best kept; if the winner scores below
/// [acceptScore] one more edit runs with the judge's critique folded
/// into the prompt, and the better of the two wins. [onStage] reports
/// phases. Throws StateError only when NO candidate could be made.
Future<Uint8List> museEnhanceBest(
  Uint8List png, {
  required String apiKey,
  String? prompt,
  int candidates = 2,
  double acceptScore = 8,
  void Function(String stage)? onStage,
}) async {
  onStage?.call('Generating $candidates candidates');
  final results = await Future.wait([
    for (var i = 0; i < candidates; i++)
      museEnhanceImage(png, apiKey: apiKey, prompt: prompt)
          .then<Uint8List?>((v) => v)
          .catchError((_) => null),
  ]);
  final ok = [for (final r in results) ?r];
  if (ok.isEmpty) {
    // surface the real error from one more attempt
    return museEnhanceImage(png, apiKey: apiKey, prompt: prompt);
  }
  if (ok.length == 1) return ok.first;
  onStage?.call('Judging candidates');
  final verdicts = await Future.wait([
    for (final c in ok) museJudgeRender(png, c, apiKey: apiKey),
  ]);
  var bi = 0;
  for (var i = 1; i < ok.length; i++) {
    if (verdicts[i].score > verdicts[bi].score) bi = i;
  }
  var best = ok[bi];
  final bv = verdicts[bi];
  if (bv.score < acceptScore && bv.fix.isNotEmpty) {
    onStage?.call('Refining');
    try {
      final extra = '${prompt ?? ''} Correct these defects: ${bv.fix}';
      final r = await museEnhanceImage(png, apiKey: apiKey, prompt: extra);
      final rv = await museJudgeRender(png, r, apiKey: apiKey);
      if (rv.score > bv.score) best = r;
    } catch (_) {}
  }
  return best;
}
