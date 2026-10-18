import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../mesh/mesh_service.dart';
import '../mesh/router.dart';
import '../platform/native_bridge.dart';
import '../platform/permissions.dart';
import 'dm_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.mesh});
  final MeshService mesh;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  String? _blocker; // why the mesh couldn't start
  bool _permanent = false;
  bool _hideNativeNotice = false;

  MeshService get mesh => widget.mesh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startMesh());
  }

  Future<void> _startMesh() async {
    final r = await requestMeshPermissions();
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _permanent = r.permanentlyDenied;
        _blocker = r.locationServiceOff
            ? 'Turn on Location. Android needs it to find nearby phones on this version.'
            : 'MeshTalk needs the Nearby devices permission to find and talk to phones around you.';
      });
      return;
    }
    setState(() => _blocker = null);
    await mesh.start();
  }

  Future<void> _confirmSos() async {
    final ctrl = TextEditingController(text: 'I need help');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // keyboard opens over the dialog: let it scroll, not overflow
        icon: const Icon(Icons.sos, color: kSosRed, size: 40),
        title: const Text('Send SOS to everyone?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
                'Every phone in the mesh gets an alert and relays it before any other message. '
                'Say where you are.'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              minLines: 1,
              maxLines: 3,
              maxLength: 300,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'e.g. Injured near the main gate'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: kSosRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Send SOS'),
          ),
        ],
      ),
    );
    // (controller not disposed here: the dialog's closing animation still uses it)
    final text = ctrl.text;
    if (ok == true) {
      mesh.sendSos(text.trim().isEmpty ? 'I need help' : text);
      setState(() => _tab = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: mesh,
      builder: (context, _) {
        final peers = mesh.peers;
        final bcCount = mesh.bitchatPeers.length;
        final status = !mesh.running
            ? 'Mesh off'
            : mesh.linkCount == 0 && bcCount == 0
                ? 'Searching nearby…'
                : '${mesh.linkCount} direct · ${peers.length} in mesh'
                    '${bcCount > 0 ? ' · $bcCount bitchat' : ''}';

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('MeshTalk', maxLines: 1, overflow: TextOverflow.ellipsis),
                Row(
                  children: [
                    _Dot(on: mesh.running && mesh.linkCount > 0, searching: mesh.running),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: kSosRed,
                    foregroundColor: Colors.white,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: mesh.running ? _confirmSos : null,
                  icon: const Icon(Icons.sos, size: 20),
                  label: const Text('SOS'),
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'toggle') {
                    if (mesh.running) {
                      await mesh.stop();
                    } else {
                      await _startMesh();
                    }
                  } else if (v == 'clear') {
                    await mesh.clearHistory();
                  } else if (v == 'bitchat') {
                    await mesh.setBitchatEnabled(!mesh.bitchatEnabled);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'toggle',
                      child: Text(mesh.running ? 'Turn mesh off' : 'Turn mesh on')),
                  CheckedPopupMenuItem(
                    value: 'bitchat',
                    checked: mesh.bitchatEnabled,
                    child: const Text('Talk with bitchat users'),
                  ),
                  const PopupMenuItem(value: 'clear', child: Text('Clear message history')),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              if (mesh.sosAlert != null) _SosBanner(m: mesh.sosAlert!, onDismiss: mesh.dismissSos),
              if (!NativeBridge.available && !_hideNativeNotice)
                _Notice(
                  text: 'Background mode is off: the app\'s Android code is out of date. '
                      'Stop the app and run a full rebuild (flutter run), not a hot restart.',
                  action: 'OK',
                  onAction: () async => setState(() => _hideNativeNotice = true),
                ),
              if (_blocker != null)
                _Notice(
                  text: _blocker!,
                  action: _permanent ? 'Open settings' : 'Try again',
                  onAction: () async {
                    if (_permanent) {
                      await openAppSettings();
                    } else {
                      await _startMesh();
                    }
                  },
                )
              else if (mesh.lastError != null && mesh.linkCount == 0)
                _Notice(text: mesh.lastError!, action: 'Retry', onAction: () async {
                  await mesh.stop();
                  await _startMesh();
                }),
              Expanded(
                child: IndexedStack(
                  index: _tab,
                  children: [
                    _PublicChat(mesh: mesh),
                    _People(mesh: mesh, peers: peers),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              const NavigationDestination(
                  icon: Icon(Icons.forum_outlined),
                  selectedIcon: Icon(Icons.forum),
                  label: 'Everyone'),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: mesh.totalUnread > 0,
                  label: Text('${mesh.totalUnread}'),
                  child: const Icon(Icons.people_outline),
                ),
                selectedIcon: const Icon(Icons.people),
                label: 'People (${peers.length + bcCount})',
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.on, required this.searching});
  final bool on, searching;
  @override
  Widget build(BuildContext context) {
    final c = on ? Colors.green : (searching ? Colors.amber : Colors.grey);
    return Container(
        width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle));
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.action, required this.onAction});
  final String text, action;
  final Future<void> Function() onAction;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Expanded(child: Text(text, style: TextStyle(color: cs.onTertiaryContainer))),
            TextButton(onPressed: onAction, child: Text(action)),
          ],
        ),
      ),
    );
  }
}

class _SosBanner extends StatelessWidget {
  const _SosBanner({required this.m, required this.onDismiss});
  final ChatMessage m;
  final VoidCallback onDismiss;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: kSosRed,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(
            children: [
              const Icon(Icons.sos, color: Colors.white, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SOS from ${m.fromName} · ${m.hops} hop${m.hops == 1 ? '' : 's'} away',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w700)),
                    Text(m.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              IconButton(
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close, color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PublicChat extends StatelessWidget {
  const _PublicChat({required this.mesh});
  final MeshService mesh;

  @override
  Widget build(BuildContext context) {
    final feed = mesh.publicFeed;
    return Column(
      children: [
        Expanded(
          child: feed.isEmpty
              ? const _Empty(
                  icon: Icons.forum_outlined,
                  title: 'No messages yet',
                  body: 'Messages here go to everyone in the mesh, '
                      'including phones several hops away.')
              : ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: feed.length,
                  itemBuilder: (_, i) => MessageBubble(m: feed[feed.length - 1 - i]),
                ),
        ),
        Composer(
          enabled: mesh.running,
          hint: 'Message everyone',
          onSend: (t) async => mesh.sendPublic(t),
          onSendImage: (jpeg) => mesh.sendImage(jpeg),
          onSendVoice: (path, durMs) => mesh.sendVoice(path, durMs),
        ),
      ],
    );
  }
}

class _People extends StatelessWidget {
  const _People({required this.mesh, required this.peers});
  final MeshService mesh;
  final List<PeerInfo> peers;

  void _open(BuildContext context, String id) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DmScreen(mesh: mesh, peerId: id)));
  }

  @override
  Widget build(BuildContext context) {
    final offline = mesh.offlineConversations;
    final bitchat = mesh.bitchatPeers;
    if (peers.isEmpty && offline.isEmpty && bitchat.isEmpty) {
      return const _Empty(
        icon: Icons.radar,
        title: 'Looking for people nearby',
        body: 'Phones running MeshTalk within about 100 m connect automatically. '
            'People further away appear once someone in between joins.',
      );
    }
    return ListView(
      children: [
        for (final p in peers)
          ListTile(
            leading: Avatar(id: p.nodeId, name: p.name),
            title: Text(p.name),
            subtitle: Text(p.hops <= 1
                ? 'Direct · in range'
                : '${p.hops} hops away · relayed by ${p.hops - 1} phone${p.hops == 2 ? '' : 's'}'),
            trailing: _Unread(n: mesh.unreadDm[p.nodeId] ?? 0, hops: p.hops),
            onTap: () => _open(context, p.nodeId),
          ),
        if (bitchat.isNotEmpty || (mesh.bitchatEnabled && mesh.bitchatProblem != null)) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('On bitchat (public chat only)'),
          ),
          if (mesh.bitchatProblem != null)
            ListTile(
              leading: const Icon(Icons.bluetooth_disabled),
              title: const Text("Can't reach bitchat users"),
              subtitle: Text(mesh.bitchatProblem!),
            ),
          for (final p in bitchat)
            ListTile(
              leading: Avatar(id: p.id, name: p.nickname),
              title: Text(p.nickname),
              subtitle: Text(
                  '${p.isMeshTalk ? 'MeshTalk via Bluetooth' : 'bitchat'} · ${p.hops <= 1 ? 'direct' : '~${p.hops} hops'}'),
              trailing: const Icon(Icons.bluetooth, size: 18),
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(p.isMeshTalk
                    ? '${p.nickname} is only reachable over Bluetooth right now. '
                        'Message them in Everyone.'
                    : 'Private messages to bitchat users aren\'t supported yet. '
                        'Write to ${p.nickname} in Everyone.'),
              )),
            ),
        ],
        if (offline.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Not in the mesh right now'),
          ),
          for (final m in offline)
            ListTile(
              leading: Opacity(
                  opacity: 0.5,
                  child: Avatar(id: m.peerId!, name: mesh.nameFor(m.peerId!))),
              title: Text(mesh.nameFor(m.peerId!)),
              subtitle: Text(m.preview, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: _Unread(n: mesh.unreadDm[m.peerId!] ?? 0),
              onTap: () => _open(context, m.peerId!),
            ),
        ],
      ],
    );
  }
}

class _Unread extends StatelessWidget {
  const _Unread({required this.n, this.hops});
  final int n;
  final int? hops;
  @override
  Widget build(BuildContext context) {
    if (n > 0) return Badge(label: Text('$n'));
    if (hops == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        hops!.clamp(1, 4).toInt(),
        (_) => const Padding(
          padding: EdgeInsets.only(left: 2),
          child: Icon(Icons.circle, size: 6),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: t.colorScheme.primary),
            const SizedBox(height: 12),
            Text(title, style: t.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(body, textAlign: TextAlign.center, style: t.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
