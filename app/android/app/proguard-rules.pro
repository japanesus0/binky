# Flutter wrapper — keep all Flutter engine classes.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# flutter_local_notifications uses reflection for the notification responder.
-keep class com.dexterous.** { *; }

# flutter_local_notifications stores scheduled notifications on disk via
# Gson, which reflects on generic types via TypeToken<T>. R8 strips
# generic signatures by default; without these rules, every schedule /
# cancel call after the first one throws:
#   PlatformException(... TypeToken must be created with a type
#   argument: new TypeToken<...>() {}; ...)
# and the OS-side completion notification never fires.
-keepattributes Signature
-keepattributes *Annotation*
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken
# Bonus defensive rules from Gson's official ProGuard config — covers any
# other Gson-style reflective serialization we might pull in via plugins:
-keep class * extends com.google.gson.TypeAdapter
-keep class * extends com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepclassmembers,allowobfuscation class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# Keep Enums (general Dart/Kotlin code-gen often serializes these reflectively).
-keep class * extends java.lang.Enum {
    <fields>;
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Plugin GeneratedPluginRegistrant — never reachable from user code, so R8
# can prune it incorrectly without help.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# Suppress noisy warnings from plugins that ship unused desugared classes.
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
