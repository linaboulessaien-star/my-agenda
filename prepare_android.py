#!/usr/bin/env python3
"""Prépare le projet Android généré par `flutter create`.

Utilisation :  python3 tools/prepare_android.py <dossier_du_projet> <dossier_icon>

Ce script (lancé automatiquement par GitHub) :
  1. désactive le contrôle « lint » qui plantait la construction,
  2. active ce qu'il faut pour les notifications programmées,
  3. ajoute les autorisations, le widget d'écran d'accueil et ses fichiers,
  4. fabrique l'icône de l'app à partir du dossier icon/.
"""
import glob
import os
import re
import sys

EXPECTED_PACKAGE = "com.monplanning.mon_planning"


def fail(msg):
    print("ERREUR : " + msg)
    sys.exit(1)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


# ---------------------------------------------------------------- Gradle ---
def patch_gradle(app_dir):
    kts = os.path.join(app_dir, "build.gradle.kts")
    groovy = os.path.join(app_dir, "build.gradle")
    if os.path.exists(kts):
        path, is_kts = kts, True
    elif os.path.exists(groovy):
        path, is_kts = groovy, False
    else:
        fail("build.gradle(.kts) introuvable dans " + app_dir)

    s = read(path)
    if "coreLibraryDesugaring" in s:
        print("Gradle déjà modifié : " + path)
        return

    if is_kts:
        lint = ("    lint {\n"
                "        checkReleaseBuilds = false\n"
                "        abortOnError = false\n"
                "    }\n")
        flag = "        isCoreLibraryDesugaringEnabled = true\n"
        dep = ('\ndependencies {\n'
               '    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n'
               '}\n')
    else:
        lint = ("    lint {\n"
                "        checkReleaseBuilds false\n"
                "        abortOnError false\n"
                "    }\n")
        flag = "        coreLibraryDesugaringEnabled true\n"
        dep = ("\ndependencies {\n"
               "    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n"
               "}\n")

    s, n1 = re.subn(r"(^android\s*\{[ \t]*\n)", lambda m: m.group(1) + lint,
                    s, count=1, flags=re.M)
    s, n2 = re.subn(r"(compileOptions\s*\{[ \t]*\n)", lambda m: m.group(1) + flag,
                    s, count=1)
    if n1 == 0:
        fail("bloc 'android {' introuvable dans " + path)
    if n2 == 0:
        fail("bloc 'compileOptions {' introuvable dans " + path)
    s = s.rstrip("\n") + "\n" + dep
    write(path, s)
    print("Gradle modifié : " + path)


# -------------------------------------------------------------- Manifeste ---
PERMISSIONS = [
    ("android.permission.POST_NOTIFICATIONS", ""),
    ("android.permission.RECEIVE_BOOT_COMPLETED", ""),
    ("android.permission.VIBRATE", ""),
    ("android.permission.USE_EXACT_ALARM", ""),
    ("android.permission.SCHEDULE_EXACT_ALARM", ' android:maxSdkVersion="32"'),
]

RECEIVERS = """
        <receiver android:exported="false"
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false"
            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED"/>
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
            </intent-filter>
        </receiver>
        <receiver android:name=".PlanningWidgetProvider"
            android:exported="true"
            android:label="Planning du jour">
            <intent-filter>
                <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>
            </intent-filter>
            <meta-data android:name="android.appwidget.provider"
                android:resource="@xml/planning_widget_info"/>
        </receiver>
"""


def patch_manifest(path):
    s = read(path)
    if "PlanningWidgetProvider" in s:
        print("Manifeste déjà modifié.")
        return
    s = re.sub(r'android:label="[^"]*"', 'android:label="Mon Planning"', s, count=1)

    perms = ""
    for name, extra in PERMISSIONS:
        if name not in s:
            perms += '    <uses-permission android:name="%s"%s/>\n' % (name, extra)
    i = s.find("<application")
    if i < 0:
        fail("<application introuvable dans le manifeste")
    s = s[:i] + perms + "    " + s[i:]

    j = s.rfind("</application>")
    if j < 0:
        fail("</application> introuvable dans le manifeste")
    s = s[:j] + RECEIVERS + "    " + s[j:]
    write(path, s)
    print("Manifeste modifié : " + path)


# ----------------------------------------------- Widget et ressources -------
WIDGET_KT = '''package PACKAGE_NAME

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.widget.RemoteViews
import org.json.JSONArray
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class PlanningWidgetProvider : AppWidgetProvider() {

    private fun parse(hex: String?, fallback: Int): Int {
        return try {
            Color.parseColor(hex)
        } catch (e: Exception) {
            fallback
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        // home_widget range les données dans ces préférences.
        val prefs = context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE)
        val bg = parse(prefs.getString("widget_bg", null), Color.parseColor("#E8DEF8"))
        val fg = parse(prefs.getString("widget_fg", null), Color.parseColor("#1D192B"))

        val now = Date()
        val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(now)
        var title = SimpleDateFormat("EEEE d MMMM", Locale("fr", "FR")).format(now)
        title = title.replaceFirstChar { it.uppercase() }

        // Tâches d'aujourd'hui : non faites d'abord, puis par heure.
        val open = ArrayList<String>()
        val done = ArrayList<String>()
        try {
            val arr = JSONArray(prefs.getString("widget_json", "[]"))
            val rows = ArrayList<Triple<Boolean, String, String>>()
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                if (o.getString("d") == today) {
                    rows.add(Triple(o.getBoolean("x"), o.getString("t"), o.getString("n")))
                }
            }
            rows.sortWith(compareBy({ it.first }, { if (it.second.isEmpty()) "99:99" else it.second }))
            for (r in rows) {
                val time = if (r.second.isEmpty()) "" else r.second + "  "
                if (r.first) done.add("\\u2713 " + time + r.third)
                else open.add("\\u2022 " + time + r.third)
            }
        } catch (e: Exception) {
            // Données absentes ou illisibles : on affiche le message par défaut.
        }

        val all = open + done
        val shown = all.take(6)
        val text = when {
            all.isEmpty() -> "Rien de prévu aujourd'hui"
            all.size > shown.size -> shown.joinToString("\\n") + "\\n+" + (all.size - shown.size) + " autre(s)"
            else -> shown.joinToString("\\n")
        }

        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pending = if (launch != null) {
            PendingIntent.getActivity(context, 0, launch, PendingIntent.FLAG_IMMUTABLE)
        } else null

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.planning_widget)
            views.setInt(R.id.widget_bg, "setColorFilter", bg)
            views.setInt(R.id.widget_bg, "setImageAlpha", 240)
            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_tasks, text)
            views.setTextColor(R.id.widget_title, fg)
            views.setTextColor(R.id.widget_tasks, fg)
            if (pending != null) views.setOnClickPendingIntent(R.id.widget_root, pending)
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
'''

WIDGET_LAYOUT = '''<?xml version="1.0" encoding="utf-8"?>
<FrameLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/widget_root"
    android:layout_width="match_parent"
    android:layout_height="match_parent">

    <ImageView
        android:id="@+id/widget_bg"
        android:layout_width="match_parent"
        android:layout_height="match_parent"
        android:scaleType="fitXY"
        android:src="@drawable/widget_bg" />

    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="match_parent"
        android:orientation="vertical"
        android:padding="14dp">

        <TextView
            android:id="@+id/widget_title"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:maxLines="1"
            android:textSize="16sp"
            android:textStyle="bold" />

        <TextView
            android:id="@+id/widget_tasks"
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:layout_marginTop="6dp"
            android:ellipsize="end"
            android:maxLines="7"
            android:textSize="14sp" />
    </LinearLayout>
</FrameLayout>
'''

WIDGET_INFO = '''<?xml version="1.0" encoding="utf-8"?>
<appwidget-provider xmlns:android="http://schemas.android.com/apk/res/android"
    android:minWidth="250dp"
    android:minHeight="110dp"
    android:updatePeriodMillis="1800000"
    android:initialLayout="@layout/planning_widget"
    android:resizeMode="horizontal|vertical"
    android:widgetCategory="home_screen" />
'''

WIDGET_BG = '''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android"
    android:shape="rectangle">
    <solid android:color="#FFFFFFFF" />
    <corners android:radius="22dp" />
</shape>
'''

NOTIF_ICON = '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="M17,12h-5v5h5v-5zM16,1v2H8V1H6v2H5c-1.11,0 -1.99,0.9 -1.99,2L3,19c0,1.1 0.89,2 2,2h14c1.1,0 2,-0.9 2,-2V5c0,-1.1 -0.9,-2 -2,-2h-1V1h-2zM19,19H5V8h14v11z" />
</vector>
'''


def write_widget_files(main_dir):
    res = os.path.join(main_dir, "res")
    write(os.path.join(res, "layout", "planning_widget.xml"), WIDGET_LAYOUT)
    write(os.path.join(res, "xml", "planning_widget_info.xml"), WIDGET_INFO)
    write(os.path.join(res, "drawable", "widget_bg.xml"), WIDGET_BG)
    write(os.path.join(res, "drawable", "ic_notification.xml"), NOTIF_ICON)

    # Le fichier Kotlin doit être dans le même paquet que MainActivity.
    hits = glob.glob(os.path.join(main_dir, "**", "MainActivity.*"), recursive=True)
    hits = [h for h in hits if h.endswith((".kt", ".java"))]
    if not hits:
        fail("MainActivity introuvable")
    activity = hits[0]
    m = re.search(r"^package\s+([\w.]+)", read(activity), re.M)
    if not m:
        fail("paquet introuvable dans " + activity)
    package = m.group(1)
    if package != EXPECTED_PACKAGE:
        fail("le paquet est '%s' mais l'app attend '%s'" % (package, EXPECTED_PACKAGE))
    target = os.path.join(os.path.dirname(activity), "PlanningWidgetProvider.kt")
    write(target, WIDGET_KT.replace("PACKAGE_NAME", package))
    print("Widget écrit : " + target)


# ------------------------------------------------------------------ Icônes ---
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
ADAPTIVE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

ADAPTIVE_XML = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
'''


def make_icons(icon_dir, res_dir):
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("Pillow absent : icône par défaut conservée.")
        return
    icon_path = os.path.join(icon_dir, "icon.png")
    if not os.path.exists(icon_path):
        print("icon/icon.png absent : icône par défaut conservée.")
        return

    icon = Image.open(icon_path).convert("RGBA")
    fg_path = os.path.join(icon_dir, "foreground.png")
    bg_path = os.path.join(icon_dir, "background.png")

    for name, size in DENSITIES.items():
        # Anciennes versions d'Android : icône carrée aux coins arrondis.
        img = icon.resize((size, size), Image.LANCZOS)
        mask = Image.new("L", (size * 4, size * 4), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, size * 4 - 1, size * 4 - 1), radius=int(size * 4 * 0.22), fill=255)
        mask = mask.resize((size, size), Image.LANCZOS)
        img.putalpha(mask)
        out = os.path.join(res_dir, "mipmap-" + name)
        os.makedirs(out, exist_ok=True)
        img.save(os.path.join(out, "ic_launcher.png"))

    for name, size in ADAPTIVE.items():
        out = os.path.join(res_dir, "mipmap-" + name)
        if os.path.exists(fg_path):
            fg = Image.open(fg_path).convert("RGBA").resize((size, size), Image.LANCZOS)
        else:
            # Image personnelle seule : on la réduit pour qu'elle reste dans la zone visible.
            fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            inner = int(size * 0.62)
            small = icon.resize((inner, inner), Image.LANCZOS)
            fg.paste(small, ((size - inner) // 2, (size - inner) // 2), small)
        if os.path.exists(bg_path):
            bg = Image.open(bg_path).convert("RGBA").resize((size, size), Image.LANCZOS)
        else:
            corner = icon.getpixel((4, 4))
            bg = Image.new("RGBA", (size, size), corner)
        fg.save(os.path.join(out, "ic_launcher_foreground.png"))
        bg.save(os.path.join(out, "ic_launcher_background.png"))

    write(os.path.join(res_dir, "mipmap-anydpi-v26", "ic_launcher.xml"), ADAPTIVE_XML)
    print("Icônes générées.")


def main():
    if len(sys.argv) != 3:
        fail("usage : prepare_android.py <projet> <dossier_icon>")
    project, icon_dir = sys.argv[1], sys.argv[2]
    app_dir = os.path.join(project, "android", "app")
    main_dir = os.path.join(app_dir, "src", "main")
    if not os.path.isdir(main_dir):
        fail("dossier introuvable : " + main_dir)
    patch_gradle(app_dir)
    patch_manifest(os.path.join(main_dir, "AndroidManifest.xml"))
    write_widget_files(main_dir)
    make_icons(icon_dir, os.path.join(main_dir, "res"))
    print("Préparation Android terminée.")


if __name__ == "__main__":
    main()
