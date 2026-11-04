// sqlite3_db_config is variadic and cannot be invoked directly from Swift.
#include <sqlite3.h>
int sidestore_recovery_disable_close_checkpoint(sqlite3 *database) {
    int enabled = 0;
    int result = sqlite3_db_config(database, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &enabled);
    return result == SQLITE_OK && enabled != 1 ? SQLITE_ERROR : result;
}
