import 'package:flutter/material.dart';

import '../mesh/mesh_service.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.mesh});
  final MeshService mesh;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _go() {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    widget.mesh.setNick(v);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.hub_outlined, size: 56, color: t.colorScheme.primary),
                const SizedBox(height: 20),
                Text('MeshTalk', style: t.textTheme.headlineLarge),
                const SizedBox(height: 8),
                Text(
                  'Chat with people nearby without internet or SIM. '
                  'Every phone running MeshTalk relays messages for the others, '
                  'so messages can hop across many phones.',
                  style: t.textTheme.bodyLarge,
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: _ctrl,
                  maxLength: 20,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _go(),
                  decoration: const InputDecoration(
                    labelText: 'Your nickname',
                    hintText: 'e.g. Ali',
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _go,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Join the mesh'),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Next, Android will ask for Nearby devices (Bluetooth / Wi-Fi) '
                  'permission. Nothing leaves your phone except over the mesh.',
                  style: t.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
