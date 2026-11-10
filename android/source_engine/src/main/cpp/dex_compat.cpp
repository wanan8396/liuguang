#include <jni.h>
#include <android/log.h>
#include <cstdarg>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>

namespace {
struct Scope {
    const JNINativeInterface* original;
    jclass dex_class;
    jmethodID constructor;
    jclass output_class;
    jmethodID output_constructors[4];
    jmethodID file_path;
    std::string data_dir;
    Scope* previous;
};
thread_local Scope* active = nullptr;

// Rewriting an already mapped DEX in place can corrupt ART's mapping. A legacy
// loader must create a new inode on the next run, then make that inode read-only
// before loading it. Never make the old executable mapping writable again.
void prepare_write(JNIEnv* env, jobject path_arg, bool is_file, bool append) {
    if (!path_arg || append) return;
    Scope* scope = active;
    jstring path = is_file ? static_cast<jstring>(scope->original->CallObjectMethod(env, path_arg, scope->file_path)) : static_cast<jstring>(path_arg);
    if (!path || scope->original->ExceptionCheck(env)) return;
    const char* value = scope->original->GetStringUTFChars(env, path, nullptr);
    if (!value) return;
    std::string name(value);
    scope->original->ReleaseStringUTFChars(env, path, value);
    if (is_file) scope->original->DeleteLocalRef(env, path);
    char* canonical = realpath(name.c_str(), nullptr);
    if (!canonical) return;
    std::string resolved(canonical);
    free(canonical);
    const std::string cache = scope->data_dir + "cache/";
    const std::string code_cache = scope->data_dir + "code_cache/";
    if (resolved.compare(0, cache.size(), cache) != 0 && resolved.compare(0, code_cache.size(), code_cache) != 0) return;
    int fd = open(name.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return;
    struct stat info{}, current{};
    char magic[8]{};
    bool dex = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == getuid() &&
        (info.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)) == 0 &&
        read(fd, magic, sizeof(magic)) == sizeof(magic) &&
        memcmp(magic, "dex\n", 4) == 0 && magic[7] == '\0';
    close(fd);
    if (dex && lstat(name.c_str(), &current) == 0 && current.st_ino == info.st_ino && current.st_dev == info.st_dev &&
        unlink(name.c_str()) == 0) {
        __android_log_print(ANDROID_LOG_INFO, "LiuguangDexCompat", "Recreated legacy secondary DEX output");
    }
}

int output_constructor(JNIEnv* env, jclass cls, jmethodID method) {
    if (!active->original->IsSameObject(env, cls, active->output_class)) return -1;
    for (int i = 0; i < 4; i++) if (method == active->output_constructors[i]) return i;
    return -1;
}

// A legacy factory may pass several DEX paths. Only touch regular files owned by
// this app, after canonicalization; other paths retain the platform's checks.
void prepare(JNIEnv* env, jclass cls, jmethodID method, jstring paths) {
    Scope* scope = active;
    if (!scope || method != scope->constructor || !paths ||
        !scope->original->IsSameObject(env, cls, scope->dex_class)) return;
    const char* value = scope->original->GetStringUTFChars(env, paths, nullptr);
    if (!value) return;
    std::string list(value);
    scope->original->ReleaseStringUTFChars(env, paths, value);
    size_t start = 0;
    do {
        size_t end = list.find(':', start);
        std::string path = list.substr(start, end == std::string::npos ? end : end - start);
        char* canonical = realpath(path.c_str(), nullptr);
        if (canonical) {
            std::string resolved(canonical);
            free(canonical);
            struct stat info{};
            if (resolved.compare(0, scope->data_dir.size(), scope->data_dir) == 0 &&
                stat(resolved.c_str(), &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == getuid() &&
                (info.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)) != 0) {
                if (chmod(resolved.c_str(), info.st_mode & ~(S_IWUSR | S_IWGRP | S_IWOTH)) == 0) {
                    __android_log_print(ANDROID_LOG_INFO, "LiuguangDexCompat", "Prepared read-only secondary DEX");
                }
            }
        }
        if (end == std::string::npos) break;
        start = end + 1;
    } while (start < list.size());
}

jobject new_object_v(JNIEnv* env, jclass cls, jmethodID method, va_list args) {
    va_list copy;
    va_copy(copy, args);
    if (active && method == active->constructor) prepare(env, cls, method, va_arg(copy, jstring));
    else if (active) {
        int type = output_constructor(env, cls, method);
        if (type >= 0) {
            jobject path = va_arg(copy, jobject);
            bool append = type % 2 == 1 && va_arg(copy, jint) != 0;
            prepare_write(env, path, type >= 2, append);
        }
    }
    va_end(copy);
    return active->original->NewObjectV(env, cls, method, args);
}

jobject new_object(JNIEnv* env, jclass cls, jmethodID method, ...) {
    va_list args;
    va_start(args, method);
    jobject result = new_object_v(env, cls, method, args);
    va_end(args);
    return result;
}

jobject new_object_a(JNIEnv* env, jclass cls, jmethodID method, const jvalue* args) {
    if (active && args && method == active->constructor) prepare(env, cls, method, static_cast<jstring>(args[0].l));
    else if (active && args) {
        int type = output_constructor(env, cls, method);
        if (type >= 0) prepare_write(env, args[0].l, type >= 2, type % 2 == 1 && args[1].z);
    }
    return active->original->NewObjectA(env, cls, method, args);
}
} // namespace

extern "C" JNIEXPORT void JNICALL
Java_cn_liuguang_engine_NativeDexCompat_runScoped(JNIEnv* env, jclass, jstring data_dir, jobject action) {
    // JNIEnv is thread-local. The table override lasts only for this synchronous
    // call, and delegates every operation except the DEX constructor unchanged.
    // No ART offsets, instruction patches, global JNI table edits or root access.
    if (active) {
        jclass cls = env->GetObjectClass(action);
        jmethodID run = env->GetMethodID(cls, "run", "()V");
        if (run) env->CallVoidMethod(action, run);
        env->DeleteLocalRef(cls);
        return;
    }
    jclass dex = env->FindClass("dalvik/system/DexClassLoader");
    if (!dex) return;
    jmethodID constructor = env->GetMethodID(dex, "<init>", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V");
    jclass runnable = env->FindClass("java/lang/Runnable");
    if (!constructor || !runnable) return;
    jclass output = env->FindClass("java/io/FileOutputStream");
    jclass file = env->FindClass("java/io/File");
    if (!output || !file) return;
    jmethodID writers[4] = {
        env->GetMethodID(output, "<init>", "(Ljava/lang/String;)V"),
        env->GetMethodID(output, "<init>", "(Ljava/lang/String;Z)V"),
        env->GetMethodID(output, "<init>", "(Ljava/io/File;)V"),
        env->GetMethodID(output, "<init>", "(Ljava/io/File;Z)V"),
    };
    jmethodID file_path = env->GetMethodID(file, "getPath", "()Ljava/lang/String;");
    if (env->ExceptionCheck()) return;
    jmethodID run = env->GetMethodID(runnable, "run", "()V");
    const char* dir = env->GetStringUTFChars(data_dir, nullptr);
    if (!run || !dir) return;
    char* canonical = realpath(dir, nullptr);
    std::string root(canonical ? canonical : dir);
    free(canonical);
    env->ReleaseStringUTFChars(data_dir, dir);
    root += '/';
    Scope scope{env->functions, dex, constructor, output, {writers[0], writers[1], writers[2], writers[3]}, file_path, root, active};
    JNINativeInterface replacement = *env->functions;
    replacement.NewObject = new_object;
    replacement.NewObjectV = new_object_v;
    replacement.NewObjectA = new_object_a;
    active = &scope;
    env->functions = &replacement;
    scope.original->CallVoidMethod(env, action, run);
    env->functions = scope.original;
    active = scope.previous;
    env->DeleteLocalRef(runnable);
    env->DeleteLocalRef(dex);
    env->DeleteLocalRef(output);
    env->DeleteLocalRef(file);
}
