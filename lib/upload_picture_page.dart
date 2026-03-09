import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:exif/exif.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

class UploadPicturePage extends StatefulWidget {
  @override
  _UploadPicturePageState createState() => _UploadPicturePageState();
}

class _UploadPicturePageState extends State<UploadPicturePage> {
  final List<File> _selectedImages = [];
  Map<String, dynamic>? _sharedMetadata;
  bool _isLoading = false;
  final String _geminiApiKey = "";

  // Dark forest colours
  static const Color _bgDark    = Color(0xFF0D1F0D);
  static const Color _bgMid     = Color(0xFF122412);
  static const Color _accent    = Color(0xFF4CAF50);
  static const Color _textLight = Color(0xFFE8F5E9);
  static const Color _textMuted = Color(0xFF81C784);
  static const Color _cardBg    = Color(0xFF1B2E1B);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pickImages());
  }

  Future<bool> _requestGalleryPermission() async {
    try {
      var status = await Permission.photos.status;
      if (status.isDenied) status = await Permission.photos.request();
      if (status.isPermanentlyDenied) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
                'Gallery permission permanently denied. Please enable from settings.'),
            action: SnackBarAction(
                label: 'Settings', onPressed: () => openAppSettings()),
          ),
        );
        return false;
      }
      return status.isGranted;
    } catch (e) {
      return false;
    }
  }

  Future<void> _processImages(List<XFile> images) async {
    try {
      setState(() => _isLoading = true);

      File? firstValidImage;
      Map<String, dynamic>? coordinates;

      for (final image in images) {
        final f = File(image.path);
        coordinates = await _extractCoordinates(f);
        if (coordinates != null) {
          firstValidImage = f;
          break;
        }
      }

      if (firstValidImage == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No images with location data found')),
        );
        setState(() => _isLoading = false);
        return;
      }

      final species = await _identifySpecies(firstValidImage);
      final base64First =
          await _compressAndConvertToBase64(firstValidImage);

      _sharedMetadata = {
        'coordinates': coordinates,
        'base64Image': base64First,
        'species': species,
        'timestamp': DateTime.now(),
        'protectedArea': '',
        'flagCount': 0,
      };

      setState(() {
        _selectedImages.clear();
        for (final image in images) _selectedImages.add(File(image.path));
      });

      await _showImageDetailPage(firstValidImage, _sharedMetadata!);
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error processing images: $e')));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _pickImages() async {
    if (!await _requestGalleryPermission()) return;
    try {
      final picker = ImagePicker();
      final images = await picker.pickMultiImage();
      if (images != null && images.isNotEmpty) {
        await _processImages(images);
      } else {
        Navigator.pop(context);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error selecting images: $e')));
    }
  }

  Future<Map<String, dynamic>?> _extractCoordinates(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final exif = await readExifFromBytes(bytes);
      if (exif != null &&
          exif.containsKey('GPS GPSLatitude') &&
          exif.containsKey('GPS GPSLongitude') &&
          exif.containsKey('GPS GPSLatitudeRef') &&
          exif.containsKey('GPS GPSLongitudeRef')) {
        final latValues = exif['GPS GPSLatitude']!.values?.toList();
        final lngValues = exif['GPS GPSLongitude']!.values?.toList();
        final latRef = exif['GPS GPSLatitudeRef']!.printable?.trim();
        final lngRef = exif['GPS GPSLongitudeRef']!.printable?.trim();
        if (latValues != null && lngValues != null &&
            latRef != null && lngRef != null) {
          double lat = _toDec(latValues);
          double lng = _toDec(lngValues);
          if (latRef == 'S') lat = -lat;
          if (lngRef == 'W') lng = -lng;
          return {'latitude': lat, 'longitude': lng};
        }
      }
    } catch (e) {
      debugPrint('EXIF error: $e');
    }
    return null;
  }

  double _toDec(List<dynamic> values) {
    double d = _ratioToDouble(values[0]);
    double m = _ratioToDouble(values[1]);
    double s = _ratioToDouble(values[2]);
    return d + m / 60 + s / 3600;
  }

  double _ratioToDouble(dynamic ratio) {
    if (ratio is Ratio) return ratio.numerator / ratio.denominator;
    if (ratio is num) return ratio.toDouble();
    throw Exception('Invalid ratio: $ratio');
  }

  Future<String> _compressAndConvertToBase64(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    img.Image? original = img.decodeImage(bytes);
    if (original == null) throw Exception('Failed to decode image');

    int maxSize = 800 * 1024;
    int quality = 30;
    int maxWidth = 600;
    List<int> compressed;

    do {
      final resized = img.copyResize(original,
          width: original.width > maxWidth ? maxWidth : original.width);
      compressed = img.encodeJpg(resized, quality: quality);
      quality -= 10;
      if (quality <= 10) {
        maxWidth = (maxWidth * 0.75).round();
        quality = 50;
      }
    } while (compressed.length > maxSize && maxWidth > 200);

    if (compressed.length > maxSize) {
      throw Exception('Unable to compress image to required size');
    }
    return base64Encode(compressed);
  }

  Future<String> _identifySpecies(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final b64 = base64Encode(bytes);

      final response = await http.post(
        Uri.parse(
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$_geminiApiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {
                  'text':
                      'Analyze this image and provide ONLY the scientific name if it contains an animal or plant. If it\'s an animal or plant, respond with just the scientific name (e.g., "Panthera leo" or "Quercus robur"). If it\'s not an animal or plant, respond with a short generic description of the object (e.g., "Rock", "Building", "Car"). Keep your response brief - just the name or object type, nothing else.'
                },
                {
                  'inline_data': {
                    'mime_type': 'image/jpeg',
                    'data': b64
                  }
                }
              ]
            }
          ]
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['candidates'] != null &&
            data['candidates'].isNotEmpty &&
            data['candidates'][0]['content']?['parts'] != null &&
            data['candidates'][0]['content']['parts'].isNotEmpty) {
          String text =
              data['candidates'][0]['content']['parts'][0]['text'].trim();
          text = text.split('\n')[0].trim();
          return text.isNotEmpty ? text : 'Unknown';
        }
      }
      return 'Unknown Species';
    } catch (e) {
      return 'Error Identifying Species';
    }
  }

  Future<void> _showImageDetailPage(
      File imageFile, Map<String, dynamic> metadata) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageDetailPage(
          imageFile: imageFile,
          metadata: metadata,
          onMetadataUpdated: (updated) =>
              setState(() => _sharedMetadata = updated),
        ),
      ),
    );
  }

  Future<void> _uploadImages() async {
    if (_selectedImages.isEmpty || _sharedMetadata == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No images selected')));
      return;
    }
    setState(() => _isLoading = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final contributorId = prefs.getString('contributor_id') ?? 'unknown';
      final firestore = FirebaseFirestore.instance;
      final List<String> base64Images = [];
      final List<String> failedImages = [];

      for (final f in _selectedImages) {
        try {
          base64Images.add(await _compressAndConvertToBase64(f));
        } catch (e) {
          failedImages.add(
              'Image ${_selectedImages.indexOf(f) + 1}');
        }
      }

      if (base64Images.isNotEmpty) {
        await firestore.collection('wild').doc().set({
          'base64Images': base64Images,
          'coordinates': _sharedMetadata!['coordinates'],
          'species': _sharedMetadata!['species'],
          'protectedArea': _sharedMetadata!['protectedArea'] ?? '',
          'contributorId': contributorId,
          'timestamp': FieldValue.serverTimestamp(),
          'redFlagCount': 0,
          'blueFlagCount': 0,
          'imageCount': base64Images.length,
        });

        String msg =
            'Successfully uploaded ${base64Images.length} image(s)';
        if (failedImages.isNotEmpty) {
          msg += '\nFailed: ${failedImages.join(", ")}';
        }
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to upload any images. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Error uploading images: $e'),
            backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        backgroundColor: _bgMid,
        elevation: 0,
        title: const Text('Upload Pictures',
            style: TextStyle(
                color: _textLight, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: _textMuted),
        actions: [
          if (_selectedImages.isNotEmpty &&
              _sharedMetadata != null &&
              !_isLoading)
            IconButton(
              icon: const Icon(Icons.cloud_upload, color: _accent),
              onPressed: _uploadImages,
            ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_bgDark, _bgMid]),
        ),
        child: _isLoading
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(color: _accent),
                    const SizedBox(height: 16),
                    Text(
                      'Processing…\nPlease wait',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 15, color: _textMuted),
                    ),
                  ],
                ),
              )
            : _selectedImages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('No images selected',
                            style: TextStyle(
                                fontSize: 18, color: _textMuted)),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: _pickImages,
                          icon: const Icon(Icons.photo_library),
                          label: const Text('Select Images'),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: Colors.white),
                        ),
                      ],
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: _selectedImages.length,
                    itemBuilder: (context, index) {
                      return GestureDetector(
                        onTap: () => _sharedMetadata != null
                            ? _showImageDetailPage(
                                _selectedImages[index], _sharedMetadata!)
                            : null,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.file(
                                _selectedImages[index],
                                fit: BoxFit.cover,
                              ),
                              // Species label
                              Positioned(
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: Container(
                                  color: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 6),
                                  child: Text(
                                    _sharedMetadata?['species'] ??
                                        'Processing…',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

// ── Image Detail Page ─────────────────────────────────────────────────────────

class ImageDetailPage extends StatefulWidget {
  final File imageFile;
  final Map<String, dynamic> metadata;
  final Function(Map<String, dynamic>) onMetadataUpdated;

  const ImageDetailPage({
    Key? key,
    required this.imageFile,
    required this.metadata,
    required this.onMetadataUpdated,
  }) : super(key: key);

  @override
  _ImageDetailPageState createState() => _ImageDetailPageState();
}

class _ImageDetailPageState extends State<ImageDetailPage> {
  late TextEditingController _speciesController;
  late TextEditingController _protectedAreaController;

  static const Color _bgDark    = Color(0xFF0D1F0D);
  static const Color _bgMid     = Color(0xFF122412);
  static const Color _accent    = Color(0xFF4CAF50);
  static const Color _textLight = Color(0xFFE8F5E9);
  static const Color _textMuted = Color(0xFF81C784);
  static const Color _cardBg    = Color(0xFF1B2E1B);

  @override
  void initState() {
    super.initState();
    _speciesController =
        TextEditingController(text: widget.metadata['species']);
    _protectedAreaController =
        TextEditingController(text: widget.metadata['protectedArea']);
  }

  @override
  void dispose() {
    _speciesController.dispose();
    _protectedAreaController.dispose();
    super.dispose();
  }

  void _saveAndReturn() {
    widget.metadata['species'] = _speciesController.text;
    widget.metadata['protectedArea'] = _protectedAreaController.text;
    widget.onMetadataUpdated(widget.metadata);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        backgroundColor: _bgMid,
        elevation: 0,
        title: const Text('Image Details',
            style: TextStyle(
                color: _textLight, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: _textMuted),
        actions: [
          IconButton(
            icon: const Icon(Icons.check, color: _accent),
            onPressed: _saveAndReturn,
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [_bgDark, _bgMid]),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Image preview
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(widget.imageFile,
                    height: 280, fit: BoxFit.cover),
              ),
              const SizedBox(height: 20),

              // Location card
              Container(
                decoration: BoxDecoration(
                  color: _cardBg,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: Colors.greenAccent.withOpacity(0.12)),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Location Data',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: _textLight)),
                    const SizedBox(height: 10),
                    Text(
                        'Latitude: ${widget.metadata['coordinates']['latitude'].toStringAsFixed(6)}',
                        style: TextStyle(color: _textMuted)),
                    Text(
                        'Longitude: ${widget.metadata['coordinates']['longitude'].toStringAsFixed(6)}',
                        style: TextStyle(color: _textMuted)),
                    Text(
                        'Date & Time: ${widget.metadata['timestamp']}',
                        style: TextStyle(color: _textMuted)),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Species field
              _darkTextField(
                controller: _speciesController,
                label: 'Species',
                helper: 'Identified by Gemini AI',
              ),
              const SizedBox(height: 14),

              // Protected area field (no local area)
              _darkTextField(
                controller: _protectedAreaController,
                label: 'Area',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _darkTextField({
    required TextEditingController controller,
    required String label,
    String? helper,
  }) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: _textLight),
      cursorColor: _accent,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: _textMuted),
        helperText: helper,
        helperStyle: TextStyle(color: _textMuted.withOpacity(0.6)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
                color: Colors.white.withOpacity(0.12))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: _accent.withOpacity(0.7))),
        filled: true,
        fillColor: _cardBg,
      ),
    );
  }
}
