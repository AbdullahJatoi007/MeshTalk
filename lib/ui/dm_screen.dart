import 'package:flutter/material.dart';

import '../mesh/mesh_service.dart';
import '../platform/permissions.dart';
import 'widgets.dart';

/// End-to-end encrypted 1-to-1 chat. Relays carry it but can't read it.
/// Voice calls are offered only when the person is in direct range.
class DmScreen extends StatefulWidget {
  const DmScreen({super.key, required this.mesh, required this.peerId});
  final MeshService mesh;
  final String peerId;

  @override
  State<DmScreen> createState() => _DmScreenState();
}

class _DmScreenState extends State<DmScreen> {
  MeshService get mesh => widget.mesh;

  @override
  void initState() {
    super.initState();
    mesh.openThread = widget.peerId;
    WidgetsBinding.instance.addPostFrameCallback((_) => mesh.markRead(widget.peerId));
  }

  @override
  void dispose() {
    if (mesh.openThread == widget.peerId) mesh.openThread = null;
    super.dispose();
  }

  Future<void> _call() async {
    if (!await requestMicrophone()) {
      if (mounted) showError(context, StateError('Microphone permission is needed for calls'));
      return;
    }
    try {
      // The app shows the call screen as soon as the call exists.
      await mesh.startCall(widget.peerId);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) {
        final peer = mesh.peer(widget.peerId);
        final name = mesh.nameFor(widget.peerId);
        final msgs = mesh.thread(widget.peerId);
        final reachable = peer != null && mesh.running;
        final canCall = mesh.canCall(widget.peerId);
        if ((mesh.unreadDm[widget.peerId] ?? 0) > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) => mesh.markRead(widget.peerId));
        }

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(
              children: [
                Avatar(id: widget.peerId, name: name, radius: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        !reachable
                            ? 'Not in the mesh right now'
                            : peer!.hops <= 1
                            ? 'Direct · encrypted'
                            : '${peer.hops} hops away · encrypted',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: canCall
                    ? 'Voice call'
                    : 'Calls work only with phones in direct range',
                onPressed: canCall
                    ? _call
                    : () => showError(
                    context,
                    StateError(mesh.call != null
                        ? 'You are already in a call'
                        : 'Calls work only when $name is in direct range (1 hop)')),
                icon: Icon(Icons.call_outlined,
                    color: canCall ? null : Theme.of(context).disabledColor),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: msgs.isEmpty
                    ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.lock_outline, size: 18),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Only $name can read these messages, photos and '
                                'voice messages, even though other phones relay them.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
                    : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) =>
                      MessageBubble(m: msgs[msgs.length - 1 - i], showSender: false),
                ),
              ),
              Composer(
                enabled: reachable,
                hint: reachable ? 'Private message' : 'Waiting for $name to rejoin…',
                onSend: (t) => mesh.sendDm(widget.peerId, t),
                onSendImage: (jpeg) => mesh.sendImage(jpeg, toPeer: widget.peerId),
                onSendVoice: (path, durMs) =>
                    mesh.sendVoice(path, durMs, toPeer: widget.peerId),
              ),
            ],
          ),
        );
      },
    );
  }
}