import 'dart:async';
import 'dart:convert';
import 'dart:math' show pi, cos, sin;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:location/location.dart';

class MapPage extends StatefulWidget {
  final double? initialLatitude;
  final double? initialLongitude;
  final String? markerId;

  MapPage({
    this.initialLatitude,
    this.initialLongitude,
    this.markerId,
  });

  @override
  _MapPageState createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final Completer<GoogleMapController> _controller = Completer();
  final Set<Marker> _markers = {};
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Location _location = Location();

  late CameraPosition _initialPosition;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initialPosition = CameraPosition(
      target: widget.initialLatitude != null && widget.initialLongitude != null
          ? LatLng(widget.initialLatitude!, widget.initialLongitude!)
          : const LatLng(0, 0),
      zoom: widget.initialLatitude != null ? 15 : 2,
    );

    if (widget.initialLatitude == null || widget.initialLongitude == null) {
      _getCurrentLocation();
    }
    _loadMarkers();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.markerId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        while (_isLoading) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        final marker = _markers.firstWhere(
          (m) => m.markerId.value == widget.markerId,
          orElse: () => Marker(markerId: const MarkerId('')),
        );
        if (marker.markerId.value.isNotEmpty) {
          final controller = await _controller.future;
          controller.showMarkerInfoWindow(marker.markerId);
        }
      });
    }
  }

  Future<BitmapDescriptor> _createCustomMarker(String base64Image) async {
    final bytes = base64Decode(base64Image);
    final codec = await ui.instantiateImageCodec(bytes,
        targetHeight: 100, targetWidth: 100);
    final frame = await codec.getNextFrame();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, 120, 120),
      Paint()
        ..color = Colors.lightGreen.withOpacity(0.3)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      Rect.fromLTWH(2, 2, 116, 116),
      Paint()
        ..color = Colors.lightGreen
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0,
    );
    canvas.drawImageRect(
      frame.image,
      Rect.fromLTWH(0, 0, frame.image.width.toDouble(),
          frame.image.height.toDouble()),
      const Rect.fromLTWH(10, 10, 100, 100),
      Paint(),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(120, 120);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);

    if (data != null) {
      return BitmapDescriptor.fromBytes(data.buffer.asUint8List());
    }
    return BitmapDescriptor.defaultMarker;
  }

  Future<void> _loadMarkers() async {
    setState(() => _isLoading = true);

    try {
      final snapshot = await _firestore.collection('wild').get();
      final Set<Marker> markers = {};

      // Group by coordinates
      final Map<String, List<QueryDocumentSnapshot>> groups = {};
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        if (data['coordinates'] == null) continue;
        final coords = data['coordinates'] as Map<String, dynamic>;
        if (coords['latitude'] == null || coords['longitude'] == null) continue;
        final key = '${coords['latitude']},${coords['longitude']}';
        groups.putIfAbsent(key, () => []).add(doc);
      }

      for (final docs in groups.values) {
        if (docs.length == 1) {
          await _addMarker(docs.first, markers);
        } else {
          await _addOffsetMarkers(docs, markers);
        }
      }

      setState(() {
        _markers
          ..clear()
          ..addAll(markers);
        _isLoading = false;
      });

      // Auto-show card for initial markerId
      if (widget.markerId != null && _markers.isNotEmpty) {
        final relevant = _markers.firstWhere(
          (m) => m.markerId.value == widget.markerId,
          orElse: () => Marker(markerId: const MarkerId('')),
        );
        if (relevant.markerId.value.isNotEmpty) {
          final data = (await _firestore
                  .collection('wild')
                  .doc(widget.markerId)
                  .get())
              .data();
          if (data != null) _showImageCard(data, widget.markerId!);
        }
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showError('Error loading markers: $e');
    }
  }

  Future<void> _addMarker(
      QueryDocumentSnapshot doc, Set<Marker> markers) async {
    final data = doc.data() as Map<String, dynamic>;
    final imgs = List<String>.from(data['base64Images'] ?? []);
    if (imgs.isEmpty) return;

    final coords = data['coordinates'] as Map<String, dynamic>;
    final icon = await _createCustomMarker(imgs[0]);

    markers.add(Marker(
      markerId: MarkerId(doc.id),
      position: LatLng(
          coords['latitude'].toDouble(), coords['longitude'].toDouble()),
      icon: icon,
      onTap: () => _showImageCard(data, doc.id),
    ));
  }

  Future<void> _addOffsetMarkers(
      List<QueryDocumentSnapshot> docs, Set<Marker> markers) async {
    final base =
        (docs.first.data() as Map<String, dynamic>)['coordinates'];
    final double baseLat = base['latitude'].toDouble();
    final double baseLng = base['longitude'].toDouble();
    const double offsetRadius = 0.0002;

    for (int i = 0; i < docs.length; i++) {
      final data = docs[i].data() as Map<String, dynamic>;
      final imgs = List<String>.from(data['base64Images'] ?? []);
      if (imgs.isEmpty) continue;

      final angle = (2 * pi * i) / docs.length;
      final icon = await _createCustomMarker(imgs[0]);

      markers.add(Marker(
        markerId: MarkerId(docs[i].id),
        position: LatLng(
          baseLat + offsetRadius * cos(angle),
          baseLng + offsetRadius * sin(angle),
        ),
        icon: icon,
        onTap: () => _showImageCard(data, docs[i].id),
      ));
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      bool svcEnabled = await _location.serviceEnabled();
      if (!svcEnabled) {
        svcEnabled = await _location.requestService();
        if (!svcEnabled) return;
      }
      PermissionStatus perm = await _location.hasPermission();
      if (perm == PermissionStatus.denied) {
        perm = await _location.requestPermission();
        if (perm != PermissionStatus.granted) return;
      }
      final loc = await _location.getLocation();
      if (!mounted) return;
      final pos = CameraPosition(
          target: LatLng(loc.latitude!, loc.longitude!), zoom: 12);
      setState(() => _initialPosition = pos);
      final ctrl = await _controller.future;
      await ctrl.animateCamera(CameraUpdate.newCameraPosition(pos));
    } catch (e) {
      debugPrint('Location error: $e');
    }
  }

  void _showImageCard(Map<String, dynamic> data, String docId) {
    final imgs = List<String>.from(data['base64Images'] ?? []);

    String formattedDateTime = 'Not specified';
    if (data['timestamp'] != null) {
      try {
        final dt = (data['timestamp'] as Timestamp).toDate();
        formattedDateTime =
            '${dt.day}/${dt.month}/${dt.year}  ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {}
    }

    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: MediaQuery.of(context).size.width * 0.9,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Image gallery
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(20)),
                    child: SizedBox(
                      height: 250,
                      child: PageView.builder(
                        itemCount: imgs.length,
                        itemBuilder: (_, i) => Image.memory(
                            base64Decode(imgs[i]),
                            fit: BoxFit.cover),
                      ),
                    ),
                  ),

                  // Info
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Species name
                        Text(
                          data['species'] ?? 'Unknown Species',
                          style: Theme.of(context).textTheme.titleLarge,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const Divider(height: 20),

                        // Info rows — no local area
                        _infoRow(Icons.person,
                            'Contributor',
                            data['contributorId'] ?? 'Unknown'),
                        _infoRow(Icons.park,
                            'Area',
                            data['protectedArea'] ?? 'Not specified'),
                        _infoRow(Icons.calendar_today,
                            'Date & Time', formattedDateTime),
                        _infoRow(
                          Icons.gps_fixed,
                          'Coordinates',
                          '${data['coordinates']['latitude'].toStringAsFixed(4)}, '
                              '${data['coordinates']['longitude'].toStringAsFixed(4)}',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Close button
            Positioned(
              right: -12,
              top: -12,
              child: GestureDetector(
                onTap: () => Navigator.of(dialogContext).pop(),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(
                          color: Colors.black26,
                          spreadRadius: 1,
                          blurRadius: 2),
                    ],
                  ),
                  child: const Icon(Icons.close, size: 20, color: Colors.black87),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Text('$label: ',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Biodiversity Map',
            style: TextStyle(
                color: Color(0xFFE8F5E9), fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF122412),
        elevation: 0,
        iconTheme: const IconThemeData(color: Color(0xFF81C784)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadMarkers,
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            mapType: MapType.normal,
            initialCameraPosition: _initialPosition,
            markers: _markers,
            onMapCreated: (ctrl) {
              _controller.complete(ctrl);
              if (widget.markerId != null) {
                final target = _markers.firstWhere(
                  (m) => m.markerId.value == widget.markerId,
                  orElse: () => Marker(markerId: const MarkerId('')),
                );
                if (target.markerId.value.isNotEmpty) {
                  ctrl.animateCamera(CameraUpdate.newLatLngZoom(
                      target.position, 15));
                }
              }
            },
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            compassEnabled: true,
            zoomControlsEnabled: true,
            zoomGesturesEnabled: true,
            rotateGesturesEnabled: true,
            tiltGesturesEnabled: true,
            scrollGesturesEnabled: true,
            mapToolbarEnabled: true,
          ),
          if (_isLoading)
            Container(
              color: Colors.black45,
              child: const Center(
                child: CircularProgressIndicator(
                    valueColor:
                        AlwaysStoppedAnimation<Color>(Colors.green)),
              ),
            ),
        ],
      ),
    );
  }
}
