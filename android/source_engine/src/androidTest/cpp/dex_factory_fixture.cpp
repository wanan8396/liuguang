#include <jni.h>
#include <cstdarg>

static jobject create_v(JNIEnv* env, jclass cls, jmethodID constructor, ...) {
    va_list args;
    va_start(args, constructor);
    jobject result = env->NewObjectV(cls, constructor, args);
    va_end(args);
    return result;
}

extern "C" JNIEXPORT void JNICALL
Java_cn_liuguang_engine_NativeDexCompatTest_rewrite(JNIEnv* env, jobject, jstring path, jbyteArray bytes, jint type, jint mode) {
    jclass file = env->FindClass("java/io/File");
    jclass output = env->FindClass("java/io/FileOutputStream");
    jmethodID file_init = env->GetMethodID(file, "<init>", "(Ljava/lang/String;)V");
    jobject arg = type >= 2 ? env->NewObject(file, file_init, path) : path;
    const char* signatures[] = {"(Ljava/lang/String;)V", "(Ljava/lang/String;Z)V", "(Ljava/io/File;)V", "(Ljava/io/File;Z)V"};
    jmethodID init = env->GetMethodID(output, "<init>", signatures[type]);
    jobject writer;
    if (mode == 0) writer = env->NewObject(output, init, arg, JNI_FALSE);
    else if (mode == 1) writer = create_v(env, output, init, arg, JNI_FALSE);
    else {
        jvalue args[2]{};
        args[0].l = arg;
        writer = env->NewObjectA(output, init, args);
    }
    if (env->ExceptionCheck()) return;
    jmethodID write = env->GetMethodID(output, "write", "([B)V");
    jmethodID close = env->GetMethodID(output, "close", "()V");
    env->CallVoidMethod(writer, write, bytes);
    if (env->ExceptionCheck()) return;
    env->CallVoidMethod(writer, close);
}

extern "C" JNIEXPORT jobject JNICALL
Java_cn_liuguang_engine_NativeDexCompatTest_create(JNIEnv* env, jobject, jstring path, jstring folder, jobject parent, jint mode) {
    jclass cls = env->FindClass("dalvik/system/DexClassLoader");
    if (!cls) return nullptr;
    jmethodID constructor = env->GetMethodID(cls, "<init>", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V");
    if (!constructor) return nullptr;
    jobject result;
    if (mode == 0) result = env->NewObject(cls, constructor, path, folder, nullptr, parent);
    else if (mode == 1) result = create_v(env, cls, constructor, path, folder, nullptr, parent);
    else {
        jvalue args[4]{};
        args[0].l = path; args[1].l = folder; args[3].l = parent;
        result = env->NewObjectA(cls, constructor, args);
    }
    env->DeleteLocalRef(cls);
    return result;
}
