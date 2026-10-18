import 'dart:async';

import 'package:flutter/material.dart';

import '../mesh/mesh_service.dart';
import '../platform/permissions.dart';
import 'theme.dart';
import 'widgets.dart';

/// Full-screen call UI: ringing (in/out) and the active call.
/// Opened by the app automatically whenever a call exists; closes itself
/// when the call ends.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.mesh});
  final MeshService mesh;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _clock;
  bool _closing = false;

  MeshService get mesh => widget.mesh;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && mesh.call?.phase == CallPhase.active) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  void _closeSoon() {
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _accept() async {
    if (!await requestMicrophone()) {
      if (mounted) showError(context, StateError('Microphone permission is needed to answer'));
      return;
    }
    await mesh.acceptCall();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) {
        final c = mesh.call;
        if (c == null) {
          _closeSoon();
          return const Scaffold(backgroundColor: Colors.black);
        }

        final status = switch (c.phase) {
          CallPhase.outgoing => 'Calling…',
          CallPhase.incoming => 'Incoming voice call',
          CallPhase.active =>
              durationLabel(DateTime.now().millisecondsSinceEpoch - (c.startedAt ?? 0)),
        };
        final peer = mesh.peer(c.peerId);

        return PopScope(
          canPop: false, // leave only by ending the call
          child: Scaffold(
            backgroundColor: const Color(0xFF0E1A19),
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: Column(
                  children: [
                    const Spacer(),
                    Avatar(id: c.peerId, name: c.peerName, radius: 56),
                    const SizedBox(height: 24),
                    Text(
                      c.peerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 28, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      status,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 17,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      peer != null && peer.hops == 1
                          ? 'Direct · offline voice over the mesh'
                          : 'Waiting for a direct link…',
                      style: const TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                    const Spacer(flex: 2),
                    if (c.phase == CallPhase.incoming)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _RoundButton(
                            icon: Icons.call_end_rounded,
                            label: 'Decline',
                            color: kSosRed,
                            onTap: mesh.declineCall,
                          ),
                          _RoundButton(
                            icon: Icons.call_rounded,
                            label: 'Answer',
                            color: const Color(0xFF2E7D32),
                            onTap: _accept,
                          ),
                        ],
                      )
                    else
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _RoundButton(
                            icon: c.muted ? Icons.mic_off_rounded : Icons.mic_none_rounded,
                            label: c.muted ? 'Unmute' : 'Mute',
                            color: c.muted ? Colors.white : Colors.white12,
                            iconColor: c.muted ? Colors.black : Colors.white,
                            onTap: c.phase == CallPhase.active
                                ? () => mesh.setMuted(!c.muted)
                                : null,
                          ),
                          _RoundButton(
                            icon: Icons.call_end_rounded,
                            label: 'End',
                            color: kSosRed,
                            onTap: () => mesh.endCall(),
                          ),
                          _RoundButton(
                            icon: c.speaker ? Icons.volume_up_rounded : Icons.hearing_rounded,
                            label: c.speaker ? 'Speaker' : 'Earpiece',
                            color: c.speaker ? Colors.white : Colors.white12,
                            iconColor: c.speaker ? Colors.black : Colors.white,
                            onTap: c.phase == CallPhase.active
                                ? () => mesh.setSpeaker(!c.speaker)
                                : null,
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color iconColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: color,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 68,
                height: 68,
                child: Icon(icon, color: iconColor, size: 30),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        ],
      ),
    );
  }
}