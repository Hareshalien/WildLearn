import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'home_page.dart';

class IdPage extends StatefulWidget {
  final bool isInitial;
  final String? currentId;

  const IdPage({
    Key? key,
    required this.isInitial,
    this.currentId,
  }) : super(key: key);

  @override
  _IdPageState createState() => _IdPageState();
}

class _IdPageState extends State<IdPage> {
  final TextEditingController _idController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _isLoading = false;
  String? _errorMessage;

  // Dark forest theme colours
  static const Color _bgDark    = Color(0xFF0D1F0D);
  static const Color _bgMid     = Color(0xFF122412);
  static const Color _accent    = Color(0xFF4CAF50);
  static const Color _textLight = Color(0xFFE8F5E9);
  static const Color _textMuted = Color(0xFF81C784);
  static const Color _cardBg    = Color(0xFF1B2E1B);

  @override
  void initState() {
    super.initState();
    if (widget.currentId != null) {
      _idController.text = widget.currentId!;
    }
  }

  Future<void> _saveContributorId() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final oldContributorId = widget.currentId;
      final newContributorId = _idController.text.trim();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('contributor_id', newContributorId);

      if (!widget.isInitial && oldContributorId != newContributorId) {
        final QuerySnapshot querySnapshot = await _firestore
            .collection('wild')
            .where('contributorId', isEqualTo: oldContributorId)
            .get();

        if (querySnapshot.docs.isNotEmpty) {
          final batch = _firestore.batch();
          for (var doc in querySnapshot.docs) {
            batch.update(doc.reference, {'contributorId': newContributorId});
          }
          await batch.commit();
        }
      }

      if (mounted) {
        if (widget.isInitial) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => HomePage()),
            (route) => false,
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Contributor ID updated successfully'),
              backgroundColor: Color(0xFF2E7D32),
              duration: Duration(seconds: 2),
            ),
          );
          Navigator.pop(context);
        }
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error updating contributor ID: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error updating contributor ID'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: _bgDark,
      appBar: widget.isInitial
          ? null
          : AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: _textLight),
                onPressed: () => Navigator.pop(context),
              ),
            ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_bgDark, _bgMid],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Icon
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: _accent.withOpacity(0.1),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: _accent.withOpacity(0.3), width: 1.5),
                      ),
                      child: Icon(Icons.person_outline_rounded,
                          size: 60, color: _accent),
                    ),
                    const SizedBox(height: 32),

                    // Title
                    Text(
                      widget.isInitial
                          ? 'Join & Contribute to Biodiversity'
                          : 'Update Your Contributor ID',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: _textLight,
                        letterSpacing: 0.3,
                        height: 1.3,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 14),

                    // Subtitle
                    Text(
                      widget.isInitial
                          ? 'Create your unique identifier to start contributing to our global biodiversity database'
                          : 'Change your identifier while keeping all your valuable contributions',
                      style: TextStyle(
                        fontSize: 15,
                        color: _textMuted.withOpacity(0.85),
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),

                    // Input
                    Container(
                      decoration: BoxDecoration(
                        color: _cardBg,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: _accent.withOpacity(0.25), width: 1),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.3),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: TextFormField(
                        controller: _idController,
                        style: const TextStyle(
                            fontSize: 16, color: _textLight),
                        cursorColor: _accent,
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.all(20),
                          border: InputBorder.none,
                          hintText: 'Example: Ronaldo',
                          hintStyle: TextStyle(
                              color: _textMuted.withOpacity(0.4),
                              fontSize: 16),
                          prefixIcon: const Icon(
                              Icons.person_outline_rounded,
                              color: _accent,
                              size: 22),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter an identifier';
                          }
                          return null;
                        },
                        enabled: !_isLoading,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _saveContributorId(),
                      ),
                    ),

                    if (_errorMessage != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: Colors.red.withOpacity(0.3)),
                        ),
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                              color: Colors.redAccent, fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],

                    const SizedBox(height: 32),

                    // Button
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _saveContributorId,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          disabledBackgroundColor:
                              _accent.withOpacity(0.4),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                height: 22,
                                width: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white),
                              )
                            : Text(
                                widget.isInitial
                                    ? 'Start Exploring'
                                    : 'Update Identifier',
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _idController.dispose();
    super.dispose();
  }
}
