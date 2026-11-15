#pragma once
#include <stdint.h>
#include <stdbool.h>
int32_t MacToolboxSetKeychainInteractionAllowed(bool allowed);
int32_t MacToolboxKeychainInteractionAllowed(void);
