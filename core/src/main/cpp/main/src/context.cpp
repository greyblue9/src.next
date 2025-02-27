/*
 * This file is part of LSPosed.
 *
 * LSPosed is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * LSPosed is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with LSPosed.  If not, see <https://www.gnu.org/licenses/>.
 *
 * Copyright (C) 2020 EdXposed Contributors
 * Copyright (C) 2021 LSPosed Contributors
 */

#include <jni.h>
#include "jni_helper.h"
#include "jni/art_class_linker.h"
#include "jni/yahfa.h"
#include "jni/resources_hook.h"
#include <art/runtime/jni_env_ext.h>
#include "jni/pending_hooks.h"
#include "context.h"
#include "native_hook.h"
#include "jni/native_api.h"
#include "service.h"
#include "symbol_cache.h"

namespace lspd {
    extern int *allowUnload;

    constexpr int FIRST_ISOLATED_UID = 99000;
    constexpr int LAST_ISOLATED_UID = 99999;
    constexpr int FIRST_APP_ZYGOTE_ISOLATED_UID = 90000;
    constexpr int LAST_APP_ZYGOTE_ISOLATED_UID = 98999;
    constexpr int SHARED_RELRO_UID = 1037;
    constexpr int PER_USER_RANGE = 100000;

    static constexpr uid_t kAidInjected = INJECTED_AID;
    static constexpr uid_t kAidInet = 3003;

    void Context::CallOnPostFixupStaticTrampolines(void *class_ptr) {
        if (!class_ptr || !class_linker_class_ || !post_fixup_static_mid_) [[unlikely]] {
            return;
        }

        JNIEnv *env;
        vm_->GetEnv((void **) (&env), JNI_VERSION_1_4);
        art::JNIEnvExt env_ext(env);
        ScopedLocalRef clazz(env, env_ext.NewLocalRefer(class_ptr));
        if (clazz) {
            JNI_CallStaticVoidMethod(env, class_linker_class_, post_fixup_static_mid_, clazz.get());
        }
    }

    Context::PreloadedDex::PreloadedDex(int fd, std::size_t size) {
        if (auto addr = mmap(nullptr, size, PROT_READ, MAP_SHARED, fd, 0); addr) {
            addr_ = addr;
            size_ = size;
        } else {
            LOGE("Read dex failed");
        }
    }

    Context::PreloadedDex::~PreloadedDex() {
        if (*this) munmap(addr_, size_);
    }

    void Context::PreLoadDex(int fd, std::size_t size) {
        dex_ = PreloadedDex{fd, size};
    }

    void Context::PreLoadDex(std::string_view dex_path) {
        if (dex_) [[unlikely]] return;

        std::unique_ptr<FILE, decltype(&fclose)> f{fopen(dex_path.data(), "rb"), &fclose};

        if (!f) {
            LOGE("Fail to open dex from %s", dex_path.data());
            return;
        } else {
            fseek(f.get(), 0, SEEK_END);
            auto size = ftell(f.get());
            rewind(f.get());
            PreLoadDex(fileno(f.get()), size);
        }
        LOGD("Loaded %s with size %zu", dex_path.data(), dex_.size());
    }

    void Context::LoadDex(JNIEnv *env) {
        auto classloader = JNI_FindClass(env, "java/lang/ClassLoader");
        auto getsyscl_mid = JNI_GetStaticMethodID(
                env, classloader, "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
        auto sys_classloader = JNI_CallStaticObjectMethod(env, classloader, getsyscl_mid);
        if (!sys_classloader) [[unlikely]] {
            LOGE("getSystemClassLoader failed!!!");
            return;
        }
        auto in_memory_classloader = JNI_FindClass(env, "dalvik/system/InMemoryDexClassLoader");
        auto initMid = JNI_GetMethodID(env, in_memory_classloader, "<init>",
                                       "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V");
        auto byte_buffer_class = JNI_FindClass(env, "java/nio/ByteBuffer");
        auto dex = std::move(dex_);
        auto dex_buffer = env->NewDirectByteBuffer(dex.data(), dex.size());
        if (auto my_cl = JNI_NewObject(env, in_memory_classloader, initMid,
                                       dex_buffer, sys_classloader)) {
            inject_class_loader_ = JNI_NewGlobalRef(env, my_cl);
        } else {
            LOGE("InMemoryDexClassLoader creation failed!!!");
            return;
        }

        env->DeleteLocalRef(dex_buffer);

        env->GetJavaVM(&vm_);
    }

    void Context::Init() {
    }

    void Context::Init(JNIEnv *env) {
        if (auto class_linker_class = FindClassFromCurrentLoader(env, kClassLinkerClassName)) {
            class_linker_class_ = JNI_NewGlobalRef(env, class_linker_class);
        }
        post_fixup_static_mid_ = JNI_GetStaticMethodID(env, class_linker_class_,
                                                       "onPostFixupStaticTrampolines",
                                                       "(Ljava/lang/Class;)V");

        if (auto entry_class = FindClassFromLoader(env, GetCurrentClassLoader(),
                                                   kEntryClassName)) {
            entry_class_ = JNI_NewGlobalRef(env, entry_class);
        }

        RegisterResourcesHook(env);
        RegisterArtClassLinker(env);
        RegisterYahfa(env);
        RegisterPendingHooks(env);
        RegisterNativeAPI(env);
    }

    ScopedLocalRef<jclass>
    Context::FindClassFromLoader(JNIEnv *env, jobject class_loader,
                                 std::string_view class_name) {
        if (class_loader == nullptr) return {env, nullptr};
        static auto clz = JNI_NewGlobalRef(env,
                                           JNI_FindClass(env, "dalvik/system/DexClassLoader"));
        static jmethodID mid = JNI_GetMethodID(env, clz, "loadClass",
                                               "(Ljava/lang/String;)Ljava/lang/Class;");
        if (!mid) {
            mid = JNI_GetMethodID(env, clz, "findClass",
                                  "(Ljava/lang/String;)Ljava/lang/Class;");
        }
        if (mid) [[likely]] {
            auto target = JNI_CallObjectMethod(env, class_loader, mid,
                                               env->NewStringUTF(class_name.data()));
            if (target) {
                return target;
            }
        } else {
            LOGE("No loadClass/findClass method found");
        }
        LOGE("Class %s not found", class_name.data());
        return {env, nullptr};
    }

    template<typename ...Args>
    void
    Context::FindAndCall(JNIEnv *env, std::string_view method_name, std::string_view method_sig,
                         Args &&... args) const {
        if (!entry_class_) [[unlikely]] {
            LOGE("cannot call method %s, entry class is null", method_name.data());
            return;
        }
        jmethodID mid = JNI_GetStaticMethodID(env, entry_class_, method_name, method_sig);
        if (mid) [[likely]] {
            JNI_CallStaticVoidMethod(env, entry_class_, mid, std::forward<Args>(args)...);
        } else {
            LOGE("method %s id is null", method_name.data());
        }
    }

    void
    Context::OnNativeForkSystemServerPre(JNIEnv *env) {
        Service::instance()->InitService(env);
        skip_ = !symbol_cache->initialized.test(std::memory_order_acquire);
        if (skip_) [[unlikely]] {
            LOGW("skip system server due to symbol cache");
        }
        setAllowUnload(skip_);
    }

    void
    Context::OnNativeForkSystemServerPost(JNIEnv *env) {
        if (!skip_) {
            LoadDex(env);
            Service::instance()->HookBridge(*this, env);
            auto binder = Service::instance()->RequestBinderForSystemServer(env);
            if (binder) {
                InstallInlineHooks();
                Init(env);
                FindAndCall(env, "forkSystemServerPost", "(Landroid/os/IBinder;)V", binder);
            } else skip_ = true;
        }
        if (skip_) [[unlikely]] {
            LOGW("skipped system server");
        }
        setAllowUnload(skip_);
    }

    void Context::OnNativeForkAndSpecializePre(JNIEnv *env,
                                               jint uid,
                                               jintArray &gids,
                                               jstring nice_name,
                                               jboolean is_child_zygote,
                                               jstring app_data_dir) {
        if (uid == kAidInjected) {
            int array_size = gids ? env->GetArrayLength(gids) : 0;
            auto region = std::make_unique<jint[]>(array_size + 1);
            auto *new_gids = env->NewIntArray(array_size + 1);
            if (gids) env->GetIntArrayRegion(gids, 0, array_size, region.get());
            region.get()[array_size] = kAidInet;
            env->SetIntArrayRegion(new_gids, 0, array_size + 1, region.get());
            if (gids) env->SetIntArrayRegion(gids, 0, 1, region.get() + array_size);
            gids = new_gids;
        }
        Service::instance()->InitService(env);
        const auto app_id = uid % PER_USER_RANGE;
        JUTFString process_name(env, nice_name);
        skip_ = !symbol_cache->initialized.test(std::memory_order_acquire);
        if (!skip_ && !app_data_dir) {
            LOGD("skip injecting into %s because it has no data dir", process_name.get());
            skip_ = true;
        }
        if (!skip_ && is_child_zygote) {
            skip_ = true;
            LOGD("skip injecting into %s because it's a child zygote", process_name.get());
        }

        if (!skip_ && ((app_id >= FIRST_ISOLATED_UID && app_id <= LAST_ISOLATED_UID) ||
                       (app_id >= FIRST_APP_ZYGOTE_ISOLATED_UID &&
                        app_id <= LAST_APP_ZYGOTE_ISOLATED_UID) ||
                       app_id == SHARED_RELRO_UID)) {
            skip_ = true;
            LOGI("skip injecting into %s because it's isolated", process_name.get());
        }
        setAllowUnload(skip_);
    }

    void
    Context::OnNativeForkAndSpecializePost(JNIEnv *env, jstring nice_name,
                                           jstring app_data_dir) {
        const JUTFString process_name(env, nice_name);
        auto binder = skip_ ? ScopedLocalRef<jobject>{env, nullptr}
                            : Service::instance()->RequestBinder(env, nice_name);
        if (binder) {
            InstallInlineHooks();
            LoadDex(env);
            Init(env);
            LOGD("Done prepare");
            FindAndCall(env, "forkAndSpecializePost",
                        "(Ljava/lang/String;Ljava/lang/String;Landroid/os/IBinder;)V",
                        app_data_dir, nice_name,
                        binder);
            LOGD("injected xposed into %s", process_name.get());
            setAllowUnload(false);
        } else {
            auto context = Context::ReleaseInstance();
            auto service = Service::ReleaseInstance();
            GetArt().reset();
            LOGD("skipped %s", process_name.get());
            setAllowUnload(true);
        }
    }

    void Context::setAllowUnload(bool unload) {
        if (allowUnload) {
            *allowUnload = unload ? 1 : 0;
        }
    }
}  // namespace lspd
