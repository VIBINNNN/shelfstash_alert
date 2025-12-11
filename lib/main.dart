import 'dart:async';
import 'dart:html' as html;
import 'dart:math';
import 'package:flutter/material.dart';

// shared notifiers
final ValueNotifier<String> usernameNotifier = ValueNotifier<String>('Username');

//(fixes disappearing items)
final ValueNotifier<List<PantryItem>> pantryNotifier = ValueNotifier<List<PantryItem>>([]);

// notifications are derived but kept as separate list for the notifications tab UI
final ValueNotifier<List<PantryItem>> notificationsNotifier = ValueNotifier<List<PantryItem>>([]);

final Set<String> dismissedNotificationIds = {}; // user-dismissed notifications (prevents re-alerting)
final Map<String, Set<String>> alertedTypesGlobal = {}; // alert-type tracking global map
void Function()? triggerExpiryCheck; // callback so ItemDetail can request an immediate re-check

Future<void> Function()? globalEnsureAudioPrimed; // exposed priming hook for ItemDetail

//Models
class PantryItem {
  String id;
  String name;
  DateTime expiry;
  String notes;
  PantryItem({required this.id, required this.name, required this.expiry, this.notes = ''});

  PantryItem copyWith({String? name, DateTime? expiry, String? notes}) {
    return PantryItem(
      id: id,
      name: name ?? this.name,
      expiry: expiry ?? this.expiry,
      notes: notes ?? this.notes,
    );
  }
}

// App Entry
void main() {
  // populate initial pantry items
  pantryNotifier.value = [
    PantryItem(id: 'milk', name: 'Milk', expiry: DateTime.now().add(const Duration(days: 1)), notes: '2L'),
    PantryItem(id: 'rice', name: 'Rice', expiry: DateTime.now().add(const Duration(days: 9)), notes: '5kg'),
    PantryItem(id: 'yogurt', name: 'Yogurt', expiry: DateTime.now().subtract(const Duration(days: 1)), notes: 'strawberry'),
  ];
  runApp(const ShelfStashApp());
}

class ShelfStashApp extends StatelessWidget {
  const ShelfStashApp({super.key});

  @override
  Widget build(BuildContext context) {
    final primary = const Color(0xFF00A896);
    return MaterialApp(
      title: 'ShelfStash',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: primary,
        // keep the app's accent/primary color
        colorScheme: ColorScheme.fromSwatch(primarySwatch: createMaterialColor(primary)).copyWith(secondary: primary),
        // global background -> black per request
        scaffoldBackgroundColor: Colors.black,
        // AppBar dark themed so icons/text are visible
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
          iconTheme: IconThemeData(color: Colors.white),
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
        ),
        textTheme: const TextTheme(
          titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
          bodyMedium: TextStyle(fontSize: 14, color: Colors.white),
          bodyLarge: TextStyle(color: Colors.white),
        ),
      ),
      home: const HomeShell(),
    );
  }

  static MaterialColor createMaterialColor(Color color) {
    List strengths = <double>[.05];
    Map<int, Color> swatch = {};
    final int r = color.red, g = color.green, b = color.blue;
    for (int i = 1; i < 10; i++) {
      strengths.add(0.1 * i);
    }
    for (var strength in strengths) {
      final double ds = 0.5 - strength;
      swatch[(strength * 1000).round()] = Color.fromRGBO(
        r + ((ds < 0 ? r : (255 - r)) * ds).round(),
        g + ((ds < 0 ? g : (255 - g)) * ds).round(),
        b + ((ds < 0 ? b : (255 - b)) * ds).round(),
        1,
      );
    }
    return MaterialColor(color.value, swatch);
  }
}

//Shell
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  _HomeShellState createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;
  late final List<Widget> pages;

  @override
  void initState() {
    super.initState();
    pages = [const HomePage(), const NotificationsPage(), ProfilePage()];
  }

  void _onNavTap(int idx) {
    setState(() => _selectedIndex = idx);
  }

  @override
  Widget build(BuildContext context) {
    // bottom nav icons should be white/green on dark background
    return Scaffold(
      body: SafeArea(child: pages[_selectedIndex]),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: Colors.black,
        currentIndex: _selectedIndex,
        onTap: _onNavTap,
        selectedItemColor: Theme.of(context).colorScheme.secondary,
        unselectedItemColor: Colors.grey[400],
        items: [
          const BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(
            icon: ValueListenableBuilder<List<PantryItem>>(
              valueListenable: notificationsNotifier,
              builder: (_, list, __) {
                return SizedBox(
                  width: 36,
                  height: 36,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Center(child: Icon(Icons.notifications)),
                      if (list.isNotEmpty)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: CircleAvatar(
                            radius: 9,
                            backgroundColor: Colors.red,
                            child: Text('${list.length}', style: const TextStyle(fontSize: 9, color: Colors.white)),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            label: 'Notifications',
          ),
          const BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

//Home Page
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  Timer? _pollTimer;
  DateTime _suppressAlertsUntil = DateTime.fromMillisecondsSinceEpoch(0);

  static const int pollIntervalSeconds = 60;

  late html.AudioElement _preloadedAudio;
  bool _audioPrimedFlag = false;

  // new: single controller for the white-streak animation
  late AnimationController _streakController;

  // pending notifications that had audio suppressed because audio wasn't primed yet
  final List<String> _pendingAudioNotificationIds = [];

  // overlay control for confirmation popup/confetti (currently unused for add dialog)
  final GlobalKey<ConfettiOverlayState> _confettiKey = GlobalKey<ConfettiOverlayState>();

  @override
  void initState() {
    super.initState();

    // preload audio
    _preloadedAudio = html.AudioElement('assets/sounds/alert.mp3')..preload = 'auto';
    _preloadedAudio.load();

    // streak animation controller (repeats)
    _streakController = AnimationController(vsync: this, duration: const Duration(seconds: 5))..repeat();

    // visibility listener: prevent spurious alerts for tiny switches
    html.document.onVisibilityChange.listen((_) {
      if (html.document.hidden == false) {
        _suppressAlertsUntil = DateTime.now().add(const Duration(seconds: 1));
      }
    });

    // initial check and periodic checks
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkExpiryAndNotify());
    _pollTimer = Timer.periodic(const Duration(seconds: pollIntervalSeconds), (_) => _checkExpiryAndNotify());

    // register callback for other pages to request an immediate re-check
    triggerExpiryCheck = _checkExpiryAndNotify;

    // expose priming hook
    globalEnsureAudioPrimed = ensureAudioPrimed;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _streakController.dispose();
    if (triggerExpiryCheck == _checkExpiryAndNotify) triggerExpiryCheck = null;
    if (globalEnsureAudioPrimed == ensureAudioPrimed) globalEnsureAudioPrimed = null;
    super.dispose();
  }

  // Ensure audio is primed (must be called during a user gesture to satisfy browser policies)
  Future<void> ensureAudioPrimed() async {
    if (_audioPrimedFlag) return;
    try {
      await _preloadedAudio.play();
      _preloadedAudio.pause();
      _preloadedAudio.currentTime = 0;
      _audioPrimedFlag = true;
      // if there are pending notification audio requests, play them now
      if (_pendingAudioNotificationIds.isNotEmpty) {
        for (final id in List<String>.from(_pendingAudioNotificationIds)) {
          // ignore: cast_from_null_always_fails
          pantryNotifier.value.firstWhere((p) => p.id == id, orElse: () => null as PantryItem);
          await Future.delayed(const Duration(milliseconds: 80));
          try {
            _preloadedAudio.currentTime = 0;
            await _preloadedAudio.play();
          } catch (_) {}
          _pendingAudioNotificationIds.remove(id);
        }
      }
    } catch (e) {
      print('Audio priming failed: $e');
    }
  }

  // central check - create notifications and play audio (or enqueue if not primed)
  void _checkExpiryAndNotify() {
    if (DateTime.now().isBefore(_suppressAlertsUntil)) return;

    final now = DateTime.now();
    final oneDayAhead = now.add(const Duration(days: 1));

    final items = pantryNotifier.value;

    for (final item in items) {
      // skip if user dismissed the notification for this item
      if (dismissedNotificationIds.contains(item.id)) continue;

      alertedTypesGlobal.putIfAbsent(item.id, () => <String>{});
      final alreadyOneDay = alertedTypesGlobal[item.id]!.contains('one_day');
      final alreadyExpired = alertedTypesGlobal[item.id]!.contains('expired');

      final isWithinOneDay = item.expiry.isAfter(now) && !item.expiry.isAfter(oneDayAhead);
      final isExpired = item.expiry.isBefore(now) || item.expiry.isAtSameMomentAs(now);

      if (isWithinOneDay && !alreadyOneDay) {
        alertedTypesGlobal[item.id]!.add('one_day');
        _addNotificationIfMissing(item);
        _playOrEnqueueAudio(item.id);
        _showSnackBar('${item.name} will expire in ${item.expiry.difference(now).inDays <= 0 ? "<1" : item.expiry.difference(now).inDays} day(s) — use soon!');
        continue;
      }

      if (isExpired && !alreadyExpired) {
        alertedTypesGlobal[item.id]!.add('expired');
        _addNotificationIfMissing(item);
        _playOrEnqueueAudio(item.id);
        _showSnackBar('${item.name} has expired');
        continue;
      }
    }
  }

  void _addNotificationIfMissing(PantryItem item) {
    final nowList = List<PantryItem>.from(notificationsNotifier.value);
    if (!nowList.any((e) => e.id == item.id)) {
      nowList.insert(0, item);
      notificationsNotifier.value = nowList;
    }
  }

  // play audio immediately if primed, otherwise enqueue and show an enable-sound banner
  void _playOrEnqueueAudio(String itemId) {
    if (_audioPrimedFlag) {
      try {
        _preloadedAudio.currentTime = 0;
        _preloadedAudio.play();
      } catch (e) {
        print('Play error: $e');
      }
    } else {
      if (!_pendingAudioNotificationIds.contains(itemId)) _pendingAudioNotificationIds.add(itemId);
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.grey[900],
        content: Text(message, style: const TextStyle(color: Colors.white)),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'View',
          textColor: Colors.green[300],
          onPressed: () {
            final shell = context.findAncestorStateOfType<_HomeShellState>();
            if (shell != null) {
              shell._onNavTap(1); // go to notifications
            }
          },
        ),
      ),
    );
  }

  // NEW: show an editable dialog for creating a new item (user gesture -> primes audio)
  Future<void> _showAddItemDialogAndSave() async {
    // prime audio on gesture
    await ensureAudioPrimed();

    final now = DateTime.now();
    final newId = DateTime.now().millisecondsSinceEpoch.toString();
    final defaultItem = PantryItem(
      id: newId,
      name: 'Sample Item',
      expiry: now.add(const Duration(days: 1)),
      notes: 'Demo',
    );

    // barrierDismissible: true so the user can tap outside if something odd happens
    final result = await showDialog<PantryItem>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ItemEditDialog(item: defaultItem),
    );

    if (result != null) {
      // save to pantry (only once)
      final list = List<PantryItem>.from(pantryNotifier.value);
      if (!list.any((p) => p.id == result.id)) {
        list.insert(0, result);
        pantryNotifier.value = list;
      }

      // run check immediately to create notifications if needed
      _checkExpiryAndNotify();
      // IMPORTANT: do NOT call global saved confirmation here.
      // The dialog itself shows the "Item saved" UI and local confetti.
    }
  }

  // (kept for future use but not used by Add dialog anymore)
  Future<void> _showSavedConfirmationAndConfetti() async {
    try {
      await ensureAudioPrimed();
      final cheer = html.AudioElement('assets/sounds/cheer.mp3')..preload = 'auto';
      cheer.load();
      await cheer.play();
    } catch (e) {
      print('Cheer audio failed: $e');
    }

    _confettiKey.currentState?.showConfetti();

    final overlay = Overlay.of(context);
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 24,
        right: 24,
        bottom: 40,
        child: Material(
          color: Colors.transparent,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.green[700],
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text('Item saved', style: TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);

    await Future.delayed(const Duration(milliseconds: 3000));
    entry.remove();
    _confettiKey.currentState?.hideConfetti();
  }

  // user-gesture actions prime audio and then perform action
  void _addSample() {
    _showAddItemDialogAndSave();
  }

  void _manualRefresh() async {
    await ensureAudioPrimed();
    _checkExpiryAndNotify();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Checked for expiries')));
  }

  void _cookNow() async {
    await ensureAudioPrimed();

    final have = pantryNotifier.value.map((e) => e.name.toLowerCase()).toList();
    final Map<String, List<String>> recipes = {
      'Fried Rice': ['rice', 'egg', 'vegetables'],
      'Creamy Porridge': ['milk', 'oats', 'banana'],
      'Milkshake': ['milk', 'banana', 'ice'],
      'Omelette': ['egg', 'salt', 'butter'],
    };

    final List<Widget> content = [];
    recipes.forEach((r, ingredients) {
      final haveCount = ingredients.where((ing) => have.any((h) => h.contains(ing))).length;
      final haveAll = haveCount == ingredients.length;
      content.add(
        Row(
          children: [
            Expanded(child: Text(r, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white))),
            const SizedBox(width: 8),
            Text(
              haveAll ? 'Ready' : '$haveCount/${ingredients.length}',
              style: TextStyle(color: haveAll ? Colors.green[300] : Colors.orange),
            ),
          ],
        ),
      );
      content.add(const SizedBox(height: 6));
      content.add(
        Text(
          'Ingredients: ${ingredients.join(', ')}',
          style: TextStyle(color: Colors.grey[350], fontSize: 13),
        ),
      );
      content.add(const Divider(color: Colors.grey));
    });

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.green[700],
        title: const Text('Recipe Suggestions', style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: content,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
        ],
      ),
    );
  }

  // UI pieces
  Widget _buildEnableSoundBanner() {
    final hasPending = notificationsNotifier.value.isNotEmpty &&
        !_audioPrimedFlag &&
        _pendingAudioNotificationIds.isNotEmpty;
    if (!hasPending) return const SizedBox.shrink();
    return Container(
      color: Colors.yellow[700],
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Sound is disabled for notifications. Tap to enable sound and play pending alerts.',
              style: TextStyle(color: Colors.black),
            ),
          ),
          TextButton(
            onPressed: () async {
              await ensureAudioPrimed();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sound enabled')));
            },
            child: const Text('Enable sound'),
          )
        ],
      ),
    );
  }

  Widget _buildOverviewCard() {
    const totalSavedKg = 12;
    const points = 1200;
    return Card(
      color: Colors.green[700], // changed from white to green box
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ValueListenableBuilder<String>(
                    valueListenable: usernameNotifier,
                    builder: (_, name, __) =>
                        Text('Good afternoon, $name', style: Theme.of(context).textTheme.titleLarge),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _miniStat('Food Saved', '$totalSavedKg kg'),
                      const SizedBox(width: 12),
                      _miniStat('Points', '$points'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text('Pantry Overview', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(value: 0.6, minHeight: 8, color: Colors.greenAccent),
                  const SizedBox(height: 6),
                  Text('Smart recipe suggestions below', style: TextStyle(color: Colors.grey[300], fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _xpCircle(points),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(String title, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(fontSize: 12, color: Colors.grey[300])),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
      ],
    );
  }

  Widget _xpCircle(int points) {
    return Container(
      width: 72,
      height: 72,
      decoration: BoxDecoration(
        color: Colors.green[600],
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          '$points',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildRecipeCard() {
    return Card(
      color: Colors.green[700], // changed
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Smart Recipe Suggestion', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
                  const SizedBox(height: 6),
                  Text(
                    'Cook before it\'s too late! Try something new today!',
                    style: TextStyle(color: Colors.grey[300]),
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(onPressed: _cookNow, child: const Text('Cook Now')),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 70,
              height: 70,
              color: Colors.green[600], // changed from grey[200]
              child: Icon(Icons.restaurant, size: 36, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsAboveList() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _addSample,
              icon: const Icon(Icons.add),
              label: const Text('Add Sample Item'),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _manualRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh List'),
          ),
        ],
      ),
    );
  }

  Widget _buildPantryList() {
    return ValueListenableBuilder<List<PantryItem>>(
      valueListenable: pantryNotifier,
      builder: (_, list, __) {
        if (list.isEmpty) return const Center(child: Text('No pantry items found.', style: TextStyle(color: Colors.white)));
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          itemCount: list.length,
          separatorBuilder: (_, __) => const Divider(color: Colors.grey),
          itemBuilder: (context, i) {
            final it = list[i];
            final daysLeft = it.expiry.difference(DateTime.now()).inDays;
            final subtitle = it.expiry.isBefore(DateTime.now())
                ? 'Expired ${-daysLeft} day(s) ago'
                : 'Expires in $daysLeft day(s)';
            return Card(
              color: Colors.green[700], // item cards turned green
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                title: Text(it.name, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
                subtitle: Text(subtitle, style: const TextStyle(color: Colors.white70)),
                trailing: Text(
                  it.expiry.toLocal().toString().split(' ').first,
                  style: TextStyle(color: Colors.grey[200]),
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ItemDetailPage(
                      item: it,
                      onSave: (updated) {
                        // update pantry shared list
                        final cur = List<PantryItem>.from(pantryNotifier.value);
                        final idx = cur.indexWhere((e) => e.id == updated.id);
                        if (idx != -1) {
                          cur[idx] = updated;
                          pantryNotifier.value = cur;
                        }
                        // also update notifications list if present
                        final curN = List<PantryItem>.from(notificationsNotifier.value);
                        final nidx = curN.indexWhere((n) => n.id == updated.id);
                        if (nidx != -1) {
                          curN[nidx] = updated;
                          notificationsNotifier.value = curN;
                        }
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // helper: the moving white streak painter widget
  Widget _buildMovingStreak() {
    return AnimatedBuilder(
      animation: _streakController,
      builder: (context, child) {
        final t = _streakController.value; // 0..1
        // compute x based on t, move left->right then loop
        final screenW = MediaQuery.of(context).size.width;
        final streakWidth = max(80.0, screenW * 0.18);
        final x = (screenW + streakWidth) * t - streakWidth;
        return Positioned(
          left: x,
          top: -60,
          child: Transform.rotate(
            angle: -0.35, // angle the streak slightly for effect
            child: Container(
              width: streakWidth,
              height: MediaQuery.of(context).size.height * 1.6,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.white.withOpacity(0.0),
                    Colors.white.withOpacity(0.07),
                    Colors.white.withOpacity(0.12),
                    Colors.white.withOpacity(0.07),
                    Colors.white.withOpacity(0.0),
                  ],
                ),
                // slight blur effect could be added with BackdropFilter, but keep simple for performance
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // static black background (global scaffoldBackgroundColor is black too)
        Container(color: Colors.black),
        // moving white streak overlay that animates across all pages
        _buildMovingStreak(),

        // Rest of UI sits above the streak
        // Use transparent scaffold backgrounds so streak is visible behind
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: Row(
              children: [
                const Text('ShelfStash', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Icon(Icons.kitchen, color: Theme.of(context).colorScheme.secondary),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () {},
              ),
            ],
          ),
          body: Column(
            children: [
              // banner to enable sound if needed
              ValueListenableBuilder<List<PantryItem>>(
                valueListenable: notificationsNotifier,
                builder: (_, __, ___) => _buildEnableSoundBanner(),
              ),
              _buildOverviewCard(),
              _buildRecipeCard(),
              _buildControlsAboveList(),
              const SizedBox(height: 6),
              Expanded(child: _buildPantryList()),
            ],
          ),
        ),

        // Confetti overlay (keeps confetti drawing above everything)
        ConfettiOverlay(key: _confettiKey),
      ],
    );
  }
}

//Notifications Page 
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  // Dismiss all
  void _dismissAll() {
    final cur = List<PantryItem>.from(notificationsNotifier.value);
    for (final item in cur) {
      dismissedNotificationIds.add(item.id);
      alertedTypesGlobal.putIfAbsent(item.id, () => <String>{});
      alertedTypesGlobal[item.id]!.addAll({'one_day', 'expired'});
    }
    notificationsNotifier.value = [];
    // request re-check
    triggerExpiryCheck?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Notifications', style: TextStyle(color: Colors.white)),
        leading: Navigator.canPop(context) ? const BackButton(color: Colors.white) : null,
        actions: [
          IconButton(
            tooltip: 'Dismiss all notifications',
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              _dismissAll();
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('All notifications dismissed')));
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: ValueListenableBuilder<List<PantryItem>>(
          valueListenable: notificationsNotifier,
          builder: (_, list, __) {
            if (list.isEmpty) return const Center(child: Text('No notifications.', style: TextStyle(color: Colors.white)));
            return ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final it = list[i];
                final daysLeft = it.expiry.difference(DateTime.now()).inDays;
                final text = it.expiry.isBefore(DateTime.now())
                    ? '${it.name} has expired'
                    : '${it.name} is expiring in ${daysLeft <= 0 ? "<1" : daysLeft} day(s)';
                return Card(
                  color: Colors.green[700], // green boxes
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: ListTile(
                    title: Text(it.name, style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
                    subtitle: Text(text, style: const TextStyle(color: Colors.white70)),
                    trailing: Text(it.expiry.toLocal().toString().split(' ').first, style: TextStyle(color: Colors.grey[200])),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ItemDetailPage(
                          item: it,
                          onSave: (updated) {
                            // update pantry and notification item on save
                            final cur = List<PantryItem>.from(pantryNotifier.value);
                            final idx = cur.indexWhere((n) => n.id == updated.id);
                            if (idx != -1) {
                              cur[idx] = updated;
                              pantryNotifier.value = cur;
                            }
                            final curN = List<PantryItem>.from(notificationsNotifier.value);
                            final nidx = curN.indexWhere((n) => n.id == updated.id);
                            if (nidx != -1) {
                              curN[nidx] = updated;
                              notificationsNotifier.value = curN;
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

// Item Detail Page (editable)
class ItemDetailPage extends StatefulWidget {
  final PantryItem item;
  final void Function(PantryItem updated) onSave;
  const ItemDetailPage({super.key, required this.item, required this.onSave});

  @override
  _ItemDetailPageState createState() => _ItemDetailPageState();
}

class _ItemDetailPageState extends State<ItemDetailPage> {
  late TextEditingController _nameController;
  late TextEditingController _notesController;
  late DateTime _expiry;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.item.name);
    _notesController = TextEditingController(text: widget.item.notes);
    _expiry = widget.item.expiry;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _save() async {
    final updated = PantryItem(
      id: widget.item.id,
      name: _nameController.text.trim(),
      expiry: _expiry,
      notes: _notesController.text.trim(),
    );
    widget.onSave(updated);

    // Clear dismissed state (editing implies user wants new checks)
    dismissedNotificationIds.remove(updated.id);

    // Reset alert types so new alerts can trigger depending on new expiry
    alertedTypesGlobal.remove(updated.id);

    // Prime audio (must run in user gesture) so alerts play instantly
    if (globalEnsureAudioPrimed != null) {
      try {
        await globalEnsureAudioPrimed!();
      } catch (_) {}
    }

    // Immediately ask HomePage to re-check (so you get the new one-day alert if applicable)
    triggerExpiryCheck?.call();

    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Item updated')));
  }

  void _dismissNotification() async {
    final cur = List<PantryItem>.from(notificationsNotifier.value);
    cur.removeWhere((n) => n.id == widget.item.id);
    notificationsNotifier.value = cur;

    // mark as dismissed so it won't re-alert
    dismissedNotificationIds.add(widget.item.id);

    // also mark both alert types (safe-guard)
    alertedTypesGlobal.putIfAbsent(widget.item.id, () => <String>{});
    alertedTypesGlobal[widget.item.id]!.addAll({'one_day', 'expired'});

    // request a re-check (no beep because dismissed set prevents it)
    triggerExpiryCheck?.call();

    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Notification dismissed')));
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiry,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (picked != null) setState(() => _expiry = picked);
  }

  @override
  Widget build(BuildContext context) {
    final expired = _expiry.isBefore(DateTime.now());
    final daysLeft = _expiry.difference(DateTime.now()).inDays;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(widget.item.name, style: const TextStyle(color: Colors.white)),
        leading: const BackButton(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Edit item', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(labelText: 'Item name', border: const OutlineInputBorder(), fillColor: Colors.green[700], filled: true, labelStyle: const TextStyle(color: Colors.white70)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notesController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(labelText: 'Notes', border: const OutlineInputBorder(), fillColor: Colors.green[700], filled: true, labelStyle: const TextStyle(color: Colors.white70)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today),
                  label: const Text('Pick expiry date'),
                ),
                const SizedBox(width: 12),
                Text(_expiry.toLocal().toString().split(' ').first, style: const TextStyle(color: Colors.white)),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _dismissNotification,
                  icon: const Icon(Icons.delete),
                  label: const Text('Dismiss Notification'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(expired ? 'Expired ${-daysLeft} day(s) ago' : 'Expires in $daysLeft day(s)', style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

//Profile Page 
class ProfilePage extends StatelessWidget {
  final TextEditingController _controller = TextEditingController();
  ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    _controller.text = usernameNotifier.value;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Profile', style: TextStyle(color: Colors.white)),
        leading: Navigator.canPop(context) ? const BackButton(color: Colors.white) : null,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 36,
              backgroundColor: Colors.green[600],
              child: const Icon(Icons.person, size: 40, color: Colors.white),
            ),
            const SizedBox(height: 12),
            const Text('Display name (change below)', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    style: const TextStyle(color: Colors.white),
                    controller: _controller,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: 'Enter display name',
                      hintStyle: TextStyle(color: Colors.white70),
                      filled: true,
                      fillColor: Colors.green[700],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    final newName = _controller.text.trim();
                    if (newName.isNotEmpty) {
                      usernameNotifier.value = newName;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Display name updated')),
                      );
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(color: Colors.grey),
            const SizedBox(height: 8),
            const Text('Achievements', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
            const SizedBox(height: 6),
            const Text('Badges collected: 3', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}


// Item Edit Dialog: returns the created PantryItem to the caller. It does NOT modify pantryNotifier itself.
class ItemEditDialog extends StatefulWidget {
  final PantryItem item;
  const ItemEditDialog({super.key, required this.item});
  @override
  _ItemEditDialogState createState() => _ItemEditDialogState();
}

class _ItemEditDialogState extends State<ItemEditDialog> with SingleTickerProviderStateMixin {
  late TextEditingController _nameController;
  late TextEditingController _notesController;
  late DateTime _expiry;

  bool _isSaving = false;
  PantryItem? _resultItem;
  Timer? _autoCloseTimer;
  bool _hasPopped = false; // guard to avoid multiple pops

  // Confetti: simple local particles used only inside the dialog
  late AnimationController _confettiController;
  final List<_ConfettiParticle> _particles = [];
  final Random _rng = Random();
  bool _confettiVisible = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.item.name);
    _notesController = TextEditingController(text: widget.item.notes);
    _expiry = widget.item.expiry;

    _confettiController = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))
      ..addListener(() {
        // repaint confetti
        setState(() {
          for (final p in _particles) p.update(_confettiController.value);
        });
      })
      ..addStatusListener((st) {
        if (st == AnimationStatus.completed) {
          _confettiVisible = false;
          _particles.clear();
        }
      });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _notesController.dispose();
    _confettiController.dispose();
    _autoCloseTimer?.cancel();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiry,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (picked != null) setState(() => _expiry = picked);
  }

  void _generateParticles(BoxConstraints box) {
    _particles.clear();
    final width = box.maxWidth;
    // We'll create a mix of rectangle confetti + ribbon pieces
    const colors = [
      Color(0xFFE95656),
      Color(0xFF46C48B),
      Color(0xFF5B8CFF),
      Color(0xFFFFC857),
      Color(0xFF9B59B6),
      Color(0xFF4DD0E1),
      Color(0xFFFF7A9A),
    ];
    for (int i = 0; i < 48; i++) {
      final startX = _rng.nextDouble() * width;
      final speed = 0.8 + _rng.nextDouble() * 1.8;
      // width and height produce small rectangles (paper confetti)
      final w = 6.0 + _rng.nextDouble() * 12.0;
      final h = 10.0 + _rng.nextDouble() * 18.0;
      final color = colors[_rng.nextInt(colors.length)];
      // 20% chance to be a ribbon (longer)
      final isRibbon = _rng.nextDouble() < 0.20;
      final shapeType = isRibbon ? _ConfettiShape.ribbon : _ConfettiShape.rectangle;
      _particles.add(_ConfettiParticle(
        startX: startX,
        size: Size(w, h),
        speed: speed,
        color: color,
        rand: _rng,
        shape: shapeType,
      ));
    }
  }

  void _startConfetti(BoxConstraints box) {
    if (_confettiVisible) return;
    _generateParticles(box);
    _confettiVisible = true;
    // start after current frame so layout is stable
    Future.microtask(() => _confettiController.forward(from: 0.0));
  }

  void _fireAndForgetPlayCheer() {
    try {
      final cheer = html.AudioElement('assets/sounds/cheer.mp3')..preload = 'auto';
      cheer.load();
      // do not await; play in background
      cheer.play().catchError((e) {});
    } catch (_) {}
  }

  void _enterSavedState() {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
    });
  }

  void _scheduleAutoClose() {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = Timer(const Duration(milliseconds: 3000), () {
      if (!mounted) return;
      _popResultIfNeeded();
    });
  }

  void _popResultIfNeeded() {
    if (_hasPopped) return;
    _hasPopped = true;
    try {
      Navigator.of(context).pop(_resultItem);
    } catch (_) {}
  }

  Future<void> _onSavePressed() async {
    if (_isSaving) return;

    final created = PantryItem(
      id: widget.item.id,
      name: _nameController.text.trim().isEmpty ? 'Sample Item' : _nameController.text.trim(),
      expiry: _expiry,
      notes: _notesController.text.trim(),
    );
    _resultItem = created;

    // show saved UI immediately
    _enterSavedState();

    // play cheer (fire and forget)
    _fireAndForgetPlayCheer();

    // schedule auto-close
    _scheduleAutoClose();

    // trigger expiry checks (non-blocking)
    try {
      triggerExpiryCheck?.call();
    } catch (_) {}
  }

  void _onClosePressedEarly() {
    _autoCloseTimer?.cancel();
    _popResultIfNeeded();
  }

  @override
  Widget build(BuildContext context) {
    if (_isSaving) {
      // Saved UI: big green Icon tick + text + confined confetti + X to close early
      return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        backgroundColor: Colors.transparent,
        child: LayoutBuilder(builder: (context, constraints) {
          // start confetti when layout is ready
          if (!_confettiVisible) Future.microtask(() => _startConfetti(constraints));

          final dialogWidth = min(constraints.maxWidth, 420.0);
          final dialogHeight = 220.0;

          return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              color: Colors.green[700], // changed from white
              width: dialogWidth,
              height: dialogHeight,
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  // Confined confetti painter behind content
                  if (_confettiVisible)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _ConfettiPainter(List<_ConfettiParticle>.from(_particles)),
                      ),
                    ),

                  // Content centered
                  const Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Large white check icon (visible on green)
                          Icon(Icons.check_circle, color: Colors.white, size: 96),
                          SizedBox(height: 12),
                          Text(
                            'Item saved',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // X button — placed in top-right with safe padding
                  Positioned(
                    right: 4,
                    top: 4,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: _onClosePressedEarly,
                      tooltip: 'Close',
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      );
    }

    // Normal edit UI
    return AlertDialog(
      backgroundColor: Colors.green[700], // changed
      title: const Text('Add item', style: TextStyle(color: Colors.white)),
      content: SingleChildScrollView(
        child: Column(
          children: [
            TextField(controller: _nameController, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Item name', labelStyle: TextStyle(color: Colors.white70))),
            const SizedBox(height: 10),
            TextField(controller: _notesController, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Notes', labelStyle: TextStyle(color: Colors.white70))),
            const SizedBox(height: 10),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.calendar_today),
                  label: const Text('Pick expiry date'),
                ),
                const SizedBox(width: 12),
                Text(_expiry.toLocal().toString().split(' ').first, style: const TextStyle(color: Colors.white)),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            _onSavePressed();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// Confetti Overlay 
class ConfettiOverlay extends StatefulWidget {
  const ConfettiOverlay({super.key});
  @override
  ConfettiOverlayState createState() => ConfettiOverlayState();
}

class ConfettiOverlayState extends State<ConfettiOverlay> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<_ConfettiParticle> _particles = [];
  bool _visible = false;
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 2500))
      ..addListener(() {
        // update particles and rebuild
        setState(() {
          for (final p in _particles) {
            p.update(_controller.value);
          }
        });
      })
      ..addStatusListener((st) {
        if (st == AnimationStatus.completed) {
          _visible = false;
          _particles.clear();
        }
      });
  }

  void showConfetti() {
    // create particles
    _particles.clear();
    final width = MediaQuery.of(context).size.width;
    const colors = [
      Colors.red,
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.yellow,
      Colors.pink,
    ];
    for (int i = 0; i < 48; i++) {
      final startX = _rng.nextDouble() * width;
      final speed = 1.0 + _rng.nextDouble() * 1.6;
      final size = 6.0 + _rng.nextDouble() * 8.0;
      final color = colors[_rng.nextInt(colors.length)];
      _particles.add(
        _ConfettiParticle(
          startX: startX,
          size: Size(size, size),
          speed: speed,
          color: color,
          rand: _rng,
          shape: _ConfettiShape.rectangle,
        ),
      );
    }
    _visible = true;
    _controller.forward(from: 0.0);
  }

  void hideConfetti() {
    _controller.stop();
    _visible = false;
    _particles.clear();
    setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return IgnorePointer(
      child: Positioned.fill(
        child: CustomPaint(
          painter: _ConfettiPainter(List<_ConfettiParticle>.from(_particles)),
        ),
      ),
    );
  }
}

enum _ConfettiShape { rectangle, ribbon }

class _ConfettiParticle {
  // horizontal start (relative to dialog/painter width)
  double startX;
  // size of confetti piece (width, height)
  Size size;
  double speed;
  Color color;
  double progress = 0.0;
  double wobble = 0.0;
  Random rand;
  _ConfettiShape shape;

  // rotation state
  double baseAngle = 0.0;
  double angularVel = 0.0;

  // vertical offset start (allows particles to start slightly above)
  double yOffset = 0.0;

  _ConfettiParticle({
    required this.startX,
    required this.size,
    required this.speed,
    required this.color,
    required this.rand,
    required this.shape,
  }) {
    baseAngle = rand.nextDouble() * pi * 2;
    // angular velocity - some spin, direction varies
    angularVel = (rand.nextDouble() - 0.5) * 8.0; // radians per normalized progress
    yOffset = -20.0 - rand.nextDouble() * 40.0;
  }

  void update(double t) {
    // progress is normalized 0..1 for the painter animation
    progress = t * speed;
    wobble = sin(t * 8.0 + rand.nextDouble() * 3.14);
    // angle evolves with progress
    // clamp angle ranges so ribbons rotate faster
    final spinFactor = (shape == _ConfettiShape.ribbon) ? 2.4 : 1.4;
    baseAngle += angularVel * 0.02 * spinFactor;
  }

  Offset position(Size canvasSize) {
    // x follows startX plus wobble
    final x = startX + wobble * 18;
    // y moves from yOffset to beyond canvas according to progress
    final y = progress * (canvasSize.height + 150) + yOffset;
    return Offset(x, y);
  }

  double opacity() => max(0.0, 1.0 - progress.clamp(0.0, 1.0));
}

class _ConfettiPainter extends CustomPainter {
  final List<_ConfettiParticle> particles;
  _ConfettiPainter(this.particles);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    for (final p in particles) {
      final pos = p.position(size);
      paint.color = p.color.withOpacity(p.opacity());

      // Save canvas state, translate to particle center, rotate, draw rect/ribbon, restore.
      // Center the rectangle on its position (so rotation is natural).
      canvas.save();
      // ensure we stay inside bounds — particles are already generated within width
      // translate to center of the particle
      final cx = pos.dx;
      final cy = pos.dy;
      canvas.translate(cx, cy);
      // apply rotation
      canvas.rotate(p.baseAngle);

      if (p.shape == _ConfettiShape.rectangle) {
        // draw a small rounded rectangle centered at 0,0
        final rect = Rect.fromCenter(center: Offset.zero, width: p.size.width, height: p.size.height);
        final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(1.2));
        // Slight subtle shading: draw a thin darker strip to simulate paper fold
        canvas.drawRRect(rrect, paint);
        // subtle shine line
        final shine = Paint()..style = PaintingStyle.stroke..strokeWidth = 0.8..color = Colors.white.withOpacity(0.12 * p.opacity());
        canvas.drawLine(rect.topLeft + const Offset(1, 1), rect.topRight - const Offset(1, -1), shine);
      } else {
        // Ribbon: longer rounded rectangle with slight curve (we'll draw as rounded rect for perf)
        final w = p.size.width * 2.6;
        final h = p.size.height * 1.1;
        final rect = Rect.fromCenter(center: Offset.zero, width: w, height: h);
        final rrect = RRect.fromRectAndRadius(rect, Radius.circular(h * 0.3));
        canvas.drawRRect(rrect, paint);
        // draw a faint darker lower edge to give depth
        final shade = Paint()..style = PaintingStyle.stroke..strokeWidth = max(0.6, h * 0.06)..color = Colors.black.withOpacity(0.06 * p.opacity());
        canvas.drawRRect(rrect, shade);
      }

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) => true;
}
