/*
 * Unit tests for tokenreview_api.c using CMocka
 *
 * Uses linker --wrap to intercept curl and file I/O calls.
 */

#include <stdarg.h>
#include <stddef.h>
#include <setjmp.h>
#include <cmocka.h>
#include <string.h>
#include <stdlib.h>
#include <curl/curl.h>

#include "tokenreview_api.h"

/* ========================================================================
 * Wrap state: captures curl options set by production code
 * ======================================================================== */

static size_t (*captured_write_fn)(void*, size_t, size_t, void*) = NULL;
static void *captured_write_data = NULL;
static const char *mock_response_json = NULL;
static long mock_http_code = 200;

/* ========================================================================
 * __wrap_ functions for curl
 * ======================================================================== */

CURL *__wrap_curl_easy_init(void) {
    return (CURL *)mock();
}

void __wrap_curl_easy_cleanup(CURL *curl) {
    (void)curl;
}

CURLcode __wrap_curl_easy_setopt(CURL *curl, CURLoption option, ...) {
    (void)curl;
    va_list ap;
    va_start(ap, option);

    if (option == CURLOPT_WRITEFUNCTION) {
        captured_write_fn = va_arg(ap, void*);
    } else if (option == CURLOPT_WRITEDATA) {
        captured_write_data = va_arg(ap, void*);
    }

    va_end(ap);
    return CURLE_OK;
}

CURLcode __wrap_curl_easy_perform(CURL *curl) {
    (void)curl;
    CURLcode ret = (CURLcode)mock();

    /* If perform succeeds, feed mock JSON into the write callback */
    if (ret == CURLE_OK && mock_response_json && captured_write_fn && captured_write_data) {
        size_t len = strlen(mock_response_json);
        captured_write_fn((void*)mock_response_json, 1, len, captured_write_data);
    }

    return ret;
}

CURLcode __wrap_curl_easy_getinfo(CURL *curl, CURLINFO info, ...) {
    (void)curl;
    va_list ap;
    va_start(ap, info);

    if (info == CURLINFO_RESPONSE_CODE) {
        long *code_ptr = va_arg(ap, long*);
        *code_ptr = mock_http_code;
    }

    va_end(ap);
    return CURLE_OK;
}

const char *__wrap_curl_easy_strerror(CURLcode code) {
    (void)code;
    return "mock curl error";
}

struct curl_slist *__wrap_curl_slist_append(struct curl_slist *list, const char *string) {
    (void)string;
    /* Return a non-NULL sentinel so production code continues */
    return list ? list : (struct curl_slist *)0x1;
}

void __wrap_curl_slist_free_all(struct curl_slist *list) {
    (void)list;
}

/* ========================================================================
 * __wrap_ functions for file I/O (used by read_file in tokenreview_api.c)
 * ======================================================================== */

static const char *mock_file_content = NULL;
static size_t mock_file_size = 0;
static size_t mock_file_pos = 0;

FILE *__wrap_fopen(const char *path, const char *mode) {
    (void)path;
    (void)mode;
    FILE *ret = (FILE *)mock();
    if (ret) {
        mock_file_pos = 0;
    }
    return ret;
}

int __wrap_fclose(FILE *fp) {
    (void)fp;
    return 0;
}

int __wrap_fseek(FILE *fp, long offset, int whence) {
    (void)fp;
    if (whence == SEEK_END) {
        mock_file_pos = mock_file_size;
    } else if (whence == SEEK_SET) {
        mock_file_pos = (size_t)offset;
    }
    return 0;
}

long __wrap_ftell(FILE *fp) {
    (void)fp;
    return (long)mock_file_pos;
}

size_t __wrap_fread(void *ptr, size_t size, size_t nmemb, FILE *fp) {
    (void)fp;
    if (!mock_file_content) return 0;
    size_t total = size * nmemb;
    size_t avail = mock_file_size - mock_file_pos;
    size_t to_read = total < avail ? total : avail;
    memcpy(ptr, mock_file_content + mock_file_pos, to_read);
    mock_file_pos += to_read;
    return to_read;
}

/* ========================================================================
 * Helper: set up file mock to return content
 * ======================================================================== */

static void setup_mock_file(const char *content) {
    mock_file_content = content;
    mock_file_size = content ? strlen(content) : 0;
    mock_file_pos = 0;
}

/* ========================================================================
 * Helper: reset all mock state between tests
 * ======================================================================== */

static int test_setup(void **state) {
    (void)state;
    captured_write_fn = NULL;
    captured_write_data = NULL;
    mock_response_json = NULL;
    mock_http_code = 200;
    mock_file_content = NULL;
    mock_file_size = 0;
    mock_file_pos = 0;
    return 0;
}

/* ========================================================================
 * Pure logic tests: k8s_config_init_default
 * ======================================================================== */

static void test_config_init_default(void **state) {
    (void)state;
    k8s_config_t config;
    k8s_config_init_default(&config);

    assert_string_equal(config.api_server_url, "https://kubernetes.default.svc");
    assert_string_equal(config.ca_cert_path, "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt");
    assert_string_equal(config.token_path, "/var/run/secrets/kubernetes.io/serviceaccount/token");
    assert_int_equal(config.timeout_seconds, 10);
}

/* ========================================================================
 * Pure logic tests: k8s_parse_username
 * ======================================================================== */

static void test_parse_username_valid(void **state) {
    (void)state;
    char ns[256], sa[256];
    int ret = k8s_parse_username("system:serviceaccount:default:myapp", ns, sizeof(ns), sa, sizeof(sa));
    assert_int_equal(ret, 1);
    assert_string_equal(ns, "default");
    assert_string_equal(sa, "myapp");
}

static void test_parse_username_hyphenated(void **state) {
    (void)state;
    char ns[256], sa[256];
    int ret = k8s_parse_username("system:serviceaccount:my-namespace:my-service-account",
                                 ns, sizeof(ns), sa, sizeof(sa));
    assert_int_equal(ret, 1);
    assert_string_equal(ns, "my-namespace");
    assert_string_equal(sa, "my-service-account");
}

static void test_parse_username_missing_prefix(void **state) {
    (void)state;
    char ns[256], sa[256];
    int ret = k8s_parse_username("default:myapp", ns, sizeof(ns), sa, sizeof(sa));
    assert_int_equal(ret, 0);
}

static void test_parse_username_empty(void **state) {
    (void)state;
    char ns[256], sa[256];
    int ret = k8s_parse_username("", ns, sizeof(ns), sa, sizeof(sa));
    assert_int_equal(ret, 0);
}

static void test_parse_username_null_inputs(void **state) {
    (void)state;
    char ns[256], sa[256];
    assert_int_equal(k8s_parse_username(NULL, ns, sizeof(ns), sa, sizeof(sa)), 0);
    assert_int_equal(k8s_parse_username("system:serviceaccount:ns:sa", NULL, 0, sa, sizeof(sa)), 0);
    assert_int_equal(k8s_parse_username("system:serviceaccount:ns:sa", ns, sizeof(ns), NULL, 0), 0);
}

/* ========================================================================
 * Mocked tests: k8s_validate_token
 * ======================================================================== */

/* Valid TokenReview JSON response */
#define VALID_RESPONSE \
    "{\"status\":{\"authenticated\":true,\"user\":{" \
    "\"username\":\"system:serviceaccount:default:myapp\"," \
    "\"uid\":\"test-uid-123\"}}}"

#define UNAUTHENTICATED_RESPONSE \
    "{\"status\":{\"authenticated\":false}}"

#define WRONG_USER_RESPONSE \
    "{\"status\":{\"authenticated\":true,\"user\":{" \
    "\"username\":\"system:serviceaccount:other-ns:other-sa\"," \
    "\"uid\":\"uid-456\"}}}"

#define MALFORMED_RESPONSE "not json at all {"

#define NO_STATUS_RESPONSE "{\"kind\":\"TokenReview\"}"

#define NO_USER_RESPONSE \
    "{\"status\":{\"authenticated\":true}}"

static void test_validate_token_happy_path(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    /* Mock: fopen returns a FILE*, file contains SA token */
    setup_mock_file("sa-token-data");
    will_return(__wrap_fopen, (FILE*)0xDEAD);

    /* Mock: curl_easy_init returns a handle */
    will_return(__wrap_curl_easy_init, (CURL*)0xBEEF);

    /* Mock: curl_easy_perform succeeds */
    mock_response_json = VALID_RESPONSE;
    mock_http_code = 201;
    will_return(__wrap_curl_easy_perform, CURLE_OK);

    int ret = k8s_validate_token("test-token", &info, &config);

    assert_int_equal(ret, 1);
    assert_int_equal(info.authenticated, 1);
    assert_string_equal(info.username, "system:serviceaccount:default:myapp");
    assert_string_equal(info.namespace, "default");
    assert_string_equal(info.service_account, "myapp");
    assert_string_equal(info.uid, "test-uid-123");
    assert_true(info.validated_at > 0);
}

static void test_validate_token_unauthenticated(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    setup_mock_file("sa-token-data");
    will_return(__wrap_fopen, (FILE*)0xDEAD);
    will_return(__wrap_curl_easy_init, (CURL*)0xBEEF);

    mock_response_json = UNAUTHENTICATED_RESPONSE;
    mock_http_code = 201;
    will_return(__wrap_curl_easy_perform, CURLE_OK);

    int ret = k8s_validate_token("bad-token", &info, &config);
    assert_int_equal(ret, 0);
}

static void test_validate_token_username_mismatch(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    setup_mock_file("sa-token-data");
    will_return(__wrap_fopen, (FILE*)0xDEAD);
    will_return(__wrap_curl_easy_init, (CURL*)0xBEEF);

    /* Response is authenticated but for a different user - still returns 1
     * because k8s_validate_token doesn't check username match itself;
     * the caller (auth_k8s.c) does that comparison */
    mock_response_json = WRONG_USER_RESPONSE;
    mock_http_code = 201;
    will_return(__wrap_curl_easy_perform, CURLE_OK);

    int ret = k8s_validate_token("test-token", &info, &config);
    assert_int_equal(ret, 1);
    assert_string_equal(info.namespace, "other-ns");
    assert_string_equal(info.service_account, "other-sa");
}

static void test_validate_token_http_403(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    setup_mock_file("sa-token-data");
    will_return(__wrap_fopen, (FILE*)0xDEAD);
    will_return(__wrap_curl_easy_init, (CURL*)0xBEEF);

    mock_response_json = "{\"message\":\"forbidden\"}";
    mock_http_code = 403;
    will_return(__wrap_curl_easy_perform, CURLE_OK);

    int ret = k8s_validate_token("test-token", &info, &config);
    assert_int_equal(ret, 0);
}

static void test_validate_token_curl_perform_fails(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    setup_mock_file("sa-token-data");
    will_return(__wrap_fopen, (FILE*)0xDEAD);
    will_return(__wrap_curl_easy_init, (CURL*)0xBEEF);

    will_return(__wrap_curl_easy_perform, CURLE_OPERATION_TIMEDOUT);

    int ret = k8s_validate_token("test-token", &info, &config);
    assert_int_equal(ret, 0);
}

static void test_validate_token_curl_init_fails(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    /* curl_easy_init returns NULL */
    will_return(__wrap_curl_easy_init, NULL);

    /* fopen is NOT called because curl_easy_init is called first in the code...
     * Actually, looking at the code flow: input validation -> config -> curl_easy_init -> read_file
     * So curl_easy_init fails before fopen is called */

    int ret = k8s_validate_token("test-token", &info, &config);
    assert_int_equal(ret, 0);
}

static void test_validate_token_malformed_json(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    setup_mock_file("sa-token-data");
    will_return(__wrap_fopen, (FILE*)0xDEAD);
    will_return(__wrap_curl_easy_init, (CURL*)0xBEEF);

    mock_response_json = MALFORMED_RESPONSE;
    mock_http_code = 201;
    will_return(__wrap_curl_easy_perform, CURLE_OK);

    int ret = k8s_validate_token("test-token", &info, &config);
    assert_int_equal(ret, 0);
}

static void test_validate_token_missing_status(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    setup_mock_file("sa-token-data");
    will_return(__wrap_fopen, (FILE*)0xDEAD);
    will_return(__wrap_curl_easy_init, (CURL*)0xBEEF);

    mock_response_json = NO_STATUS_RESPONSE;
    mock_http_code = 201;
    will_return(__wrap_curl_easy_perform, CURLE_OK);

    int ret = k8s_validate_token("test-token", &info, &config);
    assert_int_equal(ret, 0);
}

static void test_validate_token_missing_user(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    setup_mock_file("sa-token-data");
    will_return(__wrap_fopen, (FILE*)0xDEAD);
    will_return(__wrap_curl_easy_init, (CURL*)0xBEEF);

    mock_response_json = NO_USER_RESPONSE;
    mock_http_code = 201;
    will_return(__wrap_curl_easy_perform, CURLE_OK);

    int ret = k8s_validate_token("test-token", &info, &config);
    assert_int_equal(ret, 0);
}

static void test_validate_token_null_token(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    int ret = k8s_validate_token(NULL, &info, &config);
    assert_int_equal(ret, 0);
}

static void test_validate_token_null_info(void **state) {
    (void)state;
    k8s_config_t config;
    k8s_config_init_default(&config);

    int ret = k8s_validate_token("test-token", NULL, &config);
    assert_int_equal(ret, 0);
}

static void test_validate_token_sa_file_unreadable(void **state) {
    (void)state;
    k8s_token_info_t info;
    k8s_config_t config;
    k8s_config_init_default(&config);

    will_return(__wrap_curl_easy_init, (CURL*)0xBEEF);

    /* fopen returns NULL (file not found / unreadable) */
    will_return(__wrap_fopen, NULL);

    int ret = k8s_validate_token("test-token", &info, &config);
    assert_int_equal(ret, 0);
}

/* ========================================================================
 * Main: register all tests
 * ======================================================================== */

int main(void) {
    const struct CMUnitTest tests[] = {
        /* Pure logic tests */
        cmocka_unit_test_setup(test_config_init_default, test_setup),
        cmocka_unit_test_setup(test_parse_username_valid, test_setup),
        cmocka_unit_test_setup(test_parse_username_hyphenated, test_setup),
        cmocka_unit_test_setup(test_parse_username_missing_prefix, test_setup),
        cmocka_unit_test_setup(test_parse_username_empty, test_setup),
        cmocka_unit_test_setup(test_parse_username_null_inputs, test_setup),

        /* Mocked k8s_validate_token tests */
        cmocka_unit_test_setup(test_validate_token_happy_path, test_setup),
        cmocka_unit_test_setup(test_validate_token_unauthenticated, test_setup),
        cmocka_unit_test_setup(test_validate_token_username_mismatch, test_setup),
        cmocka_unit_test_setup(test_validate_token_http_403, test_setup),
        cmocka_unit_test_setup(test_validate_token_curl_perform_fails, test_setup),
        cmocka_unit_test_setup(test_validate_token_curl_init_fails, test_setup),
        cmocka_unit_test_setup(test_validate_token_malformed_json, test_setup),
        cmocka_unit_test_setup(test_validate_token_missing_status, test_setup),
        cmocka_unit_test_setup(test_validate_token_missing_user, test_setup),
        cmocka_unit_test_setup(test_validate_token_null_token, test_setup),
        cmocka_unit_test_setup(test_validate_token_null_info, test_setup),
        cmocka_unit_test_setup(test_validate_token_sa_file_unreadable, test_setup),
    };

    return cmocka_run_group_tests(tests, NULL, NULL);
}
