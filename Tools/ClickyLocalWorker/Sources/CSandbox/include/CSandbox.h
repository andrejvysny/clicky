#ifndef CSANDBOX_H
#define CSANDBOX_H

/// Enters the system "no network" sandbox profile for this process. Returns 0 on success; on failure returns -1
/// and sets *error to a malloc'd message the caller must free with clicky_sandbox_free_error.
int clicky_deny_network(char **error);
void clicky_sandbox_free_error(char *error);

#endif
