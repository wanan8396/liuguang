-keep class com.github.catvod.** { *; }
-keep class com.fongmi.quickjs.** { *; }
# Downloaded DEX plugins link against these host APIs by their original names.
# R8 cannot see those external references while shrinking the application.
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class com.google.gson.** { *; }
-keep class org.jsoup.** { *; }
-keep class kotlin.** { *; }
-keep class com.orhanobut.logger.** { *; }
-keepclasseswithmembernames,includedescriptorclasses class * { native <methods>; }
-keepattributes Signature,*Annotation*,InnerClasses,EnclosingMethod
# Release builds do not emit host debug logs; preserve exception handling.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
    public static int w(...);
    public static int e(...);
}
-dontwarn com.dylibso.**
# Optional desktop TLS providers are not installed; Android uses its system TLS.
-dontwarn org.bouncycastle.jsse.BCSSLParameters
-dontwarn org.bouncycastle.jsse.BCSSLSocket
-dontwarn org.bouncycastle.jsse.provider.BouncyCastleJsseProvider
-dontwarn org.conscrypt.Conscrypt$Version
-dontwarn org.conscrypt.Conscrypt
-dontwarn org.conscrypt.ConscryptHostnameVerifier
-dontwarn org.openjsse.javax.net.ssl.SSLParameters
-dontwarn org.openjsse.javax.net.ssl.SSLSocket
-dontwarn org.openjsse.net.ssl.OpenJSSE
