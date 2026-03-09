import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:intl/intl.dart';
import 'map_page.dart';
import 'species_learn_page.dart';

class ListPage extends StatefulWidget {
  @override
  _ListPageState createState() => _ListPageState();
}

class _ListPageState extends State<ListPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Dark forest colours
  static const Color _bgDark    = Color(0xFF0D1F0D);
  static const Color _bgMid     = Color(0xFF122412);
  static const Color _accent    = Color(0xFF4CAF50);
  static const Color _textLight = Color(0xFFE8F5E9);
  static const Color _textMuted = Color(0xFF81C784);
  static const Color _cardBg    = Color(0xFF1B2E1B);

  String _sortBy = 'timestamp';
  bool _isAscending = false;
  String _speciesFilter = '';
  String _contributorFilter = '';
  DateTime? _startDateFilter;
  DateTime? _endDateFilter;

  final TextEditingController _speciesController = TextEditingController();
  final TextEditingController _contributorController = TextEditingController();

  Future<List<Map<String, dynamic>>> _fetchData() async {
    Query query = _firestore.collection('wild');

    if (_speciesFilter.isNotEmpty) {
      query = query
          .where('species', isGreaterThanOrEqualTo: _speciesFilter)
          .where('species', isLessThan: '$_speciesFilter\uf8ff');
    }
    if (_contributorFilter.isNotEmpty) {
      query = query
          .where('contributorId',
              isGreaterThanOrEqualTo: _contributorFilter)
          .where('contributorId',
              isLessThan: '$_contributorFilter\uf8ff');
    }
    if (_startDateFilter != null && _endDateFilter != null) {
      query = query
          .where('timestamp',
              isGreaterThanOrEqualTo: _startDateFilter)
          .where('timestamp',
              isLessThanOrEqualTo: _endDateFilter);
    }

    final snap = await query.get();
    List<Map<String, dynamic>> data = snap.docs.map((doc) {
      final d = doc.data() as Map<String, dynamic>;
      return {
        'id': doc.id,
        'species': d['species'] ?? 'Unknown',
        'contributorId': d['contributorId'] ?? 'Unknown',
        'latitude':
            d['coordinates']?['latitude']?.toString() ?? 'N/A',
        'longitude':
            d['coordinates']?['longitude']?.toString() ?? 'N/A',
        'protectedArea': d['protectedArea'] ?? 'N/A',
        'timestamp':
            d['timestamp']?.toDate() ?? DateTime.now(),
        'base64Images':
            List<String>.from(d['base64Images'] ?? []),
      };
    }).toList();

    data.sort((a, b) {
      switch (_sortBy) {
        case 'species':
          return _isAscending
              ? a['species'].compareTo(b['species'])
              : b['species'].compareTo(a['species']);
        case 'contributor':
          return _isAscending
              ? a['contributorId'].compareTo(b['contributorId'])
              : b['contributorId'].compareTo(a['contributorId']);
        default:
          return _isAscending
              ? a['timestamp'].compareTo(b['timestamp'])
              : b['timestamp'].compareTo(a['timestamp']);
      }
    });

    return data;
  }

  void _navigateToLearn(Map<String, dynamic> item) {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) =>
              SpeciesLearnPage(species: item['species'])),
    );
  }

  void _navigateToMap(Map<String, dynamic> item) {
    if (item['latitude'] != 'N/A' && item['longitude'] != 'N/A') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MapPage(
            initialLatitude: double.parse(item['latitude']),
            initialLongitude: double.parse(item['longitude']),
            markerId: item['id'],
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Location coordinates not available'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _cardBg,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => StatefulBuilder(
        builder: (ctx, setModal) => Container(
          padding: const EdgeInsets.all(20),
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Search & Filter',
                  style: TextStyle(
                      color: _textLight,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _darkTextField(
                controller: _speciesController,
                label: 'Filter by Species',
                icon: Icons.eco,
                onChanged: (v) => setModal(() => _speciesFilter = v),
              ),
              const SizedBox(height: 12),
              _darkTextField(
                controller: _contributorController,
                label: 'Filter by Contributor',
                icon: Icons.person,
                onChanged: (v) =>
                    setModal(() => _contributorFilter = v),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                    child: _dateButton(
                  ctx,
                  label: _startDateFilter == null
                      ? 'Start Date'
                      : DateFormat('dd/MM/yyyy')
                          .format(_startDateFilter!),
                  onTap: () async {
                    final d = await showDatePicker(
                        context: ctx,
                        initialDate:
                            _startDateFilter ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now());
                    if (d != null)
                      setModal(() => _startDateFilter = d);
                  },
                )),
                const SizedBox(width: 12),
                Expanded(
                    child: _dateButton(
                  ctx,
                  label: _endDateFilter == null
                      ? 'End Date'
                      : DateFormat('dd/MM/yyyy')
                          .format(_endDateFilter!),
                  onTap: () async {
                    final d = await showDatePicker(
                        context: ctx,
                        initialDate:
                            _endDateFilter ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime.now());
                    if (d != null)
                      setModal(() => _endDateFilter = d);
                  },
                )),
              ]),
              const SizedBox(height: 16),
              Text('Sort By',
                  style: TextStyle(
                      color: _textMuted,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(children: [
                DropdownButton<String>(
                  dropdownColor: _cardBg,
                  value: _sortBy,
                  style: TextStyle(color: _textLight),
                  iconEnabledColor: _textMuted,
                  items: const [
                    DropdownMenuItem(
                        value: 'timestamp',
                        child: Text('Date')),
                    DropdownMenuItem(
                        value: 'species',
                        child: Text('Species')),
                    DropdownMenuItem(
                        value: 'contributor',
                        child: Text('Contributor')),
                  ],
                  onChanged: (v) => setModal(() => _sortBy = v!),
                ),
                const SizedBox(width: 12),
                IconButton(
                  icon: Icon(
                      _isAscending
                          ? Icons.arrow_upward
                          : Icons.arrow_downward,
                      color: _textMuted),
                  onPressed: () =>
                      setModal(() => _isAscending = !_isAscending),
                ),
              ]),
              const Spacer(),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      setModal(() {
                        _speciesFilter = '';
                        _contributorFilter = '';
                        _startDateFilter = null;
                        _endDateFilter = null;
                        _sortBy = 'timestamp';
                        _isAscending = false;
                        _speciesController.clear();
                        _contributorController.clear();
                      });
                    },
                    style: OutlinedButton.styleFrom(
                        foregroundColor: _textMuted,
                        side: BorderSide(color: _textMuted)),
                    child: const Text('Reset'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      setState(() {});
                    },
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white),
                    child: const Text('Search'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _darkTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required ValueChanged<String> onChanged,
  }) {
    return TextField(
      controller: controller,
      style: TextStyle(color: _textLight),
      cursorColor: _accent,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: _textMuted),
        prefixIcon: Icon(icon, color: _textMuted, size: 20),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
                color: Colors.white.withOpacity(0.12))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                BorderSide(color: _accent.withOpacity(0.7))),
        filled: true,
        fillColor: const Color(0xFF162616),
      ),
    );
  }

  Widget _dateButton(BuildContext ctx,
      {required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF162616),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: Colors.white.withOpacity(0.12)),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(color: _textMuted, fontSize: 13)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgDark,
      appBar: AppBar(
        backgroundColor: _bgMid,
        elevation: 0,
        title: const Text('Database',
            style: TextStyle(color: _textLight, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: _textMuted),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_rounded, color: _textMuted),
            onPressed: _showFilterSheet,
            tooltip: 'Filter',
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: _textMuted),
            onPressed: () => setState(() {}),
            tooltip: 'Refresh',
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
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _fetchData(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                  child: CircularProgressIndicator(
                      color: _accent));
            }
            if (snapshot.hasError) {
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline,
                      size: 48, color: Colors.white30),
                  const SizedBox(height: 12),
                  Text('Error: ${snapshot.error}',
                      style: const TextStyle(color: Colors.white30)),
                ]),
              );
            }
            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.eco_outlined, size: 48, color: Colors.white30),
                  SizedBox(height: 12),
                  Text('No sightings recorded yet',
                      style: TextStyle(
                          color: Colors.white54,
                          fontSize: 15,
                          fontWeight: FontWeight.w500)),
                ]),
              );
            }

            final items = snapshot.data!;
            return GridView.builder(
              padding: const EdgeInsets.all(14),
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 0.78,
              ),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return _buildGridCard(item);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildGridCard(Map<String, dynamic> item) {
    return Container(
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: Colors.greenAccent.withOpacity(0.10), width: 1),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.35),
              blurRadius: 10,
              offset: const Offset(0, 4)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Image ──────────────────────────────────────────────
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item['base64Images'].isNotEmpty)
                    Image.memory(
                      base64Decode(item['base64Images'][0]),
                      fit: BoxFit.cover,
                    )
                  else
                    Container(
                      color: const Color(0xFF162616),
                      child: const Icon(Icons.eco_outlined,
                          size: 40, color: Colors.white24),
                    ),

                  // Gradient overlay at bottom of image
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: 40,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            _cardBg.withOpacity(0.9),
                            Colors.transparent
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Multiple images badge
                  if (item['base64Images'].length > 1)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.55),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.photo_library_rounded,
                                color: Colors.white70, size: 11),
                            const SizedBox(width: 3),
                            Text(
                              '${item['base64Images'].length}',
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // ── Species name ────────────────────────────────────────
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(10, 8, 10, 2),
              child: Text(
                item['species'],
                style: const TextStyle(
                  color: _textLight,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),

            // ── Icons row ───────────────────────────────────────────
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(4, 0, 4, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Map icon
                  _iconBtn(
                    icon: Icons.map_rounded,
                    color: const Color(0xFF66BB6A),
                    tooltip: 'View on map',
                    onTap: () => _navigateToMap(item),
                  ),
                  // Divider
                  Container(
                      height: 18,
                      width: 1,
                      color: Colors.white12),
                  // Book icon
                  _iconBtn(
                    icon: Icons.menu_book_rounded,
                    color: const Color(0xFF4DB6AC),
                    tooltip: 'Learn about species',
                    onTap: () => _navigateToLearn(item),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: 14, vertical: 8),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }
}

extension DateTimeExtension on DateTime {
  String formatRelative() {
    final now = DateTime.now();
    final difference = now.difference(this);
    if (difference.inDays < 1) {
      if (difference.inHours < 1) return '${difference.inMinutes} min ago';
      return '${difference.inHours} hr ago';
    } else if (difference.inDays < 30) {
      return '${difference.inDays} days ago';
    } else if (difference.inDays < 365) {
      return '${(difference.inDays / 30).floor()} months ago';
    } else {
      return '${(difference.inDays / 365).floor()} years ago';
    }
  }
}
