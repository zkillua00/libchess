#ifndef LIBCHESS_H
#define LIBCHESS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LIBCHESS_API_VERSION 1u

typedef struct libchess_client libchess_client_t;

/*
 * `event_json` is borrowed and remains valid only for the duration of the
 * callback. Copy it before returning. Callbacks arrive on the libchess worker
 * thread. `context` must remain valid until libchess_client_destroy returns.
 */
typedef void (*libchess_event_callback_t)(
    void *context,
    const uint8_t *event_json,
    size_t event_json_length
);

enum libchess_send_result {
    LIBCHESS_SEND_OK = 0,
    LIBCHESS_SEND_NULL_CLIENT = 1,
    LIBCHESS_SEND_NULL_BYTES = 2,
    LIBCHESS_SEND_INVALID_JSON = 3,
    LIBCHESS_SEND_UNSUPPORTED_VERSION = 4,
    LIBCHESS_SEND_WORKER_CLOSED = 5,
    LIBCHESS_SEND_PANIC = 6
};

uint32_t libchess_api_version(void);

libchess_client_t *libchess_client_create(
    libchess_event_callback_t callback,
    void *context
);

/*
 * Commands use a UTF-8 JSON envelope with `version: 1`, an optional
 * `request_id`, and one of these payloads:
 *
 * {"type":"begin_oauth","provider":"lichess","client_id":"...","redirect_uri":"..."}
 * {"type":"complete_oauth","callback_url":"..."}
 * {"type":"cancel_oauth"}
 * {"type":"list_providers"}
 * {"type":"connect","provider":"lichess","access_token":"..."}
 * {"type":"refresh_account"}
 * {"type":"disconnect"}
 */
int32_t libchess_client_send(
    libchess_client_t *client,
    const uint8_t *command_json,
    size_t command_json_length
);

/*
 * Waits for the worker to stop. Do not call this function from an event
 * callback or concurrently with libchess_client_send.
 */
void libchess_client_destroy(libchess_client_t *client);

#ifdef __cplusplus
}
#endif

#endif
