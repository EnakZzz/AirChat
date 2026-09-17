# AirChat release rules.
#
# The protocol core is plain Kotlin/JVM with no reflection, so nothing needs to be kept for it.
# Room and Compose ship their own consumer rules.

# Keep the Room database implementation generated at compile time (it is referenced by name
# from the generated schema and by Room's runtime lookup).
-keep class com.airchat.data.** { *; }
-keepclassmembers class com.airchat.data.** { *; }

# Kotlin coroutines internals used by the generated code.
-dontwarn kotlinx.coroutines.**
