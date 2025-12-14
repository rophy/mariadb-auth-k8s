/*
 * MariaDB Kubernetes ServiceAccount Authentication Plugin - Unified
 *
 * Validates ServiceAccount tokens with automatic fallback:
 * 1. AUTH API (kube-federated-auth) - if KUBE_FEDERATED_AUTH_URL is set
 * 2. JWKS (local OIDC) - fallback for local cluster only
 *
 * Username format: cluster/namespace/serviceaccount
 * - 3-part: cluster-b/default/myapp → cross-cluster
 * - 3-part with "local": local/default/myapp → local cluster
 * - 2-part: default/myapp → local cluster (implicit)
 */

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <curl/curl.h>
#include <json-c/json.h>
#include <mysql/plugin_auth.h>
#include "jwt_crypto.h"
#include "version.h"

/* Default maximum token TTL (1 hour) */
#define DEFAULT_MAX_TOKEN_TTL 3600

/* Buffer for HTTP response */
typedef struct {
    char *data;
    size_t size;
} http_response_t;

/* Parsed username components */
typedef struct {
    char cluster[128];
    char namespace[128];
    char service_account[128];
    int is_local;       /* 1 if local cluster (2-part or cluster="local") */
    int is_three_part;  /* 1 if 3-part format */
} parsed_username_t;

/* Validation result */
typedef enum {
    VALIDATION_SUCCESS,
    VALIDATION_FAILED,
    VALIDATION_UNAVAILABLE  /* AUTH API network error - can fallback */
} validation_result_t;

/* Forward declarations */
static validation_result_t validate_via_auth_api(const char *cluster, const char *token,
                                                  char **authenticated_username);
static int validate_via_jwks(const char *token, const char *expected_ns,
                             const char *expected_sa);

/*
 * CURL write callback
 */
static size_t write_callback(void *contents, size_t size, size_t nmemb, void *userp)
{
    size_t real_size = size * nmemb;
    http_response_t *response = (http_response_t *)userp;

    char *ptr = realloc(response->data, response->size + real_size + 1);
    if (!ptr) {
        fprintf(stderr, "K8s Auth: Memory allocation failed\n");
        return 0;
    }

    response->data = ptr;
    memcpy(&(response->data[response->size]), contents, real_size);
    response->size += real_size;
    response->data[response->size] = 0;

    return real_size;
}

/*
 * Parse MariaDB username into components
 *
 * Formats:
 * - 3-part: "cluster/namespace/serviceaccount"
 * - 2-part: "namespace/serviceaccount" (implicit local)
 *
 * Returns 0 on success, -1 on error
 */
static int parse_username(const char *username, parsed_username_t *parsed)
{
    if (!username || !parsed) return -1;

    memset(parsed, 0, sizeof(parsed_username_t));

    /* Count slashes to determine format */
    int slash_count = 0;
    const char *p = username;
    const char *slash1 = NULL;
    const char *slash2 = NULL;

    while (*p) {
        if (*p == '/') {
            slash_count++;
            if (!slash1) slash1 = p;
            else if (!slash2) slash2 = p;
        }
        p++;
    }

    if (slash_count == 1) {
        /* 2-part format: namespace/serviceaccount */
        parsed->is_three_part = 0;
        parsed->is_local = 1;
        strncpy(parsed->cluster, "local", sizeof(parsed->cluster) - 1);

        size_t ns_len = slash1 - username;
        if (ns_len >= sizeof(parsed->namespace)) return -1;
        strncpy(parsed->namespace, username, ns_len);
        parsed->namespace[ns_len] = '\0';

        strncpy(parsed->service_account, slash1 + 1, sizeof(parsed->service_account) - 1);

    } else if (slash_count == 2) {
        /* 3-part format: cluster/namespace/serviceaccount */
        parsed->is_three_part = 1;

        size_t cluster_len = slash1 - username;
        if (cluster_len >= sizeof(parsed->cluster)) return -1;
        strncpy(parsed->cluster, username, cluster_len);
        parsed->cluster[cluster_len] = '\0';

        size_t ns_len = slash2 - (slash1 + 1);
        if (ns_len >= sizeof(parsed->namespace)) return -1;
        strncpy(parsed->namespace, slash1 + 1, ns_len);
        parsed->namespace[ns_len] = '\0';

        strncpy(parsed->service_account, slash2 + 1, sizeof(parsed->service_account) - 1);

        /* Check if cluster is "local" */
        parsed->is_local = (strcmp(parsed->cluster, "local") == 0);

    } else {
        fprintf(stderr, "K8s Auth: Invalid username format '%s' (expected: [cluster/]namespace/serviceaccount)\n", username);
        return -1;
    }

    return 0;
}

/*
 * Get maximum token TTL from environment or use default
 */
static long get_max_token_ttl(void)
{
    const char *env_ttl = getenv("MAX_TOKEN_TTL");
    if (env_ttl) {
        long ttl = atol(env_ttl);
        if (ttl > 0) {
            return ttl;
        }
    }
    return DEFAULT_MAX_TOKEN_TTL;
}

/*
 * Validate token via AUTH API (kube-federated-auth)
 *
 * Returns:
 * - VALIDATION_SUCCESS: Token validated successfully
 * - VALIDATION_FAILED: Token validation failed (auth error)
 * - VALIDATION_UNAVAILABLE: Network error, can fallback
 */
static validation_result_t validate_via_auth_api(const char *cluster, const char *token,
                                                  char **authenticated_username)
{
    CURL *curl;
    CURLcode res;
    long http_code = 0;
    validation_result_t result = VALIDATION_FAILED;

    const char *api_url = getenv("KUBE_FEDERATED_AUTH_URL");
    if (!api_url) {
        return VALIDATION_UNAVAILABLE;
    }

    fprintf(stderr, "K8s Auth: Validating token via AUTH API %s\n", api_url);

    curl = curl_easy_init();
    if (!curl) {
        fprintf(stderr, "K8s Auth: Failed to initialize CURL\n");
        return VALIDATION_UNAVAILABLE;
    }

    /* Prepare request body */
    struct json_object *request_json = json_object_new_object();
    json_object_object_add(request_json, "cluster", json_object_new_string(cluster));
    json_object_object_add(request_json, "token", json_object_new_string(token));
    const char *request_body = json_object_to_json_string(request_json);

    /* Prepare response buffer */
    http_response_t response = {0};

    /* Set CURL options */
    curl_easy_setopt(curl, CURLOPT_URL, api_url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, request_body);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);

    /* Set headers */
    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

    /* Perform request */
    res = curl_easy_perform(curl);

    if (res != CURLE_OK) {
        fprintf(stderr, "K8s Auth: AUTH API request failed: %s\n", curl_easy_strerror(res));
        result = VALIDATION_UNAVAILABLE;
        goto cleanup;
    }

    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    fprintf(stderr, "K8s Auth: AUTH API HTTP status: %ld\n", http_code);

    /* Parse response */
    if (response.data) {
        struct json_object *response_json = json_tokener_parse(response.data);
        if (!response_json) {
            fprintf(stderr, "K8s Auth: Failed to parse JSON response\n");
            result = VALIDATION_FAILED;
            goto cleanup;
        }

        if (http_code == 200) {
            /* Extract cluster, namespace, and serviceaccount from claims */
            struct json_object *cluster_obj, *k8s_obj;
            const char *resp_cluster = NULL;
            const char *namespace = NULL;
            const char *sa_name = NULL;

            if (json_object_object_get_ex(response_json, "cluster", &cluster_obj)) {
                resp_cluster = json_object_get_string(cluster_obj);
            }

            /* Parse kubernetes.io claims */
            if (json_object_object_get_ex(response_json, "kubernetes.io", &k8s_obj)) {
                struct json_object *ns_obj, *sa_obj, *sa_name_obj;
                if (json_object_object_get_ex(k8s_obj, "namespace", &ns_obj)) {
                    namespace = json_object_get_string(ns_obj);
                }
                if (json_object_object_get_ex(k8s_obj, "serviceaccount", &sa_obj)) {
                    if (json_object_object_get_ex(sa_obj, "name", &sa_name_obj)) {
                        sa_name = json_object_get_string(sa_name_obj);
                    }
                }
            }

            if (resp_cluster && namespace && sa_name) {
                /* Check token TTL */
                struct json_object *exp_obj, *iat_obj;
                if (json_object_object_get_ex(response_json, "exp", &exp_obj) &&
                    json_object_object_get_ex(response_json, "iat", &iat_obj)) {
                    long exp = json_object_get_int64(exp_obj);
                    long iat = json_object_get_int64(iat_obj);

                    if (exp > 0 && iat > 0) {
                        long token_lifetime = exp - iat;
                        long max_ttl = get_max_token_ttl();

                        if (token_lifetime > max_ttl) {
                            fprintf(stderr, "K8s Auth: Token TTL (%lds) exceeds maximum allowed (%lds)\n",
                                    token_lifetime, max_ttl);
                            json_object_put(response_json);
                            result = VALIDATION_FAILED;
                            goto cleanup;
                        }
                        fprintf(stderr, "K8s Auth: Token TTL: %lds (max: %lds)\n", token_lifetime, max_ttl);
                    }
                }

                /* Construct authenticated username */
                if (authenticated_username) {
                    size_t username_len = strlen(resp_cluster) + strlen(namespace) + strlen(sa_name) + 3;
                    *authenticated_username = malloc(username_len);
                    if (*authenticated_username) {
                        snprintf(*authenticated_username, username_len, "%s/%s/%s", resp_cluster, namespace, sa_name);
                    }
                }
                fprintf(stderr, "K8s Auth: AUTH API validated: %s/%s/%s\n", resp_cluster, namespace, sa_name);
                result = VALIDATION_SUCCESS;
            } else {
                fprintf(stderr, "K8s Auth: Response missing required claims\n");
                result = VALIDATION_FAILED;
            }
        } else {
            /* Error response */
            struct json_object *error_obj, *message_obj;
            const char *error = "unknown";
            const char *message = "no details";

            if (json_object_object_get_ex(response_json, "error", &error_obj)) {
                error = json_object_get_string(error_obj);
            }
            if (json_object_object_get_ex(response_json, "message", &message_obj)) {
                message = json_object_get_string(message_obj);
            }

            fprintf(stderr, "K8s Auth: AUTH API error: %s - %s\n", error, message);
            result = VALIDATION_FAILED;
        }

        json_object_put(response_json);
    }

cleanup:
    if (response.data) free(response.data);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    json_object_put(request_json);

    return result;
}

/*
 * Validate token via JWKS (local OIDC)
 *
 * Returns 1 on success, 0 on failure
 */
static int validate_via_jwks(const char *token, const char *expected_ns, const char *expected_sa)
{
    k8s_jwt_token_info_t token_info;
    char error_msg[256] = {0};

    fprintf(stderr, "K8s Auth: Validating token via JWKS (local OIDC)\n");

    int valid = k8s_jwt_validate_token(token, &token_info, error_msg);
    if (!valid || !token_info.authenticated) {
        fprintf(stderr, "K8s Auth: JWKS validation failed: %s\n",
                error_msg[0] ? error_msg : "Unknown error");
        return 0;
    }

    /* Verify namespace and service account match */
    if (strcmp(token_info.namespace, expected_ns) != 0 ||
        strcmp(token_info.service_account, expected_sa) != 0) {
        fprintf(stderr, "K8s Auth: Token identity mismatch. Expected %s/%s, got %s/%s\n",
                expected_ns, expected_sa, token_info.namespace, token_info.service_account);
        return 0;
    }

    /* Check token TTL */
    long max_ttl = get_max_token_ttl();
    time_t now = time(NULL);
    if (token_info.expiration > 0) {
        /* We don't have iat in token_info, so we just check if within max_ttl from now */
        /* This is a simpler check - token must expire within max_ttl from now */
        long remaining = token_info.expiration - now;
        if (remaining > max_ttl) {
            fprintf(stderr, "K8s Auth: Token remaining lifetime (%lds) exceeds maximum allowed (%lds)\n",
                    remaining, max_ttl);
            return 0;
        }
    }

    fprintf(stderr, "K8s Auth: JWKS validated: %s/%s\n", token_info.namespace, token_info.service_account);
    return 1;
}

/*
 * Plugin initialization
 */
static int auth_k8s_plugin_init(void *p)
{
    fprintf(stderr, "K8s Auth: Initializing unified plugin...\n");

    /* Initialize JWT validator for JWKS fallback */
    if (jwt_crypto_init() != 0) {
        fprintf(stderr, "K8s Auth: Warning: Failed to initialize JWT validator (JWKS fallback unavailable)\n");
        /* Don't fail - AUTH API might still work */
    }

    const char *api_url = getenv("KUBE_FEDERATED_AUTH_URL");
    if (api_url) {
        fprintf(stderr, "K8s Auth: AUTH API configured: %s\n", api_url);
    } else {
        fprintf(stderr, "K8s Auth: AUTH API not configured, will use JWKS for local cluster\n");
    }

    fprintf(stderr, "K8s Auth: Plugin initialized successfully\n");
    return 0;
}

/*
 * Plugin deinitialization
 */
static int auth_k8s_plugin_deinit(void *p)
{
    fprintf(stderr, "K8s Auth: Cleaning up plugin...\n");
    jwt_crypto_cleanup();
    return 0;
}

/*
 * Server authentication function
 *
 * Validation flow:
 * 1. Parse username to extract cluster/namespace/sa
 * 2. If AUTH API configured, try AUTH API
 *    - Success → DONE
 *    - Unavailable (network error) → fallback
 * 3. If cross-cluster → FAIL (cannot validate without AUTH API)
 * 4. Try JWKS validation (local cluster only)
 */
static int auth_k8s_server(MYSQL_PLUGIN_VIO *vio, MYSQL_SERVER_AUTH_INFO *info)
{
    unsigned char *packet;
    int packet_len;
    char *token = NULL;
    char *authenticated_username = NULL;
    parsed_username_t parsed;
    int result = CR_ERROR;

    /* Send a request to the client for the ServiceAccount token */
    if (vio->write_packet(vio, (unsigned char *)"", 0)) {
        return CR_ERROR;
    }

    /* Read the token from the client */
    packet_len = vio->read_packet(vio, &packet);
    if (packet_len < 0) {
        return CR_ERROR;
    }

    if (packet_len == 0) {
        fprintf(stderr, "K8s Auth: No token provided\n");
        info->password_used = PASSWORD_USED_NO;
        return CR_ERROR;
    }

    info->password_used = PASSWORD_USED_YES;

    /* Null-terminate the token */
    token = malloc(packet_len + 1);
    if (!token) {
        fprintf(stderr, "K8s Auth: Memory allocation failed\n");
        return CR_ERROR;
    }
    memcpy(token, packet, packet_len);
    token[packet_len] = '\0';

    fprintf(stderr, "K8s Auth: Authenticating user '%s'\n", info->user_name);

    /* Parse username */
    if (parse_username(info->user_name, &parsed) != 0) {
        fprintf(stderr, "K8s Auth: Failed to parse username\n");
        goto cleanup;
    }

    fprintf(stderr, "K8s Auth: Parsed - cluster=%s, namespace=%s, sa=%s, is_local=%d\n",
            parsed.cluster, parsed.namespace, parsed.service_account, parsed.is_local);

    /* Step 2: Try AUTH API if configured */
    const char *api_url = getenv("KUBE_FEDERATED_AUTH_URL");
    if (api_url) {
        validation_result_t api_result = validate_via_auth_api(parsed.cluster, token, &authenticated_username);

        if (api_result == VALIDATION_SUCCESS) {
            /* Verify authenticated username matches requested username */
            char expected_username[384];
            snprintf(expected_username, sizeof(expected_username), "%s/%s/%s",
                     parsed.cluster, parsed.namespace, parsed.service_account);

            if (!authenticated_username || strcmp(expected_username, authenticated_username) != 0) {
                fprintf(stderr, "K8s Auth: Username mismatch. Expected '%s', got '%s'\n",
                        expected_username, authenticated_username ? authenticated_username : "(null)");
                goto cleanup;
            }

            strncpy(info->authenticated_as, authenticated_username, sizeof(info->authenticated_as) - 1);
            info->authenticated_as[sizeof(info->authenticated_as) - 1] = '\0';

            fprintf(stderr, "K8s Auth: Authentication successful (AUTH API)\n");
            result = CR_OK;
            goto cleanup;
        }

        if (api_result == VALIDATION_FAILED) {
            /* Auth failure, no fallback */
            fprintf(stderr, "K8s Auth: AUTH API rejected token\n");
            goto cleanup;
        }

        /* VALIDATION_UNAVAILABLE - try fallback */
        fprintf(stderr, "K8s Auth: AUTH API unavailable, attempting fallback...\n");
    }

    /* Step 3: Check if cross-cluster (cannot validate without AUTH API) */
    if (!parsed.is_local) {
        fprintf(stderr, "K8s Auth: Cannot validate cross-cluster token without AUTH API\n");
        goto cleanup;
    }

    /* Step 4: JWKS validation for local cluster */
    if (validate_via_jwks(token, parsed.namespace, parsed.service_account)) {
        /* Build authenticated username */
        snprintf(info->authenticated_as, sizeof(info->authenticated_as), "%s/%s/%s",
                 parsed.cluster, parsed.namespace, parsed.service_account);

        fprintf(stderr, "K8s Auth: Authentication successful (JWKS)\n");
        result = CR_OK;
    }

cleanup:
    if (token) free(token);
    if (authenticated_username) free(authenticated_username);

    return result;
}

/*
 * Plugin descriptor structure
 */
static struct st_mysql_auth auth_k8s_handler = {
    MYSQL_AUTHENTICATION_INTERFACE_VERSION,
    "mysql_clear_password",
    auth_k8s_server,
    NULL,
    NULL
};

/*
 * Plugin declaration
 */
mysql_declare_plugin(auth_k8s)
{
    MYSQL_AUTHENTICATION_PLUGIN,
    &auth_k8s_handler,
    "auth_k8s",
    "MariaDB K8s Auth Plugin Contributors",
    "Kubernetes ServiceAccount Authentication (AUTH API + JWKS fallback)",
    PLUGIN_LICENSE_GPL,
    auth_k8s_plugin_init,
    auth_k8s_plugin_deinit,
    PLUGIN_VERSION,
    NULL,
    NULL,
    NULL,
    0
}
mysql_declare_plugin_end;
