/*
 * Kubernetes TokenReview API Client Implementation
 */

#include "k8s_token_validator.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <curl/curl.h>
#include <json-c/json.h>

/* Default configuration values */
#define DEFAULT_API_SERVER "https://kubernetes.default.svc"
#define DEFAULT_CA_CERT "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
#define DEFAULT_TOKEN_PATH "/var/run/secrets/kubernetes.io/serviceaccount/token"
#define DEFAULT_TIMEOUT 10

/* Buffer for response data */
typedef struct {
    char *data;
    size_t size;
} response_buffer_t;

/**
 * Callback function for libcurl to write response data
 */
static size_t write_callback(void *contents, size_t size, size_t nmemb, void *userp) {
    size_t realsize = size * nmemb;
    response_buffer_t *buffer = (response_buffer_t *)userp;

    char *ptr = realloc(buffer->data, buffer->size + realsize + 1);
    if (ptr == NULL) {
        fprintf(stderr, "K8s Auth: Out of memory for response buffer\n");
        return 0;
    }

    buffer->data = ptr;
    memcpy(&(buffer->data[buffer->size]), contents, realsize);
    buffer->size += realsize;
    buffer->data[buffer->size] = '\0';

    return realsize;
}

/**
 * Read file contents into a string
 */
static char* read_file(const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) {
        return NULL;
    }

    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    if (size <= 0 || size > 1024 * 1024) { /* Max 1MB */
        fclose(fp);
        return NULL;
    }

    char *content = malloc(size + 1);
    if (!content) {
        fclose(fp);
        return NULL;
    }

    size_t read = fread(content, 1, size, fp);
    content[read] = '\0';
    fclose(fp);

    return content;
}

void k8s_config_init_default(k8s_config_t *config) {
    config->api_server_url = DEFAULT_API_SERVER;
    config->ca_cert_path = DEFAULT_CA_CERT;
    config->token_path = DEFAULT_TOKEN_PATH;
    config->timeout_seconds = DEFAULT_TIMEOUT;
}

int k8s_parse_username(const char *username, char *namespace, size_t namespace_len,
                       char *service_account, size_t sa_len) {
    if (!username || !namespace || !service_account) {
        return 0;
    }

    /* Expected format: system:serviceaccount:namespace:serviceaccount-name */
    char temp_ns[K8S_MAX_NAMESPACE_LEN + 1];
    char temp_sa[K8S_MAX_NAME_LEN + 1];

    int matched = sscanf(username, "system:serviceaccount:%253[^:]:%253s", temp_ns, temp_sa);
    if (matched != 2) {
        return 0;
    }

    strncpy(namespace, temp_ns, namespace_len - 1);
    namespace[namespace_len - 1] = '\0';

    strncpy(service_account, temp_sa, sa_len - 1);
    service_account[sa_len - 1] = '\0';

    return 1;
}

int k8s_validate_token(const char *token, k8s_token_info_t *info, const k8s_config_t *config) {
    CURL *curl = NULL;
    CURLcode res;
    int result = 0;
    response_buffer_t response = {NULL, 0};
    struct curl_slist *headers = NULL;
    char *service_account_token = NULL;
    json_object *request_obj = NULL;
    json_object *response_obj = NULL;

    /* Input validation */
    if (!token || !info) {
        fprintf(stderr, "K8s Auth: Invalid input parameters\n");
        return 0;
    }

    /* Initialize info structure */
    memset(info, 0, sizeof(k8s_token_info_t));

    /* Use default config if not provided */
    k8s_config_t default_config;
    if (!config) {
        k8s_config_init_default(&default_config);
        config = &default_config;
    }

    /* Initialize libcurl */
    curl = curl_easy_init();
    if (!curl) {
        fprintf(stderr, "K8s Auth: Failed to initialize curl\n");
        return 0;
    }

    /* Build TokenReview request JSON */
    request_obj = json_object_new_object();
    json_object *spec_obj = json_object_new_object();

    json_object_object_add(request_obj, "apiVersion",
                          json_object_new_string("authentication.k8s.io/v1"));
    json_object_object_add(request_obj, "kind",
                          json_object_new_string("TokenReview"));
    json_object_object_add(spec_obj, "token", json_object_new_string(token));
    json_object_object_add(request_obj, "spec", spec_obj);

    const char *request_json = json_object_to_json_string(request_obj);

    /* Read service account token for authentication */
    service_account_token = read_file(config->token_path);
    if (!service_account_token) {
        fprintf(stderr, "K8s Auth: Failed to read service account token from %s\n",
                config->token_path);
        goto cleanup;
    }

    /* Set up HTTP headers */
    headers = curl_slist_append(headers, "Content-Type: application/json");

    char auth_header[4096];
    snprintf(auth_header, sizeof(auth_header), "Authorization: Bearer %s",
             service_account_token);
    headers = curl_slist_append(headers, auth_header);

    /* Build TokenReview API URL */
    char api_url[1024];
    snprintf(api_url, sizeof(api_url),
             "%s/apis/authentication.k8s.io/v1/tokenreviews",
             config->api_server_url);

    /* Configure curl options */
    curl_easy_setopt(curl, CURLOPT_URL, api_url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, request_json);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, config->timeout_seconds);

    /* SSL/TLS configuration */
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_CAINFO, config->ca_cert_path);

    /* Perform the request */
    fprintf(stderr, "K8s Auth: Calling TokenReview API at %s\n", api_url);
    res = curl_easy_perform(curl);

    if (res != CURLE_OK) {
        fprintf(stderr, "K8s Auth: TokenReview API call failed: %s\n",
                curl_easy_strerror(res));
        goto cleanup;
    }

    /* Check HTTP response code */
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    if (http_code != 201 && http_code != 200) {
        fprintf(stderr, "K8s Auth: TokenReview API returned HTTP %ld\n", http_code);
        if (response.data) {
            fprintf(stderr, "K8s Auth: Response: %s\n", response.data);
        }
        goto cleanup;
    }

    /* Parse JSON response */
    response_obj = json_tokener_parse(response.data);
    if (!response_obj) {
        fprintf(stderr, "K8s Auth: Failed to parse TokenReview response\n");
        goto cleanup;
    }

    /* Extract status.authenticated */
    json_object *status_obj = NULL;
    if (!json_object_object_get_ex(response_obj, "status", &status_obj)) {
        fprintf(stderr, "K8s Auth: No 'status' field in TokenReview response\n");
        goto cleanup;
    }

    json_object *authenticated_obj = NULL;
    if (!json_object_object_get_ex(status_obj, "authenticated", &authenticated_obj)) {
        fprintf(stderr, "K8s Auth: No 'authenticated' field in TokenReview response\n");
        goto cleanup;
    }

    info->authenticated = json_object_get_boolean(authenticated_obj);

    if (!info->authenticated) {
        fprintf(stderr, "K8s Auth: Token authentication failed\n");
        goto cleanup;
    }

    /* Extract user information */
    json_object *user_obj = NULL;
    if (!json_object_object_get_ex(status_obj, "user", &user_obj)) {
        fprintf(stderr, "K8s Auth: No 'user' field in TokenReview response\n");
        goto cleanup;
    }

    /* Extract username */
    json_object *username_obj = NULL;
    if (json_object_object_get_ex(user_obj, "username", &username_obj)) {
        const char *username = json_object_get_string(username_obj);
        strncpy(info->username, username, sizeof(info->username) - 1);

        /* Parse namespace and service account from username */
        if (!k8s_parse_username(username, info->namespace, sizeof(info->namespace),
                               info->service_account, sizeof(info->service_account))) {
            fprintf(stderr, "K8s Auth: Failed to parse username: %s\n", username);
            goto cleanup;
        }

        fprintf(stderr, "K8s Auth: Token validated successfully\n");
        fprintf(stderr, "K8s Auth: Username: %s\n", info->username);
        fprintf(stderr, "K8s Auth: Namespace: %s\n", info->namespace);
        fprintf(stderr, "K8s Auth: ServiceAccount: %s\n", info->service_account);
    }

    /* Extract UID */
    json_object *uid_obj = NULL;
    if (json_object_object_get_ex(user_obj, "uid", &uid_obj)) {
        const char *uid = json_object_get_string(uid_obj);
        strncpy(info->uid, uid, sizeof(info->uid) - 1);
    }

    info->validated_at = time(NULL);
    result = 1;

cleanup:
    if (curl) {
        curl_easy_cleanup(curl);
    }
    if (headers) {
        curl_slist_free_all(headers);
    }
    if (response.data) {
        free(response.data);
    }
    if (service_account_token) {
        free(service_account_token);
    }
    if (request_obj) {
        json_object_put(request_obj);
    }
    if (response_obj) {
        json_object_put(response_obj);
    }

    return result;
}
