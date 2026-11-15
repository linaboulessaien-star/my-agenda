import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:home_widget/home_widget.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:timezone/timezone.dart' as tz;

// ---------------------------------------------------------------------------
// Options de personnalisation
// ---------------------------------------------------------------------------

const List<Color> kPalette = [
  Color(0xFF6750A4), // violet
  Color(0xFFE91E63), // rose
  Color(0xFFF44336), // rouge
  Color(0xFFFF9800), // orange
  Color(0xFFFFC107), // jaune
  Color(0xFF4CAF50), // vert
  Color(0xFF009688), // turquoise
  Color(0xFF2196F3), // bleu
  Color(0xFF3F51B5), // indigo
  Color(0xFF795548), // marron
  Color(0xFF607D8B), // gris-bleu
  Color(0xFF212121), // noir
];

// Nom affiché -> police système Android (null = police par défaut).
const Map<String, String?> kFonts = {
  'Classique': null,
  'Élégante': 'serif',
  'Machine': 'monospace',
  'Condensée': 'sans-serif-condensed',
  'Manuscrite': 'cursive',
};

// Doit correspondre au nom du paquet Android créé par le workflow GitHub.
const String kWidgetProvider =
    'com.monplanning.mon_planning.PlanningWidgetProvider';

// Délais de rappel proposés (en minutes avant la tâche).
const List<int> kReminderChoices = [0, 5, 10, 30, 60];

String reminderLabel(int m) {
  if (m == 0) return "À l'heure";
  if (m == 60) return '1 h avant';
  return '$m min avant';
}

// ---------------------------------------------------------------------------
// Modèle de données
// ---------------------------------------------------------------------------

String dateKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

enum Repeat { none, daily, weekdays, weekly, monthly }

const Map<Repeat, String> kRepeatLabels = {
  Repeat.none: 'Jamais',
  Repeat.daily: 'Chaque jour',
  Repeat.weekdays: 'Lun-Ven',
  Repeat.weekly: 'Chaque semaine',
  Repeat.monthly: 'Chaque mois',
};

class Category {
  Category({required this.id, required this.name, required this.colorIndex});

  final String id;
  final String name;
  final int colorIndex;

  Color get color =>
      kPalette[colorIndex.clamp(0, kPalette.length - 1).toInt()];

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'color': colorIndex};

  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id'] as String,
        name: j['name'] as String,
        colorIndex: (j['color'] as int?) ?? 0,
      );
}

List<Category> defaultCategories() => [
      Category(id: 'cat-ecole', name: 'École', colorIndex: 7),
      Category(id: 'cat-loisirs', name: 'Loisirs', colorIndex: 1),
      Category(id: 'cat-sport', name: 'Sport', colorIndex: 5),
      Category(id: 'cat-important', name: 'Important', colorIndex: 2),
    ];

class Task {
  Task({
    required this.id,
    required this.title,
    required this.date,
    this.time,
    this.repeat = Repeat.none,
    this.categoryId,
    Set<String>? doneDates,
    Set<String>? skipDates,
  })  : doneDates = doneDates ?? <String>{},
        skipDates = skipDates ?? <String>{};

  final String id;
  final String title;
  final DateTime date; // premier jour
  final String? time; // "HH:mm"
  final Repeat repeat;
  String? categoryId;
  final Set<String> doneDates; // jours où la tâche est cochée
  final Set<String> skipDates; // jours supprimés d'une série

  bool isDone(DateTime day) => doneDates.contains(dateKey(day));

  bool occursOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final start = DateTime(date.year, date.month, date.day);
    if (d.isBefore(start)) return false;
    if (skipDates.contains(dateKey(d))) return false;
    switch (repeat) {
      case Repeat.none:
        return dateKey(d) == dateKey(start);
      case Repeat.daily:
        return true;
      case Repeat.weekdays:
        return d.weekday <= DateTime.friday;
      case Repeat.weekly:
        return d.weekday == start.weekday;
      case Repeat.monthly:
        return d.day == start.day;
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'date': dateKey(date),
        'time': time,
        'repeat': repeat.name,
        'cat': categoryId,
        'done': doneDates.toList(),
        'skip': skipDates.toList(),
      };

  factory Task.fromJson(Map<String, dynamic> j) {
    final doneRaw = j['done'];
    final done = <String>{};
    if (doneRaw is List) {
      done.addAll(doneRaw.map((e) => e.toString()));
    } else if (doneRaw == true) {
      // Ancien format (version 1) : une simple case cochée.
      done.add(j['date'] as String);
    }
    final skipRaw = j['skip'];
    final skip = <String>{};
    if (skipRaw is List) skip.addAll(skipRaw.map((e) => e.toString()));
    return Task(
      id: j['id'] as String,
      title: j['title'] as String,
      date: DateTime.parse(j['date'] as String),
      time: j['time'] as String?,
      repeat: Repeat.values.firstWhere(
        (r) => r.name == j['repeat'],
        orElse: () => Repeat.none,
      ),
      categoryId: j['cat'] as String?,
      doneDates: done,
      skipDates: skip,
    );
  }
}

// ---------------------------------------------------------------------------
// Stockage (sur le téléphone, rien n'est envoyé en ligne)
// ---------------------------------------------------------------------------

class TaskStore extends ChangeNotifier {
  final List<Task> tasks = [];
  final List<Category> categories = [];
  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();

    final raw = _p.getString('tasks');
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        tasks
          ..clear()
          ..addAll(list.map((e) => Task.fromJson(e as Map<String, dynamic>)));
      } catch (_) {
        // Données illisibles : on repart de zéro plutôt que de planter.
      }
    }

    var loaded = false;
    final rawCats = _p.getString('categories');
    if (rawCats != null) {
      try {
        final list = jsonDecode(rawCats) as List<dynamic>;
        categories
          ..clear()
          ..addAll(
            list.map((e) => Category.fromJson(e as Map<String, dynamic>)),
          );
        loaded = true;
      } catch (_) {}
    }
    if (!loaded) {
      categories
        ..clear()
        ..addAll(defaultCategories());
    }
  }

  Category? categoryOf(Task t) {
    final id = t.categoryId;
    if (id == null) return null;
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<Task> forDay(DateTime d) {
    final list = tasks.where((t) => t.occursOn(d)).toList();
    list.sort((a, b) {
      final da = a.isDone(d);
      final db = b.isDone(d);
      if (da != db) return da ? 1 : -1;
      return (a.time ?? '99:99').compareTo(b.time ?? '99:99');
    });
    return list;
  }

  Future<void> _persist() async {
    notifyListeners();
    await _p.setString(
      'tasks',
      jsonEncode(tasks.map((t) => t.toJson()).toList()),
    );
    await _p.setString(
      'categories',
      jsonEncode(categories.map((c) => c.toJson()).toList()),
    );
  }

  Future<void> upsert(Task t) async {
    final i = tasks.indexWhere((x) => x.id == t.id);
    if (i >= 0) {
      tasks[i] = t;
    } else {
      tasks.add(t);
    }
    await _persist();
  }

  Future<void> toggle(Task t, DateTime day) async {
    final k = dateKey(day);
    if (!t.doneDates.remove(k)) t.doneDates.add(k);
    await _persist();
  }

  Future<void> remove(Task t) async {
    tasks.removeWhere((x) => x.id == t.id);
    await _persist();
  }

  Future<void> skip(Task t, DateTime day) async {
    t.skipDates.add(dateKey(day));
    await _persist();
  }

  Future<void> unskip(Task t, DateTime day) async {
    t.skipDates.remove(dateKey(day));
    await _persist();
  }

  Future<void> upsertCategory(Category c) async {
    final i = categories.indexWhere((x) => x.id == c.id);
    if (i >= 0) {
      categories[i] = c;
    } else {
      categories.add(c);
    }
    await _persist();
  }

  Future<void> removeCategory(Category c) async {
    categories.removeWhere((x) => x.id == c.id);
    for (final t in tasks) {
      if (t.categoryId == c.id) t.categoryId = null;
    }
    await _persist();
  }
}

// ---------------------------------------------------------------------------
// Réglages d'apparence et de rappels
// ---------------------------------------------------------------------------

class AppSettings extends ChangeNotifier {
  int colorIndex = 0;
  int fontIndex = 0;
  ThemeMode mode = ThemeMode.system;
  double radius = 16;
  double overlay = 0.55; // opacité du voile posé sur l'image de fond
  String? backgroundPath;
  bool notificationsEnabled = true;
  int reminderMinutes = 0;

  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    colorIndex =
        (_p.getInt('colorIndex') ?? 0).clamp(0, kPalette.length - 1).toInt();
    fontIndex =
        (_p.getInt('fontIndex') ?? 0).clamp(0, kFonts.length - 1).toInt();
    mode = ThemeMode.values[(_p.getInt('mode') ?? 0).clamp(0, 2).toInt()];
    radius = _p.getDouble('radius') ?? 16;
    overlay = _p.getDouble('overlay') ?? 0.55;
    notificationsEnabled = _p.getBool('notifs') ?? true;
    reminderMinutes = _p.getInt('reminderMin') ?? 0;
    final bg = _p.getString('bg');
    if (bg != null && File(bg).existsSync()) backgroundPath = bg;
  }

  void setColor(int i) {
    colorIndex = i;
    _p.setInt('colorIndex', i);
    notifyListeners();
  }

  void setFont(int i) {
    fontIndex = i;
    _p.setInt('fontIndex', i);
    notifyListeners();
  }

  void setMode(ThemeMode m) {
    mode = m;
    _p.setInt('mode', m.index);
    notifyListeners();
  }

  void setRadius(double v) {
    radius = v;
    _p.setDouble('radius', v);
    notifyListeners();
  }

  void setOverlay(double v) {
    overlay = v;
    _p.setDouble('overlay', v);
    notifyListeners();
  }

  void setNotifications(bool v) {
    notificationsEnabled = v;
    _p.setBool('notifs', v);
    notifyListeners();
  }

  void setReminderMinutes(int m) {
    reminderMinutes = m;
    _p.setInt('reminderMin', m);
    notifyListeners();
  }

  Future<void> pickBackground() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 85,
    );
    if (picked == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final dest =
        '${dir.path}/fond_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await File(picked.path).copy(dest);
    final old = backgroundPath;
    backgroundPath = dest;
    await _p.setString('bg', dest);
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> clearBackground() async {
    final old = backgroundPath;
    backgroundPath = null;
    await _p.remove('bg');
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// Rappels (notifications) et widget d'écran d'accueil
// ---------------------------------------------------------------------------

class Integrations {
  Integrations(this.settings, this.store);

  final AppSettings settings;
  final TaskStore store;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Timer? _debounce;

  Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('ic_notification'),
        ),
      );
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      _ready = true;
    } catch (e) {
      debugPrint('Notifications indisponibles : $e');
    }
    await syncNow();
  }

  // Regroupe plusieurs changements rapprochés en une seule mise à jour.
  void syncSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), syncNow);
  }

  Future<void> syncNow() async {
    if (!Platform.isAndroid) return;
    await _syncWidget();
    await _syncNotifications();
  }

  String _hex(Color c) {
    int ch(double v) => (v * 255).round().clamp(0, 255).toInt();
    final v = (ch(c.r) << 16) | (ch(c.g) << 8) | ch(c.b);
    return '#${v.toRadixString(16).padLeft(6, '0')}';
  }

  Future<void> _syncWidget() async {
    try {
      final now = DateTime.now();
      final items = <Map<String, dynamic>>[];
      for (var i = 0; i < 14; i++) {
        final day = DateTime(now.year, now.month, now.day + i);
        for (final t in store.forDay(day)) {
          items.add({
            'd': dateKey(day),
            't': t.time ?? '',
            'n': t.title,
            'x': t.isDone(day),
          });
        }
      }
      final Brightness b = settings.mode == ThemeMode.dark
          ? Brightness.dark
          : settings.mode == ThemeMode.light
              ? Brightness.light
              : WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final scheme = ColorScheme.fromSeed(
        seedColor: kPalette[settings.colorIndex],
        brightness: b,
      );
      await HomeWidget.saveWidgetData<String>('widget_json', jsonEncode(items));
      await HomeWidget.saveWidgetData<String>(
        'widget_bg',
        _hex(scheme.primaryContainer),
      );
      await HomeWidget.saveWidgetData<String>(
        'widget_fg',
        _hex(scheme.onPrimaryContainer),
      );
      await HomeWidget.updateWidget(qualifiedAndroidName: kWidgetProvider);
    } catch (e) {
      debugPrint('Widget non mis à jour : $e');
    }
  }

  Future<void> _syncNotifications() async {
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
      if (!settings.notificationsEnabled) return;

      final now = DateTime.now();
      final perTask = <String, int>{};
      var id = 0;
      for (var i = 0; i < 30 && id < 150; i++) {
        final day = DateTime(now.year, now.month, now.day + i);
        for (final t in store.forDay(day)) {
          if (id >= 150) break;
          final time = t.time;
          if (time == null || t.isDone(day)) continue;
          if ((perTask[t.id] ?? 0) >= 14) continue;
          final parts = time.split(':');
          final when = DateTime(
            day.year,
            day.month,
            day.day,
            int.parse(parts[0]),
            int.parse(parts[1]),
          ).subtract(Duration(minutes: settings.reminderMinutes));
          if (!when.isAfter(now)) continue;
          perTask[t.id] = (perTask[t.id] ?? 0) + 1;
          await _schedule(id++, t, when);
        }
      }
    } catch (e) {
      debugPrint('Rappels non programmés : $e');
    }
  }

  Future<void> _schedule(int id, Task t, DateTime when) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'rappels',
        'Rappels',
        channelDescription: 'Rappels de tes tâches',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    final body = settings.reminderMinutes == 0
        ? "C'est l'heure !"
        : 'À ${t.time} (${reminderLabel(settings.reminderMinutes).toLowerCase()})';
    // Instant absolu : pas besoin de connaître le fuseau horaire du téléphone.
    final at = tz.TZDateTime.from(when, tz.UTC);

    Future<void> go(AndroidScheduleMode mode) => _plugin.zonedSchedule(
          id,
          t.title,
          body,
          at,
          details,
          androidScheduleMode: mode,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
        );

    try {
      await go(AndroidScheduleMode.exactAllowWhileIdle);
    } catch (_) {
      // Alarme exacte refusée : on utilise l'horaire approximatif.
      await go(AndroidScheduleMode.inexactAllowWhileIdle);
    }
  }
}

// ---------------------------------------------------------------------------
// Application
// ---------------------------------------------------------------------------

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');
  final settings = AppSettings();
  final store = TaskStore();
  await settings.load();
  await store.load();
  final integrations = Integrations(settings, store);
  settings.addListener(integrations.syncSoon);
  store.addListener(integrations.syncSoon);
  runApp(
    PlanningApp(
      settings: settings,
      store: store,
      integrations: integrations,
    ),
  );
  // Après l'affichage : la demande d'autorisation ne bloque pas l'écran.
  unawaited(integrations.init());
}

class PlanningApp extends StatelessWidget {
  const PlanningApp({
    super.key,
    required this.settings,
    required this.store,
    required this.integrations,
  });

  final AppSettings settings;
  final TaskStore store;
  final Integrations integrations;

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: kPalette[settings.colorIndex],
      brightness: brightness,
    );
    final radius = BorderRadius.circular(settings.radius);
    final shape = RoundedRectangleBorder(borderRadius: radius);
    final hasBg = settings.backgroundPath != null;
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: kFonts.values.elementAt(settings.fontIndex),
      scaffoldBackgroundColor: hasBg ? Colors.transparent : null,
      appBarTheme: AppBarTheme(
        backgroundColor: hasBg ? Colors.transparent : null,
        scrolledUnderElevation: 0,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(shape: shape),
      filledButtonTheme:
          FilledButtonThemeData(style: FilledButton.styleFrom(shape: shape)),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: shape),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: radius),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(settings.radius)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'Mon planning',
          debugShowCheckedModeBanner: false,
          locale: const Locale('fr', 'FR'),
          supportedLocales: const [Locale('fr', 'FR'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          themeMode: settings.mode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          builder: (context, child) {
            final bg = settings.backgroundPath;
            if (bg == null) return child!;
            final scheme = Theme.of(context).colorScheme;
            return Stack(
              fit: StackFit.expand,
              children: [
                Image.file(
                  File(bg),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
                ColoredBox(
                  color: scheme.surface
                      .withAlpha((settings.overlay * 255).round()),
                ),
                child!,
              ],
            );
          },
          home: HomeScreen(
            settings: settings,
            store: store,
            integrations: integrations,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Écran principal : calendrier + tâches du jour
// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.settings,
    required this.store,
    required this.integrations,
  });

  final AppSettings settings;
  final TaskStore store;
  final Integrations integrations;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  DateTime _focused = DateTime.now();
  DateTime _selected = DateTime.now();
  CalendarFormat _format = CalendarFormat.month;
  String? _filter; // id de catégorie, ou null = toutes

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Au retour dans l'app (ex. lendemain) : widget et rappels à jour.
    if (state == AppLifecycleState.resumed) widget.integrations.syncSoon();
  }

  Future<void> _editTask(Task? existing) async {
    final result = await showModalBottomSheet<Task>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TaskForm(
        task: existing,
        initialDate: _selected,
        categories: List<Category>.of(widget.store.categories),
      ),
    );
    if (result != null) await widget.store.upsert(result);
  }

  String _capitalized(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  void _snack(String text, VoidCallback undo) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          action: SnackBarAction(label: 'Annuler', onPressed: undo),
        ),
      );
  }

  Future<void> _askDeleteRepeating(Task t) async {
    final day = _selected;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tâche répétitive'),
        content: Text(
          'Supprimer « ${t.title} » seulement le '
          '${DateFormat('d MMMM', 'fr_FR').format(day)} '
          'ou toute la série ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'one'),
            child: const Text('Ce jour'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'all'),
            child: const Text('Toute la série'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'one') {
      await widget.store.skip(t, day);
      if (!mounted) return;
      _snack('Supprimée pour ce jour', () => widget.store.unskip(t, day));
    } else if (choice == 'all') {
      await widget.store.remove(t);
      if (!mounted) return;
      _snack('Série supprimée', () => widget.store.upsert(t));
    }
  }

  Widget _tile(Task t, ColorScheme scheme, double radius, bool hasBg) {
    final borderRadius = BorderRadius.circular(radius);
    final cat = widget.store.categoryOf(t);
    final done = t.isDone(_selected);
    final details = <String>[
      if (t.time != null) t.time!,
      if (cat != null) cat.name,
      if (t.repeat != Repeat.none) kRepeatLabels[t.repeat]!,
    ].join(' · ');

    return Dismissible(
      key: ValueKey('${t.id}-${dateKey(_selected)}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: borderRadius,
        ),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      confirmDismiss: (_) async {
        if (t.repeat == Repeat.none) return true;
        await _askDeleteRepeating(t);
        return false;
      },
      onDismissed: (_) {
        widget.store.remove(t);
        _snack('Tâche supprimée', () => widget.store.upsert(t));
      },
      child: ClipRRect(
        borderRadius: borderRadius,
        child: Material(
          color: scheme.surfaceContainerHighest.withAlpha(hasBg ? 210 : 255),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 6, color: cat?.color ?? Colors.transparent),
                Expanded(
                  child: ListTile(
                    leading: Checkbox(
                      value: done,
                      onChanged: (_) => widget.store.toggle(t, _selected),
                    ),
                    title: Text(
                      t.title,
                      style: TextStyle(
                        decoration: done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    subtitle: details.isEmpty ? null : Text(details),
                    trailing: t.repeat == Repeat.none
                        ? null
                        : const Icon(Icons.repeat, size: 18),
                    onTap: () => _editTask(t),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _filters() {
    final cats = widget.store.categories;
    if (cats.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('Toutes'),
              selected: _filter == null,
              onSelected: (_) => setState(() => _filter = null),
            ),
          ),
          for (final c in cats)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: CircleAvatar(backgroundColor: c.color, radius: 6),
                label: Text(c.name),
                selected: _filter == c.id,
                onSelected: (_) =>
                    setState(() => _filter = _filter == c.id ? null : c.id),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = widget.settings.radius;
    final hasBg = widget.settings.backgroundPath != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mon planning'),
        actions: [
          IconButton(
            tooltip: "Aujourd'hui",
            icon: const Icon(Icons.today),
            onPressed: () => setState(() {
              _focused = DateTime.now();
              _selected = DateTime.now();
            }),
          ),
          IconButton(
            tooltip: 'Personnaliser',
            icon: const Icon(Icons.palette_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(
                  settings: widget.settings,
                  store: widget.store,
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editTask(null),
        icon: const Icon(Icons.add),
        label: const Text('Tâche'),
      ),
      body: ListenableBuilder(
        listenable: widget.store,
        builder: (context, _) {
          final filter =
              widget.store.categories.any((c) => c.id == _filter)
                  ? _filter
                  : null;
          final tasks = widget.store
              .forDay(_selected)
              .where((t) => filter == null || t.categoryId == filter)
              .toList();
          final doneCount = tasks.where((t) => t.isDone(_selected)).length;
          return Column(
            children: [
              TableCalendar<Task>(
                locale: 'fr_FR',
                firstDay: DateTime.utc(2020, 1, 1),
                lastDay: DateTime.utc(2100, 12, 31),
                focusedDay: _focused,
                calendarFormat: _format,
                startingDayOfWeek: StartingDayOfWeek.monday,
                availableCalendarFormats: const {
                  CalendarFormat.month: 'Mois',
                  CalendarFormat.twoWeeks: '2 sem.',
                  CalendarFormat.week: 'Semaine',
                },
                selectedDayPredicate: (d) => isSameDay(d, _selected),
                eventLoader: (d) => widget.store.forDay(d),
                onDaySelected: (selected, focused) => setState(() {
                  _selected = selected;
                  _focused = focused;
                }),
                onFormatChanged: (f) => setState(() => _format = f),
                onPageChanged: (focused) => _focused = focused,
                headerStyle: const HeaderStyle(
                  titleCentered: true,
                  formatButtonShowsNext: false,
                ),
                calendarStyle: CalendarStyle(
                  selectedDecoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                  selectedTextStyle: TextStyle(color: scheme.onPrimary),
                  todayDecoration: BoxDecoration(
                    color: scheme.primary.withAlpha(90),
                    shape: BoxShape.circle,
                  ),
                  todayTextStyle: TextStyle(color: scheme.onSurface),
                ),
                calendarBuilders: CalendarBuilders<Task>(
                  markerBuilder: (context, day, events) {
                    if (events.isEmpty) return null;
                    final colors = events
                        .map((t) =>
                            widget.store.categoryOf(t)?.color ??
                            scheme.tertiary)
                        .toSet()
                        .take(3)
                        .toList();
                    return Positioned(
                      bottom: 4,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final c in colors)
                            Container(
                              width: 6,
                              height: 6,
                              margin:
                                  const EdgeInsets.symmetric(horizontal: 1),
                              decoration: BoxDecoration(
                                color: c,
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              _filters(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _capitalized(
                          DateFormat('EEEE d MMMM', 'fr_FR').format(_selected),
                        ),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (tasks.isNotEmpty) Text('$doneCount/${tasks.length}'),
                  ],
                ),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? const Center(child: Text('Rien de prévu ce jour-là.'))
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                        itemCount: tasks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) =>
                            _tile(tasks[i], scheme, radius, hasBg),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Formulaire d'ajout / modification d'une tâche
// ---------------------------------------------------------------------------

class TaskForm extends StatefulWidget {
  const TaskForm({
    super.key,
    this.task,
    required this.initialDate,
    required this.categories,
  });

  final Task? task;
  final DateTime initialDate;
  final List<Category> categories;

  @override
  State<TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<TaskForm> {
  late final TextEditingController _title;
  late DateTime _date;
  TimeOfDay? _time;
  String? _cat;
  Repeat _repeat = Repeat.none;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _title = TextEditingController(text: t?.title ?? '');
    _date = t?.date ?? widget.initialDate;
    _repeat = t?.repeat ?? Repeat.none;
    final cat = t?.categoryId;
    _cat = widget.categories.any((c) => c.id == cat) ? cat : null;
    final time = t?.time;
    if (time != null) {
      final parts = time.split(':');
      _time = TimeOfDay(
        hour: int.parse(parts[0]),
        minute: int.parse(parts[1]),
      );
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  String? _timeString() {
    final t = _time;
    if (t == null) return null;
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: _time ?? TimeOfDay.now(),
    );
    if (t != null) setState(() => _time = t);
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final newDate = DateTime(_date.year, _date.month, _date.day);
    final old = widget.task;
    Set<String>? done = old?.doneDates;
    if (old != null && old.repeat == Repeat.none && _repeat == Repeat.none) {
      // Tâche simple déplacée : elle garde son état coché.
      done = old.doneDates.isEmpty ? <String>{} : {dateKey(newDate)};
    }
    Navigator.of(context).pop(
      Task(
        id: old?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        title: title,
        date: newDate,
        time: _timeString(),
        repeat: _repeat,
        categoryId: _cat,
        doneDates: done,
        skipDates: old?.skipDates,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = Theme.of(context).textTheme.labelLarge;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _title,
            autofocus: widget.task == null,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Que veux-tu planifier ?',
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.event),
                  label: Text(DateFormat('EEE d MMM', 'fr_FR').format(_date)),
                  onPressed: _pickDate,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.schedule),
                  label: Text(_timeString() ?? 'Heure'),
                  onPressed: _pickTime,
                ),
              ),
            ],
          ),
          if (_time != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _time = null),
                child: const Text("Retirer l'heure"),
              ),
            ),
          if (widget.categories.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Catégorie', style: label),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: const Text('Aucune'),
                  selected: _cat == null,
                  onSelected: (_) => setState(() => _cat = null),
                ),
                for (final c in widget.categories)
                  ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: c.color, radius: 6),
                    label: Text(c.name),
                    selected: _cat == c.id,
                    onSelected: (_) => setState(() => _cat = c.id),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text('Répéter', style: label),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final r in Repeat.values)
                ChoiceChip(
                  label: Text(kRepeatLabels[r]!),
                  selected: _repeat == r,
                  onSelected: (_) => setState(() => _repeat = r),
                ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Enregistrer')),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Écran de personnalisation
// ---------------------------------------------------------------------------

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.settings, required this.store});

  final AppSettings settings;
  final TaskStore store;

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      );

  Future<void> _editCategory(BuildContext context, Category? c) async {
    final nameCtl = TextEditingController(text: c?.name ?? '');
    var colorIndex = c?.colorIndex ?? 0;
    final result = await showDialog<Category>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(c == null ? 'Nouvelle catégorie' : 'Modifier'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Nom'),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < kPalette.length; i++)
                    GestureDetector(
                      onTap: () => setS(() => colorIndex = i),
                      child: CircleAvatar(
                        radius: 16,
                        backgroundColor: kPalette[i],
                        child: colorIndex == i
                            ? const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                final n = nameCtl.text.trim();
                if (n.isEmpty) return;
                Navigator.pop(
                  ctx,
                  Category(
                    id: c?.id ??
                        DateTime.now().microsecondsSinceEpoch.toString(),
                    name: n,
                    colorIndex: colorIndex,
                  ),
                );
              },
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await store.upsertCategory(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Personnaliser')),
      body: ListenableBuilder(
        listenable: Listenable.merge([settings, store]),
        builder: (context, _) {
          final bg = settings.backgroundPath;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              _section(context, 'Couleur principale'),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (var i = 0; i < kPalette.length; i++)
                    GestureDetector(
                      onTap: () => settings.setColor(i),
                      child: CircleAvatar(
                        radius: 20,
                        backgroundColor: kPalette[i],
                        child: settings.colorIndex == i
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                      ),
                    ),
                ],
              ),
              _section(context, 'Thème'),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('Auto')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Clair')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Sombre')),
                ],
                selected: {settings.mode},
                onSelectionChanged: (s) => settings.setMode(s.first),
              ),
              _section(context, 'Police'),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < kFonts.length; i++)
                    ChoiceChip(
                      label: Text(
                        kFonts.keys.elementAt(i),
                        style: TextStyle(fontFamily: kFonts.values.elementAt(i)),
                      ),
                      selected: settings.fontIndex == i,
                      onSelected: (_) => settings.setFont(i),
                    ),
                ],
              ),
              _section(context, 'Arrondi des formes'),
              Slider(
                value: settings.radius,
                min: 0,
                max: 32,
                divisions: 8,
                label: settings.radius.round().toString(),
                onChanged: settings.setRadius,
              ),
              _section(context, 'Catégories'),
              for (final c in store.categories)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(radius: 12, backgroundColor: c.color),
                  title: Text(c.name),
                  onTap: () => _editCategory(context, c),
                  trailing: IconButton(
                    tooltip: 'Supprimer',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => store.removeCategory(c),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _editCategory(context, null),
                  icon: const Icon(Icons.add),
                  label: const Text('Ajouter une catégorie'),
                ),
              ),
              _section(context, 'Rappels'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Notifications'),
                subtitle: const Text('Pour les tâches qui ont une heure'),
                value: settings.notificationsEnabled,
                onChanged: settings.setNotifications,
              ),
              if (settings.notificationsEnabled)
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final m in kReminderChoices)
                      ChoiceChip(
                        label: Text(reminderLabel(m)),
                        selected: settings.reminderMinutes == m,
                        onSelected: (_) => settings.setReminderMinutes(m),
                      ),
                  ],
                ),
              _section(context, "Widget d'écran d'accueil"),
              const Text(
                "Appuie longuement sur un espace vide de ton écran d'accueil, "
                'choisis « Widgets », puis « Mon Planning » et glisse-le où tu '
                'veux. Il prend les couleurs choisies ici.',
              ),
              _section(context, 'Image de fond'),
              if (bg != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(settings.radius),
                    child: Image.file(
                      File(bg),
                      height: 140,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: settings.pickBackground,
                    icon: const Icon(Icons.image_outlined),
                    label: Text(bg == null ? 'Choisir une image' : 'Changer'),
                  ),
                  const SizedBox(width: 8),
                  if (bg != null)
                    TextButton(
                      onPressed: settings.clearBackground,
                      child: const Text('Retirer'),
                    ),
                ],
              ),
              if (bg != null) ...[
                _section(context, "Voile sur l'image"),
                Slider(
                  value: settings.overlay,
                  min: 0.2,
                  max: 0.9,
                  onChanged: settings.setOverlay,
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
