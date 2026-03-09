import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'config.dart';

class SpeciesLearnPage extends StatefulWidget {
  final String species;

  const SpeciesLearnPage({
    Key? key,
    required this.species,
  }) : super(key: key);

  @override
  _SpeciesLearnPageState createState() => _SpeciesLearnPageState();
}

class _SpeciesLearnPageState extends State<SpeciesLearnPage>
    with SingleTickerProviderStateMixin {
  // State
  bool _loadingFacts = true;
  bool _loadingVideo = true;
  bool _loadingTts = false;
  bool _videoError = false;
  bool _ttsPlaying = false;
  bool _loadingInfographic = true;
  bool _infographicError = false;
  bool _loadingLifecycle = true;
  bool _lifecycleError = false;
  String _videoOpKey = '';
  Timer? _videoPollTimer;

  // Data
  Map<String, dynamic> _facts = {};
  String _videoBase64 = '';
  String _illustrationBase64 = '';
  String _ttsScript = '';
  String _infographicBase64 = '';
  String _lifecycleBase64 = '';

  // Controllers
  VideoPlayerController? _videoController;
  final AudioPlayer _audioPlayer = AudioPlayer();
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  final PageController _imagePageController = PageController();

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation =
        Tween<double>(begin: 0.6, end: 1.0).animate(_pulseController);

    _loadAll();
  }

  bool _disposed = false;

  // Safe setState — never calls setState after dispose
  void _safeSetState(VoidCallback fn) {
    if (!_disposed && mounted) setState(fn);
  }

  @override
  void dispose() {
    _disposed = true;
    _videoPollTimer?.cancel();
    _videoController?.dispose();
    _audioPlayer.dispose();
    _pulseController.dispose();
    _imagePageController.dispose();
    super.dispose();
  }

  // ── Load everything ─────────────────────────────────────────────────────────

  Future<void> _loadAll() async {
    await Future.wait([
      _loadFacts(),
      _startVideoGeneration(),
      _loadInfographic(),
      _loadLifecycle(),
    ]);
  }

  /// Calls /learn-species on the backend — single interleaved Gemini call
  /// that returns facts, illustration (base64 image), AND kicks off TTS.
  Future<void> _loadFacts() async {
    try {
      final resp = await http
          .post(
            Uri.parse('${Config.backendUrl}/learn-species'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'species': widget.species,
            }),
          )
          .timeout(const Duration(seconds: 60));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        _safeSetState(() {
          _facts = data;
          _illustrationBase64 = data['illustrationBase64'] ?? '';
          _ttsScript = data['ttsScript'] ?? '';
          _loadingFacts = false;
        });
        // Load TTS audio in background
        if (_ttsScript.isNotEmpty) _loadTts(_ttsScript);
      } else {
        _safeSetState(() => _loadingFacts = false);
      }
    } catch (e) {
      debugPrint('[learn] facts error: $e');
      _safeSetState(() => _loadingFacts = false);
    }
  }

  /// Starts async Veo video generation using species name only.
  Future<void> _startVideoGeneration() async {
    try {
      final startResp = await http
          .post(
            Uri.parse('${Config.backendUrl}/learn-species-video-start'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'species': widget.species}),
          )
          .timeout(const Duration(seconds: 30));

      if (startResp.statusCode == 200) {
        final key = jsonDecode(startResp.body)['opKey'] as String? ?? '';
        if (key.isNotEmpty) {
          _safeSetState(() => _videoOpKey = key);
          _videoPollTimer =
              Timer.periodic(const Duration(seconds: 5), (_) => _pollVideo());
        } else {
          _safeSetState(() {
            _loadingVideo = false;
            _videoError = true;
          });
        }
      } else {
        _safeSetState(() {
          _loadingVideo = false;
          _videoError = true;
        });
      }
    } catch (e) {
      debugPrint('[learn] video start error: $e');
      _safeSetState(() {
        _loadingVideo = false;
        _videoError = true;
      });
    }
  }

  Future<void> _pollVideo() async {
    if (_videoOpKey.isEmpty) return;
    try {
      // Status check — tiny response, just done/hasVideo/error
      final resp = await http
          .get(Uri.parse(
              '${Config.backendUrl}/learn-species-video-status?key=$_videoOpKey'))
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) return;

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['done'] != true) return; // Still generating, keep polling

      _videoPollTimer?.cancel();

      if (data['hasVideo'] != true) {
        debugPrint('[video] done but no video: ${data['error']}');
        _safeSetState(() { _loadingVideo = false; _videoError = true; });
        return;
      }

      // Download raw MP4 bytes directly — no base64, no JSON
      await _downloadAndInitVideo();

    } catch (e) {
      debugPrint('[video] poll error: $e');
    }
  }

  Future<void> _downloadAndInitVideo() async {
    try {
      debugPrint('[video] Downloading raw video bytes...');
      final videoResp = await http
          .get(Uri.parse(
              '${Config.backendUrl}/learn-species-video-download?key=$_videoOpKey'))
          .timeout(const Duration(seconds: 120)); // large file, generous timeout

      if (videoResp.statusCode != 200 || videoResp.bodyBytes.isEmpty) {
        debugPrint('[video] Download failed: ${videoResp.statusCode}');
        _safeSetState(() { _loadingVideo = false; _videoError = true; });
        return;
      }

      debugPrint('[video] Downloaded ${videoResp.bodyBytes.length} bytes, writing to file...');
      await _initVideo(videoResp.bodyBytes);

    } catch (e) {
      debugPrint('[video] download error: $e');
      _safeSetState(() { _loadingVideo = false; _videoError = true; });
    }
  }

  Future<void> _initVideo(Uint8List videoBytes) async {
    try {
      final tempDir  = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/species_video_${_videoOpKey.substring(0, 8)}.mp4');
      await tempFile.writeAsBytes(videoBytes, flush: true);
      debugPrint('[video] Written to ${tempFile.path}');

      _videoController = VideoPlayerController.file(tempFile);
      await _videoController!.initialize();
      _videoController!.setLooping(true);
      _videoController!.play();
      _safeSetState(() => _loadingVideo = false);
      debugPrint('[video] Player initialised successfully');
    } catch (e) {
      debugPrint('[video] init error: $e');
      _safeSetState(() { _loadingVideo = false; _videoError = true; });
    }
  }

  Future<void> _loadInfographic() async {
    try {
      final resp = await http
          .post(
            Uri.parse('${Config.backendUrl}/learn-species-infographic'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'species': widget.species,
              'diet':     _facts['diet']     ?? '',
              'habitat':  _facts['habitat']  ?? '',
              'size':     _facts['size']     ?? '',
              'lifespan': _facts['lifespan'] ?? '',
            }),
          )
          .timeout(const Duration(seconds: 90));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final img = data['imageBase64'] as String? ?? '';
        _safeSetState(() {
          _infographicBase64 = img;
          _loadingInfographic = false;
          _infographicError = img.isEmpty;
        });
      } else {
        _safeSetState(() { _loadingInfographic = false; _infographicError = true; });
      }
    } catch (e) {
      debugPrint('[infographic] error: $e');
      _safeSetState(() { _loadingInfographic = false; _infographicError = true; });
    }
  }

  Future<void> _loadLifecycle() async {
    try {
      final resp = await http
          .post(
            Uri.parse('${Config.backendUrl}/learn-species-lifecycle'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'species': widget.species}),
          )
          .timeout(const Duration(seconds: 90));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final img = data['imageBase64'] as String? ?? '';
        _safeSetState(() {
          _lifecycleBase64 = img;
          _loadingLifecycle = false;
          _lifecycleError = img.isEmpty;
        });
      } else {
        _safeSetState(() { _loadingLifecycle = false; _lifecycleError = true; });
      }
    } catch (e) {
      debugPrint('[lifecycle] error: $e');
      _safeSetState(() { _loadingLifecycle = false; _lifecycleError = true; });
    }
  }

  Future<void> _loadTts(String script) async {
    _safeSetState(() => _loadingTts = true);
    try {
      final resp = await http
          .post(
            Uri.parse('${Config.backendUrl}/learn-species-tts'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'script': script}),
          )
          .timeout(const Duration(seconds: 30));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final audioB64  = data['audioBase64'] as String? ?? '';
        final audioMime = data['audioMime']   as String? ?? 'audio/mpeg';
        if (audioB64.isNotEmpty) {
          final bytes = base64Decode(audioB64);

          // Write bytes to a local temp file — avoids Android cleartext HTTP
          // restriction that fires when just_audio tries to stream from a
          // non-file/non-https URI (e.g. data: URIs, StreamAudioSource on
          // some Android versions).
          final ext      = audioMime.contains('wav') ? 'wav' : 'mp3';
          final tempDir  = await getTemporaryDirectory();
          final tempFile = File('${tempDir.path}/species_tts.$ext');
          await tempFile.writeAsBytes(bytes, flush: true);

          await _audioPlayer.setFilePath(tempFile.path);
          debugPrint('[tts] loaded from temp file: ${tempFile.path}');
        }
      }
    } catch (e) {
      debugPrint('[learn] tts error: $e');
    } finally {
      _safeSetState(() => _loadingTts = false);
    }
  }

  Future<void> _toggleTts() async {
    final playing = _audioPlayer.playing;
    if (playing) {
      await _audioPlayer.stop();
    } else {
      await _audioPlayer.seek(Duration.zero);
      await _audioPlayer.play();
    }
  }

  // ── UI ───────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1F0D),
      body: CustomScrollView(
        slivers: [
          _buildAppBar(),
          SliverToBoxAdapter(
            child: _buildVideoSection(),
          ),
          SliverToBoxAdapter(
            child: _loadingFacts ? _buildFactsLoading() : _buildFactsContent(),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar() {
    return SliverAppBar(
      expandedHeight: 0,
      pinned: true,
      backgroundColor: const Color(0xFF0D1F0D),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
        onPressed: () => Navigator.pop(context),
      ),
      title: Text(
        widget.species,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
      actions: [
        // TTS button
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: _loadingTts
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.greenAccent),
                  ),
                )
              : IconButton(
                  icon: const Icon(
                    Icons.volume_up_rounded,
                    color: Colors.white70,
                  ),
                  tooltip: 'Listen',
                  onPressed: _ttsScript.isEmpty ? null : _toggleTts,
                ),
        ),
      ],
    );
  }

  Widget _buildVideoSection() {
    return Container(
      height: 240,
      color: Colors.black,
      child: _loadingVideo
          ? _buildVideoLoading()
          : _videoError
              ? _buildVideoError()
              : _buildVideoPlayer(),
    );
  }

  Widget _buildVideoLoading() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (_, __) => Opacity(
              opacity: _pulseAnimation.value,
              child: const Icon(Icons.videocam_rounded,
                  size: 52, color: Colors.greenAccent),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Generating wildlife video…',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 4),
          const Text(
            'Powered by Veo 3.1 · may take ~1 min',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoError() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_rounded, size: 40, color: Colors.white24),
          SizedBox(height: 8),
          Text('Video unavailable',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildVideoPlayer() {
    final ctrl = _videoController!;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Video fills the container
        Center(
          child: AspectRatio(
            aspectRatio: ctrl.value.aspectRatio,
            child: VideoPlayer(ctrl),
          ),
        ),

        // Tap anywhere to toggle play/pause
        GestureDetector(
          onTap: _toggleVideoPlayback,
          behavior: HitTestBehavior.translucent,
          child: Container(color: Colors.transparent),
        ),

        // Bottom control bar
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withOpacity(0.75),
                  Colors.transparent,
                ],
              ),
            ),
            child: Row(
              children: [
                // Play / Pause button
                GestureDetector(
                  onTap: _toggleVideoPlayback,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      shape: BoxShape.circle,
                    ),
                    child: AnimatedBuilder(
                      animation: ctrl,
                      builder: (_, __) => Icon(
                        ctrl.value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ),

                const SizedBox(width: 10),

                // Progress bar
                Expanded(
                  child: AnimatedBuilder(
                    animation: ctrl,
                    builder: (_, __) {
                      final total = ctrl.value.duration.inMilliseconds;
                      final pos   = ctrl.value.position.inMilliseconds;
                      final pct   = total > 0 ? (pos / total).clamp(0.0, 1.0) : 0.0;
                      return GestureDetector(
                        onTapDown: (d) => _seekVideo(d, total),
                        child: Container(
                          height: 4,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            color: Colors.white24,
                          ),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: pct,
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(2),
                                color: Colors.greenAccent,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(width: 10),

                // Duration label
                AnimatedBuilder(
                  animation: ctrl,
                  builder: (_, __) {
                    final pos = _formatDuration(ctrl.value.position);
                    final dur = _formatDuration(ctrl.value.duration);
                    return Text(
                      '$pos / $dur',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 10),
                    );
                  },
                ),

                const SizedBox(width: 8),

                // Veo badge
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: Colors.greenAccent.withOpacity(0.4)),
                  ),
                  child: const Text(
                    'Veo 3.1',
                    style: TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 9,
                        fontWeight: FontWeight.bold),
                  ),
                ),

                const SizedBox(width: 4),

                // Download video button
                GestureDetector(
                  onTap: _downloadVideo,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.download_rounded,
                        color: Colors.white70, size: 18),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _downloadVideo() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final src = File('${tempDir.path}/species_video_${_videoOpKey.substring(0, 8)}.mp4');
      if (!await src.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Row(children: const [
              Icon(Icons.info_outline, color: Colors.white70, size: 18),
              SizedBox(width: 10),
              Text('Video not ready yet'),
            ]),
            backgroundColor: const Color(0xFF1A2E1A),
          ));
        }
        return;
      }
      final result = await ImageGallerySaverPlus.saveFile(
        src.path,
        name: 'biomap_${widget.species.replaceAll(' ', '_')}',
      );
      if (mounted) {
        final success = result['isSuccess'] == true ||
            result['isSuccess'] == 'true' ||
            (result['filePath'] != null &&
                result['filePath'].toString().isNotEmpty);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
            Icon(
              success
                  ? Icons.check_circle_rounded
                  : Icons.error_outline_rounded,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 10),
            Text(success
                ? 'Video saved to gallery successfully'
                : 'Could not save'),
          ]),
          backgroundColor:
              success ? const Color(0xFF2E7D32) : Colors.red.shade900,
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      debugPrint('[download] video error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: const [
            Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Expanded(child: Text('Could not save video')),
          ]),
          backgroundColor: Colors.red.shade900,
        ));
      }
    }
  }

  Future<void> _downloadImage(Uint8List bytes, String name) async {
    try {
      final result = await ImageGallerySaverPlus.saveImage(
        bytes,
        name: 'biomap_${name.replaceAll(' ', '_')}',
        quality: 100,
      );
      if (mounted) {
        final success = result['isSuccess'] == true ||
            result['isSuccess'] == 'true' ||
            (result['filePath'] != null &&
                result['filePath'].toString().isNotEmpty);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: [
            Icon(
              success
                  ? Icons.check_circle_rounded
                  : Icons.error_outline_rounded,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 10),
            Text(success
                ? 'Image saved to gallery successfully'
                : 'Could not save'),
          ]),
          backgroundColor:
              success ? const Color(0xFF2E7D32) : Colors.red.shade900,
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      debugPrint('[download] image error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Row(children: const [
            Icon(Icons.error_outline_rounded, color: Colors.white, size: 18),
            SizedBox(width: 10),
            Expanded(child: Text('Could not save image')),
          ]),
          backgroundColor: Colors.red.shade900,
        ));
      }
    }
  }

  void _toggleVideoPlayback() {
    final ctrl = _videoController;
    if (ctrl == null) return;
    setState(() {
      ctrl.value.isPlaying ? ctrl.pause() : ctrl.play();
    });
  }

  void _seekVideo(TapDownDetails details, int totalMs) {
    final ctrl = _videoController;
    if (ctrl == null || totalMs == 0) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    // Approximate width of the progress bar area
    final barWidth = box.size.width - 100.0;
    final pct = (details.localPosition.dx / barWidth).clamp(0.0, 1.0);
    ctrl.seekTo(Duration(milliseconds: (pct * totalMs).round()));
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildFactsLoading() {
    return const Padding(
      padding: EdgeInsets.all(32),
      child: Center(
        child: Column(
          children: [
            CircularProgressIndicator(color: Colors.greenAccent),
            SizedBox(height: 16),
            Text(
              'Researching species…',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFactsContent() {
    if (_facts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Text('Could not load species information.',
              style: TextStyle(color: Colors.white54)),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: scientific name + status chip
          _buildHeader(),
          const SizedBox(height: 20),

          // Info cards grid
          _buildInfoGrid(),
          const SizedBox(height: 20),

          // Fun fact highlight
          _buildHighlightCard(
            icon: Icons.lightbulb_rounded,
            color: const Color(0xFFFFD700),
            title: 'Fun Fact',
            body: _facts['funFact'] ?? 'No data',
          ),
          const SizedBox(height: 12),

          // History
          _buildHighlightCard(
            icon: Icons.history_edu_rounded,
            color: const Color(0xFF64B5F6),
            title: 'History',
            body: _facts['history'] ?? 'No data',
          ),
          const SizedBox(height: 12),

          // Threat
          _buildHighlightCard(
            icon: Icons.warning_amber_rounded,
            color: const Color(0xFFFF7043),
            title: 'Conservation Threat',
            body: _facts['threat'] ?? 'No data',
          ),

          // Infographic
          const SizedBox(height: 28),
          _buildInfographicSection(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Text(
      widget.species,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 24,
        fontWeight: FontWeight.bold,
        height: 1.2,
      ),
    );
  }

  Widget _buildInfoGrid() {
    final items = [
      _FactItem('Diet',     _facts['diet']),
      _FactItem('Habitat',  _facts['habitat']),
      _FactItem('Size',     _facts['size']),
      _FactItem('Lifespan', _facts['lifespan']),
    ];

    final visible = items.where((i) =>
        i.value != null && i.value!.isNotEmpty && i.value != 'Unknown').toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 2.4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: visible.length,
      itemBuilder: (_, i) => _buildInfoCard(visible[i]),
    );
  }

  Widget _buildInfoCard(_FactItem item) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2E1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            item.label.toUpperCase(),
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item.value!,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildHighlightCard({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
  }) {
    if (body == 'No data' || body.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(body,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfographicSection() {
    // Build the list of available image panels
    final List<_ImagePanel> panels = [
      _ImagePanel(
        title: 'Species Infographic',
        loading: _loadingInfographic,
        error: _infographicError,
        base64: _infographicBase64,
        saveName: '${widget.species}_infographic',
        loadingLabel: 'Generating infographic…',
        errorLabel: 'Could not generate infographic',
      ),
      _ImagePanel(
        title: 'Life Cycle',
        loading: _loadingLifecycle,
        error: _lifecycleError,
        base64: _lifecycleBase64,
        saveName: '${widget.species}_lifecycle',
        loadingLabel: 'Generating life cycle…',
        errorLabel: 'Could not generate life cycle',
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Section header ────────────────────────────────────────────
        Row(
          children: [
            Container(
              width: 3,
              height: 18,
              decoration: BoxDecoration(
                color: Colors.greenAccent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Visuals',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
              ),

            ),
            const Spacer(),
            // Download both button — only show when at least one is ready
            if ((!_loadingInfographic && !_infographicError) ||
                (!_loadingLifecycle && !_lifecycleError))
              GestureDetector(
                onTap: _downloadAllImages,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: Colors.greenAccent.withOpacity(0.3)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.download_rounded,
                          color: Colors.greenAccent, size: 14),
                      SizedBox(width: 4),
                      Text(
                        '',
                        style: TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),

        // ── Swipeable image container ─────────────────────────────────
        Container(
          width: double.infinity,
          height: 340,
          decoration: BoxDecoration(
            color: const Color(0xFF1A2E1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.green.withOpacity(0.2)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              children: [
                PageView.builder(
                  controller: _imagePageController,
                  itemCount: panels.length,
                  itemBuilder: (context, index) {
                    final panel = panels[index];
                    if (panel.loading) {
                      return _buildPanelLoading(panel.loadingLabel);
                    }
                    if (panel.error) {
                      return _buildPanelError(panel.errorLabel);
                    }
                    return Image.memory(
                      base64Decode(panel.base64),
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                    );
                  },
                ),

                // ── Slide label overlay (bottom) ──────────────────────
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          Colors.black.withOpacity(0.7),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 24, 14, 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Animated label
                        _AnimatedPageLabel(
                          controller: _imagePageController,
                          panels: panels,
                        ),
                        // Dot indicators
                        Row(
                          children: List.generate(panels.length, (i) {
                            return _AnimatedDot(
                                controller: _imagePageController,
                                index: i,
                                total: panels.length);
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Swipe hint ────────────────────────────────────────────────
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Center(
            child: Text(
              'Swipe to switch between images',
              style: TextStyle(color: Colors.white24, fontSize: 11),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPanelLoading(String label) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (_, __) => Opacity(
              opacity: _pulseAnimation.value,
              child: const Icon(Icons.auto_awesome_rounded,
                  size: 36, color: Colors.greenAccent),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildPanelError(String label) {
    return Center(
      child: Text(
        label,
        style: const TextStyle(color: Colors.white30, fontSize: 12),
      ),
    );
  }

  Future<void> _downloadAllImages() async {
    int saved = 0;
    if (_infographicBase64.isNotEmpty) {
      try {
        final result = await ImageGallerySaverPlus.saveImage(
          base64Decode(_infographicBase64),
          name: 'biomap_${widget.species.replaceAll(' ', '_')}_infographic',
          quality: 100,
        );
        final ok = result['isSuccess'] == true ||
            result['isSuccess'] == 'true' ||
            (result['filePath'] != null &&
                result['filePath'].toString().isNotEmpty);
        if (ok) saved++;
      } catch (e) {
        debugPrint('[download] infographic error: $e');
      }
    }
    if (_lifecycleBase64.isNotEmpty) {
      try {
        final result = await ImageGallerySaverPlus.saveImage(
          base64Decode(_lifecycleBase64),
          name: 'biomap_${widget.species.replaceAll(' ', '_')}_lifecycle',
          quality: 100,
        );
        final ok = result['isSuccess'] == true ||
            result['isSuccess'] == 'true' ||
            (result['filePath'] != null &&
                result['filePath'].toString().isNotEmpty);
        if (ok) saved++;
      } catch (e) {
        debugPrint('[download] lifecycle error: $e');
      }
    }
    if (mounted) {
      final success = saved > 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Row(children: [
          Icon(
            success
                ? Icons.check_circle_rounded
                : Icons.error_outline_rounded,
            color: Colors.white,
            size: 18,
          ),
          const SizedBox(width: 10),
          Text(success
              ? '$saved image${saved > 1 ? 's' : ''} saved to gallery successfully'
              : 'Could not save images'),
        ]),
        backgroundColor:
            success ? const Color(0xFF2E7D32) : Colors.red.shade900,
        duration: const Duration(seconds: 3),
      ));
    }
  }

}

// ── Simple fact item model ────────────────────────────────────────────────────
class _FactItem {
  final String label;
  final String? value;
  _FactItem(this.label, this.value);
}

// ── Image panel data model ────────────────────────────────────────────────────
class _ImagePanel {
  final String title;
  final bool loading;
  final bool error;
  final String base64;
  final String saveName;
  final String loadingLabel;
  final String errorLabel;

  const _ImagePanel({
    required this.title,
    required this.loading,
    required this.error,
    required this.base64,
    required this.saveName,
    required this.loadingLabel,
    required this.errorLabel,
  });
}

// ── Animated dot indicator ────────────────────────────────────────────────────
class _AnimatedDot extends StatefulWidget {
  final PageController controller;
  final int index;
  final int total;

  const _AnimatedDot({
    required this.controller,
    required this.index,
    required this.total,
  });

  @override
  State<_AnimatedDot> createState() => _AnimatedDotState();
}

class _AnimatedDotState extends State<_AnimatedDot> {
  double _page = 0;

  @override
  void initState() {
    super.initState();
    _page = widget.controller.initialPage.toDouble();
    widget.controller.addListener(_onScroll);
  }

  void _onScroll() {
    if (mounted) setState(() => _page = widget.controller.page ?? _page);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = (_page.round() == widget.index);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.symmetric(horizontal: 3),
      width: active ? 18 : 6,
      height: 6,
      decoration: BoxDecoration(
        color: active ? Colors.greenAccent : Colors.white30,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

// ── Animated page label ───────────────────────────────────────────────────────
class _AnimatedPageLabel extends StatefulWidget {
  final PageController controller;
  final List<_ImagePanel> panels;

  const _AnimatedPageLabel({
    required this.controller,
    required this.panels,
  });

  @override
  State<_AnimatedPageLabel> createState() => _AnimatedPageLabelState();
}

class _AnimatedPageLabelState extends State<_AnimatedPageLabel> {
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _page = widget.controller.initialPage;
    widget.controller.addListener(_onScroll);
  }

  void _onScroll() {
    final p = (widget.controller.page ?? _page.toDouble()).round();
    if (p != _page && mounted) setState(() => _page = p);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final idx = _page.clamp(0, widget.panels.length - 1);
    return Text(
      widget.panels[idx].title,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
