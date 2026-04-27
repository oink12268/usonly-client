#import "KeychainFix.h"
#import <Security/Security.h>
#import <Foundation/Foundation.h>
#import "fishhook.h"

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef _Nullable * _Nullable);
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef _Nullable * _Nullable);
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);

// --- Fake keychain backed by UserDefaults ---

static NSString* fkItemKey(CFDictionaryRef dict) {
    NSDictionary *d = (__bridge NSDictionary *)dict;
    NSString *svc = d[(__bridge id)kSecAttrService] ?: @"";
    NSString *acc = d[(__bridge id)kSecAttrAccount] ?: @"";
    return [NSString stringWithFormat:@"__fkc__%@__%@", svc, acc];
}

static NSMutableDictionary* fkStore(void) {
    static NSMutableDictionary *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"__fkc_store__"];
        store = saved ? [saved mutableCopy] : [NSMutableDictionary new];
    });
    return store;
}

static void fkSave(void) {
    [[NSUserDefaults standardUserDefaults] setObject:fkStore() forKey:@"__fkc_store__"];
}

// --- Hooks ---

static OSStatus hook_Add(CFDictionaryRef attrs, CFTypeRef _Nullable * _Nullable result) {
    NSDictionary *d = (__bridge NSDictionary *)attrs;
    NSData *value = d[(__bridge id)kSecValueData];
    NSString *key = fkItemKey(attrs);

    // Always mirror to fake store for reliable cross-launch persistence
    if (value) {
        if (fkStore()[key]) {
            NSLog(@"[KeychainFix] fakeAdd duplicate: %@", key);
        } else {
            fkStore()[key] = value;
            fkSave();
            NSLog(@"[KeychainFix] fakeAdd mirrored: %@", key);
        }
    }

    OSStatus s = orig_SecItemAdd(attrs, result);
    NSLog(@"[KeychainFix] realAdd key=%@ status=%d", key, (int)s);
    if (s == errSecSuccess) return s;
    if (value && fkStore()[key]) return errSecSuccess;
    return s;
}

static OSStatus hook_CopyMatching(CFDictionaryRef query, CFTypeRef _Nullable * _Nullable result) {
    // Check fake store first to ensure consistency with hook_Add saves
    NSString *key = fkItemKey(query);
    NSData *value = fkStore()[key];
    if (value) {
        if (result) {
            NSDictionary *q = (__bridge NSDictionary *)query;
            BOOL wantData  = [q[(__bridge id)kSecReturnData] boolValue];
            BOOL wantAttrs = [q[(__bridge id)kSecReturnAttributes] boolValue];
            if (wantAttrs) {
                NSMutableDictionary *a = [NSMutableDictionary dictionary];
                if (wantData) a[(__bridge id)kSecValueData] = value;
                if (q[(__bridge id)kSecAttrService]) a[(__bridge id)kSecAttrService] = q[(__bridge id)kSecAttrService];
                if (q[(__bridge id)kSecAttrAccount]) a[(__bridge id)kSecAttrAccount] = q[(__bridge id)kSecAttrAccount];
                *result = (__bridge_retained CFTypeRef)a;
            } else {
                *result = (__bridge_retained CFTypeRef)value;
            }
        }
        NSLog(@"[KeychainFix] fakeGet OK: %@", key);
        return errSecSuccess;
    }

    OSStatus s = orig_SecItemCopyMatching(query, result);
    NSLog(@"[KeychainFix] realGet key=%@ status=%d", key, (int)s);
    return s;
}

static OSStatus hook_Update(CFDictionaryRef query, CFDictionaryRef attrsToUpdate) {
    NSString *key = fkItemKey(query);
    NSData *newValue = ((__bridge NSDictionary *)attrsToUpdate)[(__bridge id)kSecValueData];

    // Always mirror update to fake store
    if (newValue) {
        fkStore()[key] = newValue;
        fkSave();
        NSLog(@"[KeychainFix] fakeUpdate mirrored: %@", key);
    }

    OSStatus s = orig_SecItemUpdate(query, attrsToUpdate);
    NSLog(@"[KeychainFix] realUpdate key=%@ status=%d", key, (int)s);
    return errSecSuccess;
}

static OSStatus hook_Delete(CFDictionaryRef query) {
    OSStatus s = orig_SecItemDelete(query);
    if (s == errSecSuccess) return s;

    NSString *key = fkItemKey(query);
    if (!fkStore()[key]) return errSecItemNotFound;
    [fkStore() removeObjectForKey:key];
    fkSave();
    NSLog(@"[KeychainFix] fakeDelete OK: %@", key);
    return errSecSuccess;
}

@implementation KeychainFix

+ (void)load {
    struct rebinding bindings[] = {
        {"SecItemAdd", hook_Add, (void **)&orig_SecItemAdd},
        {"SecItemCopyMatching", hook_CopyMatching, (void **)&orig_SecItemCopyMatching},
        {"SecItemUpdate", hook_Update, (void **)&orig_SecItemUpdate},
        {"SecItemDelete", hook_Delete, (void **)&orig_SecItemDelete},
    };
    int r = rebind_symbols(bindings, 4);
    NSLog(@"[KeychainFix] Installed fake-keychain hooks (result=%d)", r);
}

@end
