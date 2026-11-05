part of 'model_view.dart';

// Ray-traced STILL renderer dialog: pick standard views + quality,
// render each through the pure-Dart tracer in lib/render.dart, then
// show thumbnails with per-view Save-as and an open-folder shortcut.
// Rendering runs in THIS isolate - renderPng yields every ~16 rows,
// so the progress bar and the CANCEL button stay live throughout.

/// Camera presets mirrored on the 3D canvas chip row.
const _renderViews = [
  ('ISO', -0.7, 0.55),
  ('EYE-LEVEL', -0.6, 0.1),
  ('TOP', 0.0, math.pi / 2),
  ('FRONT', 0.0, 0.05),
  ('RIGHT', -math.pi / 2, 0.05),
  ('REAR', math.pi, 0.05),
  ('LEFT', math.pi / 2, 0.05),
];

/// One render environment: either an HDRI asset (Poly Haven CC0 1k
/// maps in assets/env/), a solid backdrop (bg* = zenith/horizon ARGB
/// + ground color for studio sweeps), or neither -> procedural sky.
class _EnvDef {
  const _EnvDef(this.label, {this.asset, this.bgTop, this.bgBot, this.bgGnd});
  final String label;
  final String? asset;
  final int? bgTop, bgBot, bgGnd;
}

const _envs = [
  _EnvDef('Sky'),
  _EnvDef('Field', asset: 'kloppenheim_02'),
  _EnvDef('Forest', asset: 'autumn_forest_04'),
  _EnvDef('City', asset: 'docklands_02'),
  _EnvDef('Sunset', asset: 'venice_sunset'),
  _EnvDef('Studio', asset: 'studio_small_09'),
  _EnvDef('White', bgTop: 0xFFF2F2F5, bgBot: 0xFFFFFFFF, bgGnd: 0xFFECECEF),
  _EnvDef('Black', bgTop: 0xFF101013, bgBot: 0xFF232329, bgGnd: 0xFF161619),
];

/// One finished render: the PNG bytes, the view label, the file it
/// auto-saved to, and how long it took.
class _RenderResult {
  _RenderResult(this.view, this.png, this.path, this.secs);
  final String view;
  final Uint8List png;
  final String path;
  final double secs;
  bool savedAs = false;
}

/// Flattens a model's live faces into the triangle soup the tracer
/// eats and reuses the painter's ground height (min part base - 0.02)
/// so the render's infinite floor lines up with the editor's slab.
RenderJob renderJobForModel(
  Model3d m, {
  required double yaw,
  required double pitch,
  required int width,
  required int height,
  required RenderQuality quality,
  EnvMap? env,
  int? bgTop,
  int? bgBottom,
  int? bgGround,
  bool interiorGlow = false,
}) {
  final soup = TriSoup();
  for (final f in m.cachedFaces()) {
    soup.addPoly(f.v, f.argb);
  }
  var base = double.infinity;
  for (final v in m.volumes) {
    base = math.min(base, v.base);
  }
  for (final w in m.walls) {
    base = math.min(base, w.base);
  }
  if (base == double.infinity) base = 0;
  return RenderJob(
    vpos: soup.vpos,
    triIdx: soup.tris,
    colors: soup.colors,
    yaw: yaw,
    pitch: pitch,
    groundZ: base - 0.02,
    width: width,
    height: height,
    quality: quality,
    env: env,
    bgTop: bgTop,
    bgBottom: bgBottom,
    bgGround: bgGround,
    interiorGlow: interiorGlow,
  );
}

extension _MvRenderDlg on _ModelViewState {
  /// Opens the still-render dialog for the currently selected model.
  Future<void> _showRenderDialog() async {
    final m = _sel;
    if (m == null) return;
    await showDialog<void>(
      context: context,
      // a click outside must not kill a running render
      barrierDismissible: false,
      builder: (_) => _RenderDialog(m, _yaw, _pitch),
    );
  }
}

class _RenderDialog extends StatefulWidget {
  const _RenderDialog(this.model, this.curYaw, this.curPitch);
  final Model3d model;

  /// Live editor camera - offered as the first 'CURRENT' view so the
  /// angle the user actually framed can be rendered too.
  final double curYaw;
  final double curPitch;
  @override
  State<_RenderDialog> createState() => _RenderDialogState();
}

class _RenderDialogState extends State<_RenderDialog> {
  /// CURRENT (the live camera) + the standard preset views.
  late final _views = [
    ('CURRENT', widget.curYaw, widget.curPitch),
    ..._renderViews,
  ];
  late final _on = List<bool>.generate(
    _views.length,
    (i) => i == 0, // CURRENT selected by default
  );
  int _q = 1; // 0 draft / 1 standard / 2 final
  int _size = 0; // 0 = 720p, 1 = 1080p
  int _env = 1; // index into _envs; Field is a good default
  bool _addLib = true; // also file renders into the DRAWINGS library
  bool _glow = false; // warm interior point light (evening shots)
  bool _ai = true; // send each PNG through Muse Image for realism
  final _keyCtrl = TextEditingController(); // Meta Model API key
  final _styleCtrl = TextEditingController(); // optional style hint
  bool _styleBusy = false; // style-generate request in flight
  String _styleStage = ''; // which phase the style button is in
  Uint8List? _stylePrev; // the preview actually sent to the AI
  bool _styleHadImage = false; // true when vision was attached
  bool _aiBusy = false; // an AI enhance call is in flight
  double _aiSecs = 0; // live elapsed timer shown while enhancing
  Timer? _aiTimer;
  String? _aiErr;
  String? _dir;
  final _envCache = <int, EnvMap?>{}; // decoded HDRIs, once per dialog

  /// The Meta API key lives OUTSIDE the repo (user profile), plain
  /// text like any desktop-app credential.
  static String get _keyFile =>
      '${Platform.environment['APPDATA'] ?? Directory.systemTemp.path}'
      '${Platform.pathSeparator}ConstructionEstimate'
      '${Platform.pathSeparator}muse_key.txt';

  @override
  void initState() {
    super.initState();
    try {
      final f = File(_keyFile);
      if (f.existsSync()) {
        _keyCtrl.text = f.readAsStringSync().trim();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _aiTimer?.cancel();
    _keyCtrl.dispose();
    _styleCtrl.dispose();
    super.dispose();
  }

  /// Muse text model expands the hint (or invents one for the
  /// selected environment) and writes it back into the field.
  Future<void> _genStyle() async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty) {
      setState(() => _aiErr = 'Enter your Meta API key first');
      return;
    }
    setState(() {
      _styleBusy = true;
      _aiErr = null;
      _styleHadImage = false;
      _styleStage = 'Rendering preview...';
    });
    // quick draft frame of the LIVE camera angle so the style model
    // sees the actual building it is styling (draft = ~1s at 480p)
    Uint8List? prev;
    Object? prevErr;
    try {
      prev = await renderPng(
        renderJobForModel(
          widget.model,
          yaw: widget.curYaw,
          pitch: widget.curPitch,
          width: 480,
          height: 360,
          quality: RenderQuality.draft,
          env: await _loadEnv(),
          bgTop: _envs[_env].bgTop,
          bgBottom: _envs[_env].bgBot,
          bgGround: _envs[_env].bgGnd,
        ),
      );
      if (prev.isEmpty) prev = null;
    } catch (e) {
      prev = null;
      prevErr = e;
    }
    if (mounted) {
      setState(() {
        _stylePrev = prev; // show exactly what the AI will see
        _styleHadImage = prev != null;
        _styleStage = 'Asking Muse Spark...';
      });
    }
    if (prev == null && prevErr != null) {
      _aiErr = 'Preview render failed ($prevErr) - text-only style';
    }
    try {
      _styleCtrl.text = await museExpandStyle(
        _styleCtrl.text,
        apiKey: key,
        envLabel: _envs[_env].label,
        imagePng: prev,
      );
      if (prev == null && _aiErr == null) {
        _aiErr = 'Style made without seeing the model (no preview)';
      }
    } catch (e) {
      _aiErr = '$e';
    }
    if (mounted) {
      setState(() {
        _styleBusy = false;
        _styleStage = '';
      });
    }
  }
  bool _run = false;
  bool _cancel = false;
  bool _finished = false;
  double _prog = 0;
  String _stage = '';
  String? _err;
  final _out = <_RenderResult>[];

  /// %USERPROFILE%\Documents\ConstructionEstimate\renders (temp on
  /// odd setups); the user can redirect it with Choose folder.
  String get _outDir {
    if (_dir != null) return _dir!;
    final up = Platform.environment['USERPROFILE'];
    final docs = up != null ? '$up\\Documents' : Directory.systemTemp.path;
    return '$docs\\ConstructionEstimate\\renders';
  }

  String _fileSafe(String s) {
    final t = s.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
    return t.isEmpty ? 'model' : t;
  }

  String _ts() {
    final d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}-'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  Future<void> _pickDir() async {
    final d = await getDirectoryPath(initialDirectory: _outDir);
    if (d != null && mounted) setState(() => _dir = d);
  }

  /// Decodes the selected HDRI once and caches it for the batch;
  /// entries with no asset (Sky / solid sweeps) or a failed decode
  /// yield null -> procedural sky or solid backdrop.
  Future<EnvMap?> _loadEnv() async {
    final e = _envs[_env];
    if (e.asset == null) return null;
    if (_envCache.containsKey(_env)) return _envCache[_env];
    EnvMap? map;
    try {
      final bd = await rootBundle.load('assets/env/${e.asset}_1k.hdr');
      map = decodeHdr(bd.buffer.asUint8List());
    } catch (_) {
      map = null;
    }
    _envCache[_env] = map;
    return map;
  }

  /// Sequential batch: one renderPng per selected view, each PNG
  /// written into the output dir immediately so a crash mid-batch
  /// never loses finished frames.
  Future<void> _startRender() async {
    final picked = [
      for (var i = 0; i < _views.length; i++)
        if (_on[i]) i,
    ];
    if (picked.isEmpty) return;
    setState(() {
      _run = true;
      _cancel = false;
      _finished = false;
      _prog = 0;
      _err = null;
      _aiErr = null;
    });
    try {
      final dir = Directory(_outDir);
      await dir.create(recursive: true);
      final ts = _ts();
      // the AI refines real lighting: never feed it a draft plate
      final aiOn = _ai && _keyCtrl.text.trim().isNotEmpty;
      final q = (_q == 0 && !aiOn)
          ? RenderQuality.draft
          : _q == 2
          ? RenderQuality.finalQuality
          : RenderQuality.standard;
      final env = await _loadEnv();
      var step = 0;
      for (final i in picked) {
        step++;
        final v = _views[i];
        if (mounted) {
          setState(() {
            _stage = 'Rendering ${v.$1} ($step/${picked.length})';
            _prog = 0;
          });
        }
        final job = renderJobForModel(
          widget.model,
          yaw: v.$2,
          pitch: v.$3,
          width: _size == 0 ? 1280 : 1920,
          height: _size == 0 ? 720 : 1080,
          quality: q,
          env: env,
          bgTop: _envs[_env].bgTop,
          bgBottom: _envs[_env].bgBot,
          bgGround: _envs[_env].bgGnd,
          interiorGlow: _glow,
        );
        final sw = Stopwatch()..start();
        final png = await renderPng(
          job,
          onProgress: (p) {
            if (mounted && _run) setState(() => _prog = p);
          },
          isCancelled: () => _cancel,
        );
        if (_cancel || png.isEmpty) break;
        final f = File(
          '${dir.path}\\${_fileSafe(widget.model.name)}-${v.$1}-$ts.png',
        );
        await f.writeAsBytes(png, flush: true);
        if (_addLib) est.addDrawing(f.path, 'image');
        _out.add(
          _RenderResult(v.$1, png, f.path, sw.elapsedMilliseconds / 1000),
        );
        // AI pass: Muse Image restyles the traced frame into a
        // photographic render while geometry stays anchored
        final key = _keyCtrl.text.trim();
        if (_ai && key.isNotEmpty && mounted && !_cancel) {
          if (mounted) {
            setState(() {
              _stage = 'AI enhancing ${v.$1} ($step/${picked.length})';
            });
          }
          try {
            await File(_keyFile).writeAsString(key);
          } catch (_) {}
          _aiTimer?.cancel();
          _aiTimer = Timer.periodic(const Duration(milliseconds: 250), (
            _,
          ) {
            if (mounted) setState(() => _aiSecs += 0.25);
          });
          try {
            _aiBusy = true;
            _aiSecs = 0;
            final enh = await museEnhanceBest(
              png,
              apiKey: key,
              prompt: _styleCtrl.text,
              onStage: (t) {
                if (mounted) {
                  setState(() {
                    _stage = 'AI ${v.$1} ($step/${picked.length}): $t';
                  });
                }
              },
            );
            if (_cancel) break;
            final fa = File(
              '${dir.path}\\${_fileSafe(widget.model.name)}-'
              '${v.$1}-AI-$ts.png',
            );
            await fa.writeAsBytes(enh, flush: true);
            if (_addLib) est.addDrawing(fa.path, 'image');
            _out.add(
              _RenderResult('${v.$1} AI', enh, fa.path,
                  sw.elapsedMilliseconds / 1000),
            );
          } catch (e) {
            _aiErr = '$e';
          } finally {
            _aiTimer?.cancel();
            _aiBusy = false;
            if (mounted) setState(() {});
          }
        }
        // thumbs appear as each view finishes, not only at batch end
        if (mounted) setState(() {});
      }
    } catch (e) {
      _err = '$e';
    }
    if (mounted) {
      setState(() {
        _run = false;
        _finished = true;
      });
    }
  }

  Future<void> _saveAs(_RenderResult r) async {
    final loc = await getSaveLocation(
      suggestedName: r.path.split('\\').last,
      initialDirectory: _outDir,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'PNG image', extensions: ['png']),
      ],
    );
    if (loc == null) return;
    await File(loc.path).writeAsBytes(r.png);
    if (mounted) setState(() => r.savedAs = true);
  }

  @override
  Widget build(BuildContext context) {
    const lbl = TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.1,
      color: Color(0xFF64748B),
    );
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Ray-traced render')),
          Text(
            widget.model.name,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: Color(0xFF64748B),
            ),
          ),
        ],
      ),
      insetPadding: const EdgeInsets.symmetric(
        horizontal: 28,
        vertical: 22,
      ),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
      // horizontal studio-style panel: settings column | results pane
      content: SizedBox(
        width: 1010,
        height: 560,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // LEFT: settings, always scrollable so nothing is cut off
            SizedBox(
              width: 380,
              child: Scrollbar(
                thumbVisibility: true,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(right: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('VIEWS', style: lbl),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          FilterChip(
                            label: const Text('All'),
                            selected: _on.every((e) => e),
                            onSelected: _run
                                ? null
                                : (v) => setState(() {
                                    for (var i = 0; i < _on.length; i++) {
                                      _on[i] = v;
                                    }
                                  }),
                          ),
                          for (var i = 0; i < _views.length; i++)
                            FilterChip(
                              label: Text(_views[i].$1),
                              selected: _on[i],
                              onSelected: _run
                                  ? null
                                  : (v) => setState(() => _on[i] = v),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('QUALITY', style: lbl),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    for (final (i, q) in const [
                                      (0, 'Draft'),
                                      (1, 'Standard'),
                                      (2, 'Final'),
                                    ])
                                      ChoiceChip(
                                        label: Text(q),
                                        selected: _q == i,
                                        onSelected: _run
                                            ? null
                                            : (v) {
                                                if (v) {
                                                  setState(() => _q = i);
                                                }
                                              },
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('SIZE', style: lbl),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    for (final (i, s) in const [
                                      (0, '720p'),
                                      (1, '1080p'),
                                    ])
                                      ChoiceChip(
                                        label: Text(s),
                                        selected: _size == i,
                                        onSelected: _run
                                            ? null
                                            : (v) {
                                                if (v) {
                                                  setState(() => _size = i);
                                                }
                                              },
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text('ENVIRONMENT', style: lbl),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (var i = 0; i < _envs.length; i++)
                            ChoiceChip(
                              label: Text(_envs[i].label),
                              selected: _env == i,
                              onSelected: _run
                                  ? null
                                  : (v) {
                                      if (v) setState(() => _env = i);
                                    },
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text('AI ENHANCE', style: lbl),
                      const SizedBox(height: 4),
                      InkWell(
                        onTap: _run ? null : () => setState(() => _ai = !_ai),
                        child: Row(
                          children: [
                            Checkbox(
                              value: _ai,
                              onChanged: _run
                                  ? null
                                  : (v) => setState(() => _ai = v ?? true),
                            ),
                            const Expanded(
                              child: Text(
                                'Photorealistic pass with Muse Image '
                                '(~30s per view)',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_ai) ...[
                        SizedBox(
                          height: 34,
                          child: TextField(
                            controller: _keyCtrl,
                            obscureText: true,
                            enabled: !_run,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: OutlineInputBorder(),
                              labelText: 'Meta Model API key',
                              hintText: 'LLM_...',
                            ),
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: 34,
                                child: TextField(
                                  controller: _styleCtrl,
                                  enabled: !_run,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                    labelText: 'Style hint (optional)',
                                    hintText: 'e.g. modern villa at sunset',
                                  ),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            // Muse Spark expands the hint into a
                            // detailed photoreal style line
                            Tooltip(
                              message: 'Generate / improve style text',
                              child: IconButton(
                                icon: _styleBusy
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.auto_awesome,
                                        size: 18,
                                      ),
                                visualDensity: VisualDensity.compact,
                                onPressed:
                                    (_run || _styleBusy) ? null : _genStyle,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 5,
                          runSpacing: 2,
                          children: [
                            for (final p in const [
                              'Golden hour',
                              'Modern villa',
                              'Brick house',
                              'Tropical garden',
                              'After rain',
                              'Night lights',
                            ])
                              ActionChip(
                                label: Text(
                                  p,
                                  style: const TextStyle(fontSize: 10),
                                ),
                                visualDensity: VisualDensity.compact,
                                onPressed: _run
                                    ? null
                                    : () =>
                                        setState(() => _styleCtrl.text = p),
                              ),
                          ],
                        ),
                        // proof of what the AI actually saw + live
                        // phase text while the button is working
                        if (_styleBusy || _stylePrev != null) ...[
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              if (_stylePrev != null)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.memory(
                                    _stylePrev!,
                                    width: 72,
                                    height: 54,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              if (_stylePrev != null)
                                const SizedBox(width: 8),
                              Expanded(
                                child: _styleBusy
                                    ? Row(
                                        children: [
                                          const SizedBox(
                                            width: 12,
                                            height: 12,
                                            child:
                                                CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            _styleStage,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFF64748B),
                                            ),
                                          ),
                                        ],
                                      )
                                    : Text(
                                        _styleHadImage
                                            ? 'Style made from this view'
                                            : 'No preview was sent',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: _styleHadImage
                                              ? const Color(0xFF15803D)
                                              : const Color(0xFFB45309),
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ],
                      ],
                      if (_aiErr != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          _aiErr!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFB91C1C),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      const Text('OUTPUT', style: lbl),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _outDir,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF475569),
                              ),
                            ),
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.folder_open, size: 16),
                            label: const Text('Choose'),
                            onPressed: _run ? null : _pickDir,
                          ),
                        ],
                      ),
                      InkWell(
                        onTap:
                            _run ? null : () => setState(() => _addLib = !_addLib),
                        child: Row(
                          children: [
                            Checkbox(
                              value: _addLib,
                              onChanged: _run
                                  ? null
                                  : (v) => setState(() => _addLib = v ?? true),
                            ),
                            const Expanded(
                              child: Text(
                                'Add renders to the DRAWINGS library',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                      InkWell(
                        onTap: _run ? null : () => setState(() => _glow = !_glow),
                        child: Row(
                          children: [
                            Checkbox(
                              value: _glow,
                              onChanged: _run
                                  ? null
                                  : (v) => setState(() => _glow = v ?? false),
                            ),
                            const Expanded(
                              child: Text(
                                'Interior warm light (glow through windows)',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const VerticalDivider(width: 24),
            // RIGHT: progress + results grid, fills the remaining pane
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // status strip always visible while working
                  if (_run || _finished) ...[
                    LinearProgressIndicator(
                      value: _aiBusy ? null : (_run ? _prog : 1),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _run ? _stage : 'Done',
                            style: const TextStyle(fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          _aiBusy
                              ? '${_aiSecs.toStringAsFixed(0)}s'
                              : '${(_prog * 100).round()}%',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (_err != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        _err!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFFB91C1C),
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'RENDERED (${_out.length})',
                          style: lbl,
                        ),
                      ),
                      if (_out.isNotEmpty)
                        TextButton.icon(
                          icon: const Icon(Icons.folder_open, size: 16),
                          label: const Text('Open folder'),
                          onPressed: () => openExportedFile(_outDir),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: _out.isEmpty
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.image_outlined,
                                    size: 36,
                                    color: Color(0xFF94A3B8),
                                  ),
                                  SizedBox(height: 6),
                                  Text(
                                    'Renders appear here',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF64748B),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : GridView.builder(
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                              childAspectRatio: 1.72,
                            ),
                            itemCount: _out.length,
                            itemBuilder: (_, i) => _thumb(_out[i]),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_run)
          TextButton(
            onPressed: () => setState(() => _cancel = true),
            child: const Text('CANCEL'),
          ),
        if (!_run)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('CLOSE'),
          ),
        if (!_run)
          FilledButton.icon(
            onPressed: _on.any((e) => e) ? _startRender : null,
            icon: const Icon(Icons.camera_alt_outlined, size: 18),
            label: const Text('RENDER'),
          ),
      ],
    );
  }

  Widget _thumb(_RenderResult r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: InkWell(
            onTap: () => openExportedFile(r.path),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(
                r.png,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Expanded(
              child: Text(
                '${r.view}  -  ${r.secs.toStringAsFixed(1)}s',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF475569),
                ),
              ),
            ),
            InkWell(
              onTap: () => _saveAs(r),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  r.savedAs ? 'Saved' : 'Save as',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF2563EB),
                  ),
                ),
              ),
            ),
            InkWell(
              onTap: () => openExportedFile(r.path),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Icon(Icons.open_in_new, size: 13),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
