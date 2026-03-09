import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'home_page.dart';
import 'id_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "",
      appId: "",
      messagingSenderId: "",
      projectId: "",
      storageBucket: "",
    ),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WildLearn',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1F0D),
        primaryColor: const Color(0xFF4CAF50),
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF4CAF50),
          secondary: const Color(0xFF81C784),
          background: const Color(0xFF0D1F0D),
          surface: const Color(0xFF1B2E1B),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF122412),
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Color(0xFFE8F5E9),
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Color(0xFF81C784)),
        ),
        cardTheme: CardTheme(
          color: const Color(0xFF1B2E1B),
          elevation: 4,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF4CAF50),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Color(0xFFE8F5E9)),
          bodySmall: TextStyle(color: Color(0xFF81C784)),
          titleLarge: TextStyle(
              color: Color(0xFFE8F5E9), fontWeight: FontWeight.bold),
        ),
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: FutureBuilder<String?>(
        future: _getContributorId(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: Color(0xFF0D1F0D),
              body: Center(
                child: CircularProgressIndicator(
                    color: Color(0xFF4CAF50)),
              ),
            );
          }
          if (snapshot.data == null || snapshot.data!.isEmpty) {
            return const IdPage(isInitial: true);
          }
          return const HomePage();
        },
      ),
    );
  }

  Future<String?> _getContributorId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('contributor_id');
  }
}
