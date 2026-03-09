import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'upload_picture_page.dart';
import 'list_page.dart';
import 'map_page.dart';
import 'id_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({Key? key}) : super(key: key);

  // Dark forest theme colours
  static const Color _bgDark     = Color(0xFF0D1F0D);
  static const Color _bgMid      = Color(0xFF122412);
  static const Color _accent     = Color(0xFF4CAF50);
  static const Color _accentDim  = Color(0xFF2E7D32);
  static const Color _textLight  = Color(0xFFE8F5E9);
  static const Color _textMuted  = Color(0xFF81C784);

  Future<String?> _getContributorId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('contributor_id');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_bgDark, _bgMid],
          ),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ──────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 36, 24, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'WildLearn',
                          style: GoogleFonts.dancingScript(
                            fontSize: 46,
                            fontWeight: FontWeight.bold,
                            color: _accent,
                            letterSpacing: 1.5,
                          ),
                        ),
                        Text(
                          'Powered by Gemini',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _textMuted,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      iconSize: 22,
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      icon: const Icon(Icons.info_outline, color: _textMuted, size: 22),
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            backgroundColor: const Color(0xFF1B2E1B),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                            title: const Text(
                              'Disclaimer',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, color: _textLight),
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                Text('• Ensure images have EXIF data',
                                    style: TextStyle(color: _textMuted)),
                                SizedBox(height: 8),
                                Text('• Maximum image per upload is 3',
                                    style: TextStyle(color: _textMuted)),
                                SizedBox(height: 8),
                                Text(
                                    '• Only same species allowed when uploading more than 1 image',
                                    style: TextStyle(color: _textMuted)),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('Close',
                                    style: TextStyle(color: _accent)),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),

              // ── Grid ────────────────────────────────────────────────────────
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: GridView.count(
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    children: [
                      _buildCard(
                        context,
                        'Upload Image',
                        Icons.camera_alt_rounded,
                        const Color(0xFF1B5E20),
                        const Color(0xFF2E7D32),
                        () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => UploadPicturePage())),
                      ),
                      _buildCard(
                        context,
                        'Database',
                        Icons.storage_rounded,
                        const Color(0xFF1A3A1A),
                        const Color(0xFF2D5A2D),
                        () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => ListPage())),
                      ),
                      _buildCard(
                        context,
                        'Explore Map',
                        Icons.map_rounded,
                        const Color(0xFF0F3D2E),
                        const Color(0xFF1B5E44),
                        () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => MapPage())),
                      ),
                      _buildCard(
                        context,
                        'Contributor ID',
                        Icons.person_rounded,
                        const Color(0xFF1A2E1A),
                        const Color(0xFF2C4A2C),
                        () async {
                          String? currentId = await _getContributorId();
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => IdPage(
                                isInitial: false,
                                currentId: currentId ?? '',
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),

              // ── Footer ──────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    "Let's contribute and Learn",
                    style: TextStyle(
                      color: _textMuted.withOpacity(0.7),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(
    BuildContext context,
    String label,
    IconData icon,
    Color colorFrom,
    Color colorTo,
    VoidCallback onPressed,
  ) {
    return Card(
      elevation: 6,
      shadowColor: Colors.black54,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [colorFrom, colorTo],
            ),
            border: Border.all(
                color: Colors.greenAccent.withOpacity(0.12), width: 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 54, color: Colors.white.withOpacity(0.9)),
                const SizedBox(height: 14),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
