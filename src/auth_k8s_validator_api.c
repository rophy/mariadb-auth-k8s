/*
 * MariaDB Kubernetes ServiceAccount Authentication Plugin - API Client
 *
 * Validates ServiceAccount tokens by calling Federated K8s Auth service.
 * This plugin delegates JWT validation to a separate service that federates
 * authentication across multiple Kubernetes clusters.
 */

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <curl/curl.h>
#include <json-c/json.h>
#include <mysql/plugin_auth.h>

/* Plugin version */
#define PLUGIN_VERSION 0x0300

/* Default Federated K8s Auth API endpoint */
#ifndef FEDERATED_K8S_AUTH_URL
#define FEDERATED_K8S_AUTH_URL "http://federated-k8s-auth.default.svc.cluster.local:8080/api/v1/validate"
#endif

/* Buffer for HTTP response */
typedef struct {
    char *data;
    size_t size;
} http_response_t;

/*
 * CURL write callback
 */
static size_t write_callback(void *contents, size_t size, size_t nmemb, void *userp)
{
    size_t real_size = size * nmemb;
    http_response_t *response = (http_response_t *)userp;

    char *ptr = realloc(response->data, response->size + real_size + 1);
    if (!ptr) {
        fprintf(stderr, "K8s Auth API: Memory allocation failed\n");
        return 0;
    }

    response->data = ptr;
    memcpy(&(response->data[response->size]), contents, real_size);
    response->size += real_size;
    response->data[response->size] = 0;

    return real_size;
}

/*
 * Extract cluster name from MariaDB username
 * Expected format: cluster_name/namespace/serviceaccount
 * Returns: cluster_name (caller must free), or NULL on error
 */
static char* extract_cluster_name(const char *username)
{
    if (!username) return NULL;

    const char *slash = strchr(username, '/');
    if (!slash) {
        fprintf(stderr, "K8s Auth API: Invalid username format (expected: cluster/namespace/serviceaccount)\n");
        return NULL;
    }

    size_t len = slash - username;
    char *cluster_name = malloc(len + 1);
    if (!cluster_name) return NULL;

    memcpy(cluster_name, username, len);
    cluster_name[len] = '\0';

    return cluster_name;
}

/*
 * Call Federated K8s Auth API to validate token
 * Returns: 1 on success (authenticated), 0 on failure
 * Sets authenticated_username if provided
 */
static int validate_token_via_api(const char *cluster_name, const char *token, char **authenticated_username)
{
    CURL *curl;
    CURLcode res;
    long http_code = 0;
    int result = 0;

    /* Get API URL from environment or use default */
    const char *api_url = getenv("FEDERATED_K8S_AUTH_URL");
    if (!api_url) {
        api_url = FEDERATED_K8S_AUTH_URL;
    }

    fprintf(stderr, "K8s Auth API: Validating token via %s\n", api_url);

    /* Initialize CURL */
    curl = curl_easy_init();
    if (!curl) {
        fprintf(stderr, "K8s Auth API: Failed to initialize CURL\n");
        return 0;
    }

    /* Prepare request body */
    struct json_object *request_json = json_object_new_object();
    json_object_object_add(request_json, "cluster_name", json_object_new_string(cluster_name));
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

    /* Set headers */
    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);

    /* Perform request */
    res = curl_easy_perform(curl);

    if (res != CURLE_OK) {
        fprintf(stderr, "K8s Auth API: Request failed: %s\n", curl_easy_strerror(res));
        goto cleanup;
    }

    /* Get HTTP status code */
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    fprintf(stderr, "K8s Auth API: HTTP status: %ld\n", http_code);

    /* Parse response */
    if (response.data) {
        struct json_object *response_json = json_tokener_parse(response.data);
        if (!response_json) {
            fprintf(stderr, "K8s Auth API: Failed to parse JSON response\n");
            goto cleanup;
        }

        /* Check authenticated field */
        struct json_object *authenticated_obj;
        if (json_object_object_get_ex(response_json, "authenticated", &authenticated_obj)) {
            int authenticated = json_object_get_boolean(authenticated_obj);

            if (authenticated && http_code == 200) {
                /* Get username from response */
                struct json_object *username_obj;
                if (json_object_object_get_ex(response_json, "username", &username_obj)) {
                    const char *username = json_object_get_string(username_obj);
                    if (authenticated_username) {
                        *authenticated_username = strdup(username);
                    }
                    fprintf(stderr, "K8s Auth API: ✅ Authentication successful: %s\n", username);
                    result = 1;
                } else {
                    fprintf(stderr, "K8s Auth API: Response missing username field\n");
                }
            } else {
                /* Log error details */
                struct json_object *error_obj, *message_obj;
                const char *error = "unknown";
                const char *message = "no details";

                if (json_object_object_get_ex(response_json, "error", &error_obj)) {
                    error = json_object_get_string(error_obj);
                }
                if (json_object_object_get_ex(response_json, "message", &message_obj)) {
                    message = json_object_get_string(message_obj);
                }

                fprintf(stderr, "K8s Auth API: ❌ Authentication failed: %s - %s\n", error, message);
            }
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
 * Server authentication function
 */
static int auth_k8s_server(MYSQL_PLUGIN_VIO *vio, MYSQL_SERVER_AUTH_INFO *info)
{
    unsigned char *packet;
    int packet_len;
    char *token = NULL;
    char *cluster_name = NULL;
    char *authenticated_username = NULL;
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

    /* Check if token was provided */
    if (packet_len == 0) {
        fprintf(stderr, "K8s Auth API: No token provided\n");
        info->password_used = PASSWORD_USED_NO;
        return CR_ERROR;
    }

    info->password_used = PASSWORD_USED_YES;

    /* Null-terminate the token string */
    token = malloc(packet_len + 1);
    if (!token) {
        fprintf(stderr, "K8s Auth API: Memory allocation failed\n");
        return CR_ERROR;
    }
    memcpy(token, packet, packet_len);
    token[packet_len] = '\0';

    /* Log authentication attempt */
    fprintf(stderr, "K8s Auth API: Authenticating user '%s'\n", info->user_name);

    /* Extract cluster name from username */
    cluster_name = extract_cluster_name(info->user_name);
    if (!cluster_name) {
        fprintf(stderr, "K8s Auth API: Failed to extract cluster name from username\n");
        goto cleanup;
    }

    fprintf(stderr, "K8s Auth API: Cluster name: %s\n", cluster_name);

    /* Validate token via API */
    if (!validate_token_via_api(cluster_name, token, &authenticated_username)) {
        fprintf(stderr, "K8s Auth API: Token validation failed\n");
        goto cleanup;
    }

    /* Verify that the authenticated username matches the requested username */
    if (!authenticated_username || strcmp(info->user_name, authenticated_username) != 0) {
        fprintf(stderr, "K8s Auth API: Username mismatch. Expected '%s', got '%s'\n",
                info->user_name, authenticated_username ? authenticated_username : "(null)");
        goto cleanup;
    }

    /* Set authenticated username in info struct */
    strncpy(info->authenticated_as, authenticated_username, sizeof(info->authenticated_as) - 1);
    info->authenticated_as[sizeof(info->authenticated_as) - 1] = '\0';

    fprintf(stderr, "K8s Auth API: ✅ Authentication successful for %s\n", info->authenticated_as);
    result = CR_OK;

cleanup:
    if (token) free(token);
    if (cluster_name) free(cluster_name);
    if (authenticated_username) free(authenticated_username);

    return result;
}

/*
 * Plugin descriptor structure
 */
static struct st_mysql_auth auth_k8s_handler = {
    MYSQL_AUTHENTICATION_INTERFACE_VERSION,
    "mysql_clear_password",  /* Client plugin name */
    auth_k8s_server,         /* Server authentication function */
    NULL,                    /* Generate auth string (not used) */
    NULL                     /* Validate auth string (not used) */
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
    "Kubernetes ServiceAccount Authentication via Federated K8s Auth",
    PLUGIN_LICENSE_GPL,
    NULL,                 /* Plugin init */
    NULL,                 /* Plugin deinit */
    PLUGIN_VERSION,
    NULL,                 /* Status variables */
    NULL,                 /* System variables */
    NULL,                 /* Config options */
    0                     /* Flags */
}
mysql_declare_plugin_end;
