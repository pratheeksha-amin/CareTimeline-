import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'auth_screens.dart';
import 'health_screens.dart';
import 'doctor_dashboard.dart';
import 'database.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize SQLite database instance
  await AppDatabase.instance.database;
  runApp(const CareTimelineApp());
}

class CareTimelineApp extends StatefulWidget {
  const CareTimelineApp({super.key});

  @override
  State<CareTimelineApp> createState() => _CareTimelineAppState();
}

class _CareTimelineAppState extends State<CareTimelineApp> {
  AppUser? _currentUser;
  bool _isCheckingSession = true;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final sessionUser = await AuthService.instance.getCurrentSession();
    if (mounted) {
      setState(() {
        _currentUser = sessionUser;
        _isCheckingSession = false;
      });
    }
  }

  void _onAuthenticated(AppUser user) {
    setState(() {
      _currentUser = user;
    });
  }

  void _onLogout() {
    setState(() {
      _currentUser = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CareTimeline',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00796B), // Healthcare Teal
          brightness: Brightness.light,
          primary: const Color(0xFF00796B),
          secondary: const Color(0xFF0288D1), // Medical Blue
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      home: _isCheckingSession
          ? const Scaffold(
              body: Center(
                child: CircularProgressIndicator(),
              ),
            )
          : _currentUser == null
              ? WelcomeScreen(onAuthenticated: _onAuthenticated)
              : _currentUser!.isDoctor
                  ? DoctorDashboardScreen(user: _currentUser!, onLogout: _onLogout)
                  : PatientDashboardScreen(user: _currentUser!, onLogout: _onLogout),
    );
  }
}
