#ifndef APRICOT_H
#define APRICOT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define APRICOT_ABI_MAJOR 1u
#define APRICOT_ABI_MINOR 1u

typedef struct apricot_context apricot_context;
typedef struct apricot_operation apricot_operation;
typedef struct apricot_collaboration apricot_collaboration;

typedef struct {
    const uint8_t *ptr;
    size_t len;
} apricot_bytes;

typedef void (*apricot_release_fn)(void *user_data, const uint8_t *ptr, size_t len);

typedef struct {
    apricot_bytes bytes;
    apricot_release_fn release;
    void *user_data;
} apricot_owned_bytes;

typedef struct {
    apricot_bytes method;
    apricot_bytes url;
    apricot_bytes headers;
    apricot_bytes body;
} apricot_http_request;

typedef struct {
    uint16_t status_code;
    uint16_t reserved;
    apricot_owned_bytes headers;
    apricot_owned_bytes body;
} apricot_http_response;

typedef uint32_t (*apricot_http_fn)(void *user_data, const apricot_http_request *request, apricot_http_response *response);
typedef uint32_t (*apricot_credentials_fn)(void *user_data, apricot_bytes scope, apricot_owned_bytes *credentials);
typedef void (*apricot_progress_fn)(void *user_data, uint32_t operation_kind, apricot_bytes phase, uint64_t completed, uint64_t total);
typedef uint8_t (*apricot_cancel_fn)(void *user_data);
typedef void (*apricot_log_fn)(void *user_data, uint32_t level, apricot_bytes message);

typedef struct {
    apricot_bytes provider;
    apricot_bytes value;
} apricot_opaque_id;

typedef struct {
    apricot_owned_bytes provider;
    apricot_owned_bytes value;
} apricot_owned_opaque_id;

typedef struct {
    uint8_t create;
    uint8_t get;
    uint8_t update;
    uint8_t delete_resource;
    uint8_t list;
    uint8_t reserved[3];
} apricot_collaboration_operations;

typedef struct {
    uint32_t resource_kind;
    apricot_collaboration_operations operations;
} apricot_collaboration_capability;

typedef void (*apricot_capabilities_release_fn)(void *user_data, const apricot_collaboration_capability *ptr, size_t len);

typedef struct {
    const apricot_collaboration_capability *ptr;
    size_t len;
    apricot_capabilities_release_fn release;
    void *user_data;
} apricot_owned_capabilities;

typedef struct {
    uint32_t struct_size;
    uint32_t contract_version;
    uint32_t operation;
    uint32_t resource_kind;
    apricot_bytes repository_vcs;
    apricot_bytes repository;
    apricot_opaque_id id;
    apricot_bytes cursor;
    uint32_t limit;
    uint32_t flags;
    apricot_bytes content_type;
    apricot_bytes payload;
    apricot_bytes extensions;
} apricot_collaboration_request;

typedef struct {
    uint32_t struct_size;
    uint32_t response_kind;
    uint32_t resource_kind;
    uint32_t failure_code;
    apricot_owned_opaque_id id;
    apricot_owned_bytes version;
    apricot_owned_bytes content_type;
    apricot_owned_bytes payload;
    apricot_owned_bytes extensions;
    apricot_owned_bytes next_cursor;
    uint64_t total;
    uint64_t retry_after_seconds;
    uint8_t has_total;
    uint8_t has_retry_after;
    uint8_t retryable;
    uint8_t pagination;
    uint8_t conditional_updates;
    uint8_t idempotent_creates;
    uint8_t federation;
    uint8_t reserved;
    apricot_owned_bytes provider;
    apricot_owned_bytes protocol_family;
    apricot_owned_capabilities capabilities;
    apricot_owned_bytes error_message;
    apricot_owned_bytes provider_code;
} apricot_collaboration_callback_response;

typedef struct {
    uint32_t response_kind;
    uint32_t resource_kind;
    uint32_t failure_code;
    apricot_opaque_id id;
    apricot_bytes version;
    apricot_bytes content_type;
    apricot_bytes payload;
    apricot_bytes extensions;
    apricot_bytes next_cursor;
    uint64_t total;
    uint64_t retry_after_seconds;
    uint8_t has_total;
    uint8_t has_retry_after;
    uint8_t retryable;
    uint8_t pagination;
    uint8_t conditional_updates;
    uint8_t idempotent_creates;
    uint8_t federation;
    uint8_t reserved;
    apricot_bytes provider;
    apricot_bytes protocol_family;
    const apricot_collaboration_capability *capabilities;
    size_t capabilities_len;
    apricot_bytes error_message;
    apricot_bytes provider_code;
} apricot_collaboration_response;

typedef uint32_t (*apricot_collaboration_fn)(void *user_data, const apricot_collaboration_request *request, apricot_collaboration_callback_response *response);

typedef struct {
    uint32_t struct_size;
    uint32_t abi_major;
    uint32_t abi_minor;
    uint32_t flags;
    void *user_data;
    apricot_http_fn http;
    apricot_credentials_fn credentials;
    apricot_progress_fn progress;
    apricot_cancel_fn cancel;
    apricot_log_fn log;
    apricot_collaboration_fn collaboration;
} apricot_context_options;

enum {
    APRICOT_STATUS_OK = 0,
    APRICOT_STATUS_INVALID_ARGUMENT = 1,
    APRICOT_STATUS_INCOMPATIBLE_ABI = 2,
    APRICOT_STATUS_OUT_OF_MEMORY = 3,
    APRICOT_STATUS_CANCELLED = 4,
    APRICOT_STATUS_UNSUPPORTED = 5,
    APRICOT_STATUS_CORRUPT_DATA = 6,
    APRICOT_STATUS_CALLBACK_FAILED = 7,
    APRICOT_STATUS_INVALID_STATE = 8,
    APRICOT_STATUS_INTERNAL = 9
};

enum {
    APRICOT_COLLABORATION_DISCOVER = 0,
    APRICOT_COLLABORATION_CREATE = 1,
    APRICOT_COLLABORATION_GET = 2,
    APRICOT_COLLABORATION_UPDATE = 3,
    APRICOT_COLLABORATION_DELETE = 4,
    APRICOT_COLLABORATION_LIST = 5
};

enum {
    APRICOT_RESOURCE_ISSUE = 1,
    APRICOT_RESOURCE_CHANGE_REQUEST = 2,
    APRICOT_RESOURCE_REVIEW = 3,
    APRICOT_RESOURCE_COMMENT = 4,
    APRICOT_RESOURCE_FORK = 5,
    APRICOT_RESOURCE_CHECK = 6,
    APRICOT_RESOURCE_RELEASE = 7,
    APRICOT_RESOURCE_LABEL = 8,
    APRICOT_RESOURCE_MILESTONE = 9
};

enum {
    APRICOT_SUPPORT_UNSUPPORTED = 0,
    APRICOT_SUPPORT_NATIVE = 1,
    APRICOT_SUPPORT_EMULATED = 2
};

enum {
    APRICOT_COLLABORATION_RESPONSE_DISCOVERY = 1,
    APRICOT_COLLABORATION_RESPONSE_ITEM = 2,
    APRICOT_COLLABORATION_RESPONSE_PAGE = 3,
    APRICOT_COLLABORATION_RESPONSE_DELETED = 4,
    APRICOT_COLLABORATION_RESPONSE_FAILURE = 5
};

enum {
    APRICOT_FAILURE_UNAUTHENTICATED = 1,
    APRICOT_FAILURE_FORBIDDEN = 2,
    APRICOT_FAILURE_NOT_FOUND = 3,
    APRICOT_FAILURE_CONFLICT = 4,
    APRICOT_FAILURE_VALIDATION = 5,
    APRICOT_FAILURE_RATE_LIMITED = 6,
    APRICOT_FAILURE_UNSUPPORTED = 7,
    APRICOT_FAILURE_UNAVAILABLE = 8,
    APRICOT_FAILURE_CANCELLED = 9,
    APRICOT_FAILURE_PROVIDER = 10
};

enum {
    APRICOT_OPERATION_PUBLISH = 1,
    APRICOT_OPERATION_FETCH = 2,
    APRICOT_OPERATION_VERIFY = 3,
    APRICOT_OPERATION_CUSTOM = 255
};

enum {
    APRICOT_OPERATION_PENDING = 0,
    APRICOT_OPERATION_RUNNING = 1,
    APRICOT_OPERATION_COMPLETED = 2,
    APRICOT_OPERATION_FAILED = 3,
    APRICOT_OPERATION_CANCELLED = 4
};

enum {
    APRICOT_LOG_ERROR = 1,
    APRICOT_LOG_WARN = 2,
    APRICOT_LOG_INFO = 3,
    APRICOT_LOG_DEBUG = 4
};

uint32_t apricot_abi_version(void);
uint32_t apricot_abi_negotiate(uint32_t requested_major, uint32_t minimum_minor, uint32_t *negotiated_minor);
uint32_t apricot_context_create(const apricot_context_options *options, apricot_context **context);
void apricot_context_free(apricot_context *context);
uint32_t apricot_operation_create(apricot_context *context, uint32_t kind, apricot_bytes request, apricot_operation **operation);
void apricot_operation_free(apricot_operation *operation);
uint32_t apricot_operation_start(apricot_operation *operation);
uint32_t apricot_operation_complete(apricot_operation *operation, apricot_bytes result);
uint32_t apricot_operation_fail(apricot_operation *operation, uint32_t status, apricot_bytes message);
uint32_t apricot_operation_state(const apricot_operation *operation);
uint32_t apricot_operation_status(const apricot_operation *operation);
apricot_bytes apricot_operation_request(const apricot_operation *operation);
apricot_bytes apricot_operation_result(const apricot_operation *operation);
apricot_bytes apricot_operation_error(const apricot_operation *operation);
uint8_t apricot_operation_is_cancelled(apricot_operation *operation);
uint32_t apricot_operation_http(apricot_operation *operation, const apricot_http_request *request, apricot_http_response *response);
uint32_t apricot_operation_credentials(apricot_operation *operation, apricot_bytes scope, apricot_owned_bytes *credentials);
uint32_t apricot_operation_progress(apricot_operation *operation, apricot_bytes phase, uint64_t completed, uint64_t total);
uint32_t apricot_operation_log(apricot_operation *operation, uint32_t level, apricot_bytes message);
uint32_t apricot_verify_carrier(apricot_context *context, apricot_bytes expected_root, apricot_bytes carrier, apricot_operation **operation);
void apricot_owned_bytes_release(apricot_owned_bytes *bytes);
uint32_t apricot_collaboration_create(apricot_context *context, const apricot_collaboration_request *request, apricot_collaboration **collaboration);
uint32_t apricot_collaboration_execute(apricot_collaboration *collaboration);
uint32_t apricot_collaboration_state(const apricot_collaboration *collaboration);
uint32_t apricot_collaboration_status(const apricot_collaboration *collaboration);
const apricot_collaboration_response *apricot_collaboration_response_get(const apricot_collaboration *collaboration);
void apricot_collaboration_free(apricot_collaboration *collaboration);

#ifdef __cplusplus
}
#endif

#endif
