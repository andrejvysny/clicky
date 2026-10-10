#include "CSandbox.h"
#include <sandbox.h>
#include <stdlib.h>

// sandbox_init is deprecated but is the only public API for named profiles; it is what App Sandbox-less tools use.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int clicky_deny_network(char **error) {
    return sandbox_init(kSBXProfileNoNetwork, SANDBOX_NAMED, error) == 0 ? 0 : -1;
}
#pragma clang diagnostic pop

void clicky_sandbox_free_error(char *error) {
    if (error != NULL) sandbox_free_error(error);
}
