#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*tryagi_libtorrent_event_callback_t)(const char *json, void *context);

int tryagi_libtorrent_session_create(
    tryagi_libtorrent_event_callback_t callback,
    void *context,
    void **session
);

void tryagi_libtorrent_session_destroy(void *session);
int tryagi_libtorrent_job_start(void *session, const char *json);
int tryagi_libtorrent_job_apply_selection(void *session, const char *json);
int tryagi_libtorrent_job_update_rate_limits(void *session, const char *json);
int tryagi_libtorrent_job_reannounce(void *session, const char *json);
int tryagi_libtorrent_job_refresh_peers(void *session, const char *json);
int tryagi_libtorrent_job_pause(void *session, const char *json);
int tryagi_libtorrent_job_resume(void *session, const char *json);
int tryagi_libtorrent_job_cancel(void *session, const char *json);
const char *tryagi_libtorrent_last_error(void *session);

#ifdef __cplusplus
}
#endif
