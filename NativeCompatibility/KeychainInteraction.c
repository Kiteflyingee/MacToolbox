#include "MacToolboxKeychainCompatibility.h"
#include <Security/Security.h>

// Existing credentials use the macOS legacy keychain. Its SecItem path does
// not honor LAContext.interactionNotAllowed. Keep this deprecated SDK bridge
// isolated; it controls optional UI in this process, never grants key access.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int32_t MacToolboxSetKeychainInteractionAllowed(bool allowed) {
    return SecKeychainSetUserInteractionAllowed(allowed);
}
int32_t MacToolboxKeychainInteractionAllowed(void) {
    Boolean allowed = false;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&allowed);
    return status == errSecSuccess ? (allowed ? 1 : 0) : -1;
}
#pragma clang diagnostic pop
