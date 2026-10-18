import 'package:flutter/material.dart';

import 'mesh/mesh_service.dart';
import 'platform/native_bridge.dart';
import 'ui/call_screen.dart';
import 'ui/home_screen.dart';
import 'ui/onboarding_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  NativeBridge.init();
  final mesh = await MeshService.create();
  runApp(MeshTalkApp(mesh: mesh));
}

class MeshTalkApp extends StatefulWidget {
  const MeshTalkApp({super.key, required this.mesh});
  final MeshService mesh;

  @override
  State<MeshTalkApp> createState() => _MeshTalkAppState();
}

class _MeshTalkAppState extends State<MeshTalkApp> {
  final _navKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _callScreenOpen = false;

  MeshService get mesh => widget.mesh;

  @override
  void initState() {
    super.initState();
    mesh.addListener(_watchCalls);
  }

  @override
  void dispose() {
    mesh.removeListener(_watchCalls);
    super.dispose();
  }

  /// Opens the call screen from anywhere in the app when a call starts
  /// (incoming or outgoing), and shows why it ended afterwards.
  void _watchCalls() {
    if (mesh.call != null && !_callScreenOpen) {
      _callScreenOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final nav = _navKey.currentState;
        if (nav == null) {
          _callScreenOpen = false;
          return;
        }
        nav
            .push(MaterialPageRoute(builder: (_) => CallScreen(mesh: mesh)))
            .whenComplete(() {
          _callScreenOpen = false;
        });
      });
    }
    if (mesh.call == null) {
      final reason = mesh.takeCallEndedReason();
      if (reason != null) {
        _messengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(reason)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MeshTalk',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      scaffoldMessengerKey: _messengerKey,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: ListenableBuilder(
        listenable: mesh,
        builder: (context, _) => mesh.nick == null
            ? OnboardingScreen(mesh: mesh)
            : HomeScreen(mesh: mesh),
      ),
    );
  }
}