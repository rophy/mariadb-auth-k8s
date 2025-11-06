/*
 * Kubernetes JWT Token Validator
 *
 * Validates Kubernetes ServiceAccount JWT tokens using OIDC discovery
 * and cryptographic signature verification.
 */

#include "jwt_crypto.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <curl/curl.h>
#include <json-c/json.h>
#include <openssl/bio.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rsa.h>
#include <openssl/bn.h>
#include <openssl/err.h>

/* Global configuration for local cluster only */
static k8s_cluster_config_t g_local_cluster;
static int g_initialized = 0;

/* Default cache TTL: 1 hour */
#define DEFAULT_JWKS_TTL 3600

/* Forward declarations */
static int base64url_decode(const char *src, size_t src_len, char **out, size_t *out_len);

/* Memory buffer for curl responses */
typedef struct {
    char *data;
    size_t size;
} curl_response_t;

/*
 * Curl write callback
 */
static size_t jwt_curl_write_cb(void *contents, size_t size, size_t nmemb, void *userp)
{
    size_t realsize = size * nmemb;
    curl_response_t *response = (curl_response_t *)userp;

    char *ptr = realloc(response->data, response->size + realsize + 1);
    if (!ptr) {
        fprintf(stderr, "JWT Validator: Out of memory\n");
        return 0;
    }

    response->data = ptr;
    memcpy(&(response->data[response->size]), contents, realsize);
    response->size += realsize;
    response->data[response->size] = 0;

    return realsize;
}

/*
 * Make HTTP GET request
 */
static int http_get(const char *url, const char *ca_cert_path, const char *auth_token, curl_response_t *response)
{
    CURL *curl;
    CURLcode res;
    long http_code = 0;
    struct curl_slist *headers = NULL;

    response->data = malloc(1);
    response->size = 0;

    curl = curl_easy_init();
    if (!curl) {
        fprintf(stderr, "JWT Validator: Failed to initialize curl\n");
        return -1;
    }

    /* Add Authorization header if token provided */
    if (auth_token) {
        char auth_header[2048];
        snprintf(auth_header, sizeof(auth_header), "Authorization: Bearer %s", auth_token);
        headers = curl_slist_append(headers, auth_header);
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, jwt_curl_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, (void *)response);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "mariadb-auth-k8s/1.0");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 10L);

    if (ca_cert_path) {
        curl_easy_setopt(curl, CURLOPT_CAINFO, ca_cert_path);
    }

    res = curl_easy_perform(curl);

    if (headers) {
        curl_slist_free_all(headers);
    }

    if (res != CURLE_OK) {
        fprintf(stderr, "JWT Validator: curl_easy_perform() failed: %s\n",
                curl_easy_strerror(res));
        curl_easy_cleanup(curl);
        free(response->data);
        response->data = NULL;
        return -1;
    }

    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    curl_easy_cleanup(curl);

    if (http_code != 200) {
        fprintf(stderr, "JWT Validator: HTTP error %ld\n", http_code);
        free(response->data);
        response->data = NULL;
        return -1;
    }

    return 0;
}

/*
 * Discover OIDC configuration for local cluster
 */
int k8s_jwt_discover_oidc(void)
{
    char url[512];
    curl_response_t response = {0};
    struct json_object *root = NULL;
    struct json_object *jwks_uri_obj = NULL;
    const char *jwks_uri = NULL;

    /* Build OIDC discovery URL */
    snprintf(url, sizeof(url), "%s/.well-known/openid-configuration", g_local_cluster.api_server);

    fprintf(stderr, "JWT Validator: Discovering OIDC config from %s\n", url);

    if (http_get(url, g_local_cluster.ca_cert_path, g_local_cluster.auth_token, &response) != 0) {
        fprintf(stderr, "JWT Validator: Failed to fetch OIDC discovery document\n");
        return -1;
    }

    /* Parse JSON response */
    root = json_tokener_parse(response.data);
    free(response.data);

    if (!root) {
        fprintf(stderr, "JWT Validator: Failed to parse OIDC discovery JSON\n");
        return -1;
    }

    /* Extract jwks_uri */
    if (!json_object_object_get_ex(root, "jwks_uri", &jwks_uri_obj)) {
        fprintf(stderr, "JWT Validator: No jwks_uri in OIDC discovery\n");
        json_object_put(root);
        return -1;
    }

    jwks_uri = json_object_get_string(jwks_uri_obj);
    if (!jwks_uri) {
        fprintf(stderr, "JWT Validator: Invalid jwks_uri\n");
        json_object_put(root);
        return -1;
    }

    /* Store jwks_uri */
    g_local_cluster.jwks_uri = strdup(jwks_uri);

    fprintf(stderr, "JWT Validator: JWKS URI: %s\n", g_local_cluster.jwks_uri);

    json_object_put(root);
    return 0;
}

/*
 * Convert JWK to PEM format using OpenSSL
 */
static char *jwk_to_pem(struct json_object *jwk)
{
    struct json_object *n_obj, *e_obj, *kty_obj;
    const char *n_b64, *e_b64, *kty;
    char *pem_str = NULL;
    BIO *bio = NULL;
    EVP_PKEY *pkey = NULL;
    RSA *rsa = NULL;
    BIGNUM *bn_n = NULL, *bn_e = NULL;
    char *n_bytes = NULL, *e_bytes = NULL;
    size_t n_len, e_len;

    /* Extract key type */
    if (!json_object_object_get_ex(jwk, "kty", &kty_obj)) {
        return NULL;
    }
    kty = json_object_get_string(kty_obj);
    if (strcmp(kty, "RSA") != 0) {
        fprintf(stderr, "JWT Validator: Unsupported key type: %s\n", kty);
        return NULL;
    }

    /* Extract n and e */
    if (!json_object_object_get_ex(jwk, "n", &n_obj) ||
        !json_object_object_get_ex(jwk, "e", &e_obj)) {
        fprintf(stderr, "JWT Validator: Missing n or e in JWK\n");
        return NULL;
    }

    n_b64 = json_object_get_string(n_obj);
    e_b64 = json_object_get_string(e_obj);

    /* Decode base64url n and e */
    if (base64url_decode(n_b64, strlen(n_b64), &n_bytes, &n_len) != 0) {
        fprintf(stderr, "JWT Validator: Failed to decode n\n");
        goto cleanup;
    }

    if (base64url_decode(e_b64, strlen(e_b64), &e_bytes, &e_len) != 0) {
        fprintf(stderr, "JWT Validator: Failed to decode e\n");
        goto cleanup;
    }

    /* Create BIGNUMs from decoded bytes */
    bn_n = BN_bin2bn((unsigned char *)n_bytes, n_len, NULL);
    bn_e = BN_bin2bn((unsigned char *)e_bytes, e_len, NULL);

    if (!bn_n || !bn_e) {
        fprintf(stderr, "JWT Validator: Failed to create BIGNUMs\n");
        goto cleanup;
    }

    /* Create RSA key and set public key components */
    rsa = RSA_new();
    if (!rsa) {
        fprintf(stderr, "JWT Validator: Failed to create RSA key\n");
        goto cleanup;
    }

    /* Set n and e (RSA_set0_key takes ownership of BIGNUMs) */
    if (RSA_set0_key(rsa, bn_n, bn_e, NULL) != 1) {
        fprintf(stderr, "JWT Validator: Failed to set RSA key\n");
        goto cleanup;
    }
    bn_n = NULL;  /* Ownership transferred */
    bn_e = NULL;  /* Ownership transferred */

    /* Create EVP_PKEY and assign RSA key */
    pkey = EVP_PKEY_new();
    if (!pkey) {
        fprintf(stderr, "JWT Validator: Failed to create EVP_PKEY\n");
        goto cleanup;
    }

    if (EVP_PKEY_assign_RSA(pkey, rsa) != 1) {
        fprintf(stderr, "JWT Validator: Failed to assign RSA to EVP_PKEY\n");
        goto cleanup;
    }
    rsa = NULL;  /* Ownership transferred */

    /* Write PEM to memory BIO */
    bio = BIO_new(BIO_s_mem());
    if (!bio) {
        fprintf(stderr, "JWT Validator: Failed to create BIO\n");
        goto cleanup;
    }

    if (PEM_write_bio_PUBKEY(bio, pkey) != 1) {
        fprintf(stderr, "JWT Validator: Failed to write PEM\n");
        goto cleanup;
    }

    /* Read PEM string from BIO */
    long pem_len = BIO_get_mem_data(bio, &pem_str);
    if (pem_len > 0) {
        char *pem_copy = malloc(pem_len + 1);
        if (pem_copy) {
            memcpy(pem_copy, pem_str, pem_len);
            pem_copy[pem_len] = '\0';
            pem_str = pem_copy;
        } else {
            pem_str = NULL;
        }
    } else {
        pem_str = NULL;
    }

cleanup:
    if (bn_n) BN_free(bn_n);
    if (bn_e) BN_free(bn_e);
    if (rsa) RSA_free(rsa);
    if (pkey) EVP_PKEY_free(pkey);
    if (bio) BIO_free(bio);
    free(n_bytes);
    free(e_bytes);

    return pem_str;
}

/*
 * Fetch JWKS keys for local cluster
 */
int k8s_jwt_fetch_jwks(int force_refresh)
{
    curl_response_t response = {0};
    struct json_object *root = NULL, *keys_array = NULL;
    time_t now = time(NULL);

    /* Check cache validity */
    if (!force_refresh && g_local_cluster.keys) {
        if ((now - g_local_cluster.keys_cached_at) < g_local_cluster.keys_ttl) {
            fprintf(stderr, "JWT Validator: Using cached JWKS keys\n");
            return 0;
        }
    }

    /* Discover OIDC if not done yet */
    if (!g_local_cluster.jwks_uri) {
        if (k8s_jwt_discover_oidc() != 0) {
            return -1;
        }
    }

    fprintf(stderr, "JWT Validator: Fetching JWKS from %s\n", g_local_cluster.jwks_uri);

    if (http_get(g_local_cluster.jwks_uri, g_local_cluster.ca_cert_path, g_local_cluster.auth_token, &response) != 0) {
        fprintf(stderr, "JWT Validator: Failed to fetch JWKS\n");
        return -1;
    }

    /* Parse JSON response */
    root = json_tokener_parse(response.data);
    free(response.data);

    if (!root) {
        fprintf(stderr, "JWT Validator: Failed to parse JWKS JSON\n");
        return -1;
    }

    /* Extract keys array */
    if (!json_object_object_get_ex(root, "keys", &keys_array)) {
        fprintf(stderr, "JWT Validator: No keys in JWKS\n");
        json_object_put(root);
        return -1;
    }

    /* Free old keys */
    k8s_jwks_key_t *key = g_local_cluster.keys;
    while (key) {
        k8s_jwks_key_t *next = key->next;
        free(key->public_key_pem);
        free(key);
        key = next;
    }
    g_local_cluster.keys = NULL;

    /* Parse and cache new keys */
    int num_keys = json_object_array_length(keys_array);
    fprintf(stderr, "JWT Validator: Found %d keys in JWKS\n", num_keys);

    for (int i = 0; i < num_keys; i++) {
        struct json_object *jwk = json_object_array_get_idx(keys_array, i);
        struct json_object *kid_obj;
        const char *kid;

        if (!json_object_object_get_ex(jwk, "kid", &kid_obj)) {
            continue;
        }

        kid = json_object_get_string(kid_obj);
        char *pem = jwk_to_pem(jwk);
        if (!pem) {
            fprintf(stderr, "JWT Validator: Failed to convert JWK to PEM for kid: %s\n", kid);
            continue;
        }

        /* Create new key entry */
        k8s_jwks_key_t *new_key = malloc(sizeof(k8s_jwks_key_t));
        strncpy(new_key->kid, kid, K8S_MAX_KEY_ID_LEN - 1);
        new_key->kid[K8S_MAX_KEY_ID_LEN - 1] = '\0';
        new_key->public_key_pem = pem;
        new_key->cached_at = now;
        new_key->next = g_local_cluster.keys;
        g_local_cluster.keys = new_key;

        fprintf(stderr, "JWT Validator: Cached key: %s\n", kid);
        fprintf(stderr, "JWT Validator: PEM (first 100 chars): %.100s\n", pem);
    }

    g_local_cluster.keys_cached_at = now;
    json_object_put(root);

    return 0;
}

/*
 * Extract namespace and serviceaccount from subject
 * Expected format: system:serviceaccount:namespace:serviceaccount
 */
static int parse_subject(const char *subject, char *namespace, char *sa_name)
{
    const char *prefix = "system:serviceaccount:";
    if (strncmp(subject, prefix, strlen(prefix)) != 0) {
        return -1;
    }

    const char *rest = subject + strlen(prefix);
    const char *colon = strchr(rest, ':');
    if (!colon) {
        return -1;
    }

    size_t ns_len = colon - rest;
    if (ns_len >= K8S_MAX_NAMESPACE_LEN) {
        return -1;
    }

    strncpy(namespace, rest, ns_len);
    namespace[ns_len] = '\0';

    const char *sa = colon + 1;
    strncpy(sa_name, sa, K8S_MAX_NAME_LEN - 1);
    sa_name[K8S_MAX_NAME_LEN - 1] = '\0';

    return 0;
}

/*
 * Base64 decode table
 */
static const unsigned char base64_decode_table[256] = {
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 62, 64, 64, 64, 63,
    52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 64, 64, 64, 64, 64, 64,
    64,  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14,
    15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 64, 64, 64, 64, 64,
    64, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40,
    41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64
};

/*
 * Simple base64 decoder
 */
static int base64_decode_simple(const char *src, size_t src_len, unsigned char *out, size_t *out_len)
{
    size_t i = 0, j = 0;
    unsigned char buf[4];
    size_t buf_pos = 0;

    for (i = 0; i < src_len; i++) {
        if (src[i] == '=') break;

        unsigned char c = base64_decode_table[(unsigned char)src[i]];
        if (c == 64) continue; /* Skip invalid chars */

        buf[buf_pos++] = c;

        if (buf_pos == 4) {
            out[j++] = (buf[0] << 2) | (buf[1] >> 4);
            out[j++] = (buf[1] << 4) | (buf[2] >> 2);
            out[j++] = (buf[2] << 6) | buf[3];
            buf_pos = 0;
        }
    }

    /* Handle remaining bytes */
    if (buf_pos >= 2) {
        out[j++] = (buf[0] << 2) | (buf[1] >> 4);
        if (buf_pos >= 3) {
            out[j++] = (buf[1] << 4) | (buf[2] >> 2);
        }
    }

    *out_len = j;
    return 0;
}

/*
 * Base64 decode helper (URL-safe base64)
 */
static int base64url_decode(const char *src, size_t src_len, char **out, size_t *out_len)
{
    /* Simple base64url decode - convert to standard base64 first */
    char *b64 = malloc(src_len + 4);
    if (!b64) return -1;

    /* Replace URL-safe chars with standard base64 */
    for (size_t i = 0; i < src_len; i++) {
        if (src[i] == '-') b64[i] = '+';
        else if (src[i] == '_') b64[i] = '/';
        else b64[i] = src[i];
    }

    /* Add padding if needed */
    size_t padding = (4 - (src_len % 4)) % 4;
    for (size_t i = 0; i < padding; i++) {
        b64[src_len + i] = '=';
    }
    b64[src_len + padding] = '\0';

    /* Decode using simple decoder */
    size_t max_len = (src_len * 3) / 4 + 4;
    *out = malloc(max_len);
    if (!*out) {
        free(b64);
        return -1;
    }

    int ret = base64_decode_simple(b64, strlen(b64), (unsigned char *)*out, out_len);
    free(b64);

    if (ret < 0) {
        free(*out);
        *out = NULL;
        return -1;
    }

    (*out)[*out_len] = '\0';
    return 0;
}

/*
 * Parse JWT header and payload without verification
 * Returns issuer and kid from token
 */
static int parse_jwt_unverified(const char *token, char **issuer_out, char **kid_out)
{
    const char *dot1 = strchr(token, '.');
    if (!dot1) return -1;

    const char *dot2 = strchr(dot1 + 1, '.');
    if (!dot2) return -1;

    /* Decode header */
    size_t header_len = dot1 - token;
    char *header_json = NULL;
    size_t header_json_len;

    if (base64url_decode(token, header_len, &header_json, &header_json_len) != 0) {
        fprintf(stderr, "JWT Validator: Failed to decode JWT header\n");
        return -1;
    }

    /* Parse header JSON to get kid */
    struct json_object *header_obj = json_tokener_parse(header_json);
    free(header_json);

    if (!header_obj) {
        fprintf(stderr, "JWT Validator: Failed to parse JWT header JSON\n");
        return -1;
    }

    struct json_object *kid_obj;
    if (json_object_object_get_ex(header_obj, "kid", &kid_obj)) {
        const char *kid = json_object_get_string(kid_obj);
        if (kid) {
            *kid_out = strdup(kid);
        }
    }
    json_object_put(header_obj);

    /* Decode payload */
    size_t payload_len = dot2 - (dot1 + 1);
    char *payload_json = NULL;
    size_t payload_json_len;

    if (base64url_decode(dot1 + 1, payload_len, &payload_json, &payload_json_len) != 0) {
        fprintf(stderr, "JWT Validator: Failed to decode JWT payload\n");
        if (*kid_out) free(*kid_out);
        return -1;
    }

    /* Parse payload JSON to get issuer */
    struct json_object *payload_obj = json_tokener_parse(payload_json);
    free(payload_json);

    if (!payload_obj) {
        fprintf(stderr, "JWT Validator: Failed to parse JWT payload JSON\n");
        if (*kid_out) free(*kid_out);
        return -1;
    }

    struct json_object *iss_obj;
    if (json_object_object_get_ex(payload_obj, "iss", &iss_obj)) {
        const char *iss = json_object_get_string(iss_obj);
        if (iss) {
            *issuer_out = strdup(iss);
        }
    }
    json_object_put(payload_obj);

    if (!*issuer_out || !*kid_out) {
        if (*issuer_out) free(*issuer_out);
        if (*kid_out) free(*kid_out);
        return -1;
    }

    return 0;
}

/*
 * Verify JWT RS256 signature using OpenSSL
 */
static int verify_jwt_signature_rs256(const char *token, const char *pem_key)
{
    const char *dot1 = strchr(token, '.');
    if (!dot1) return -1;

    const char *dot2 = strchr(dot1 + 1, '.');
    if (!dot2) return -1;

    /* JWT format: header.payload.signature */
    size_t message_len = dot2 - token;  /* header.payload */
    const char *signature_b64 = dot2 + 1;

    /* Decode signature from base64url */
    char *signature_bytes = NULL;
    size_t signature_len;
    if (base64url_decode(signature_b64, strlen(signature_b64), &signature_bytes, &signature_len) != 0) {
        fprintf(stderr, "JWT Validator: Failed to decode signature\n");
        return -1;
    }

    /* Load PEM public key */
    BIO *bio = BIO_new_mem_buf(pem_key, -1);
    if (!bio) {
        fprintf(stderr, "JWT Validator: Failed to create BIO for PEM\n");
        free(signature_bytes);
        return -1;
    }

    EVP_PKEY *pkey = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
    BIO_free(bio);

    if (!pkey) {
        fprintf(stderr, "JWT Validator: Failed to read PEM public key\n");
        ERR_print_errors_fp(stderr);
        free(signature_bytes);
        return -1;
    }

    /* Create EVP_MD_CTX for verification */
    EVP_MD_CTX *md_ctx = EVP_MD_CTX_new();
    if (!md_ctx) {
        fprintf(stderr, "JWT Validator: Failed to create EVP_MD_CTX\n");
        EVP_PKEY_free(pkey);
        free(signature_bytes);
        return -1;
    }

    /* Initialize verification with SHA256 */
    if (EVP_DigestVerifyInit(md_ctx, NULL, EVP_sha256(), NULL, pkey) != 1) {
        fprintf(stderr, "JWT Validator: Failed to initialize digest verify\n");
        EVP_MD_CTX_free(md_ctx);
        EVP_PKEY_free(pkey);
        free(signature_bytes);
        return -1;
    }

    /* Update with message (header.payload) */
    if (EVP_DigestVerifyUpdate(md_ctx, token, message_len) != 1) {
        fprintf(stderr, "JWT Validator: Failed to update digest verify\n");
        EVP_MD_CTX_free(md_ctx);
        EVP_PKEY_free(pkey);
        free(signature_bytes);
        return -1;
    }

    /* Verify signature */
    int verify_result = EVP_DigestVerifyFinal(md_ctx, (unsigned char *)signature_bytes, signature_len);

    /* Cleanup */
    EVP_MD_CTX_free(md_ctx);
    EVP_PKEY_free(pkey);
    free(signature_bytes);

    if (verify_result == 1) {
        return 0;  /* Success */
    } else {
        fprintf(stderr, "JWT Validator: Signature verification failed (result=%d)\n", verify_result);
        ERR_print_errors_fp(stderr);
        return -1;
    }
}

/*
 * Validate JWT token
 */
int k8s_jwt_validate_token(
    const char *token,
    k8s_jwt_token_info_t *token_info,
    char *error_msg)
{
    char *issuer = NULL;
    char *kid = NULL;
    char *payload_json = NULL;
    size_t payload_len;
    struct json_object *payload_obj = NULL;
    const char *subject, *iss_claim;
    long exp_claim;

    memset(token_info, 0, sizeof(k8s_jwt_token_info_t));

    /* Parse JWT without verification first to get issuer and kid */
    if (parse_jwt_unverified(token, &issuer, &kid) != 0) {
        if (error_msg) {
            snprintf(error_msg, 256, "Failed to parse JWT");
        }
        fprintf(stderr, "JWT Validator: Failed to parse JWT\n");
        return 0;
    }

    fprintf(stderr, "JWT Validator: Token issuer: %s\n", issuer);
    fprintf(stderr, "JWT Validator: Token kid: %s\n", kid);

    /* Fetch JWKS keys if needed */
    if (k8s_jwt_fetch_jwks(0) != 0) {
        if (error_msg) {
            snprintf(error_msg, 256, "Failed to fetch JWKS");
        }
        free(issuer);
        free(kid);
        return 0;
    }

    /* Find matching key */
    k8s_jwks_key_t *key = g_local_cluster.keys;
    while (key) {
        if (strcmp(key->kid, kid) == 0) {
            break;
        }
        key = key->next;
    }

    if (!key) {
        if (error_msg) {
            snprintf(error_msg, 256, "Key not found: %s", kid);
        }
        fprintf(stderr, "JWT Validator: Key not found: %s\n", kid);
        free(issuer);
        free(kid);
        return 0;
    }

    /* Verify JWT signature using OpenSSL */
    fprintf(stderr, "JWT Validator: Verifying JWT signature with OpenSSL RSA-SHA256\n");

    if (verify_jwt_signature_rs256(token, key->public_key_pem) != 0) {
        if (error_msg) {
            snprintf(error_msg, 256, "JWT signature verification failed");
        }
        fprintf(stderr, "JWT Validator: Signature verification failed\n");
        free(issuer);
        free(kid);
        return 0;
    }

    fprintf(stderr, "JWT Validator: ✅ Signature verified successfully\n");

    /* Now decode the payload to extract claims */
    const char *dot1 = strchr(token, '.');
    const char *dot2 = strchr(dot1 + 1, '.');
    size_t payload_b64_len = dot2 - (dot1 + 1);

    if (base64url_decode(dot1 + 1, payload_b64_len, &payload_json, &payload_len) != 0) {
        if (error_msg) {
            snprintf(error_msg, 256, "Failed to decode payload");
        }
        free(issuer);
        free(kid);
        return 0;
    }

    payload_obj = json_tokener_parse(payload_json);
    free(payload_json);

    if (!payload_obj) {
        if (error_msg) {
            snprintf(error_msg, 256, "Failed to parse payload JSON");
        }
        free(issuer);
        free(kid);
        return 0;
    }

    /* Validate expiration */
    struct json_object *exp_obj;
    if (json_object_object_get_ex(payload_obj, "exp", &exp_obj)) {
        exp_claim = json_object_get_int64(exp_obj);
        if (exp_claim < time(NULL)) {
            if (error_msg) {
                snprintf(error_msg, 256, "Token expired");
            }
            fprintf(stderr, "JWT Validator: Token expired\n");
            json_object_put(payload_obj);
            free(issuer);
            free(kid);
            return 0;
        }
    } else {
        exp_claim = 0;
    }

    /* Extract subject */
    struct json_object *sub_obj;
    if (!json_object_object_get_ex(payload_obj, "sub", &sub_obj)) {
        if (error_msg) {
            snprintf(error_msg, 256, "No subject in JWT");
        }
        json_object_put(payload_obj);
        free(issuer);
        free(kid);
        return 0;
    }
    subject = json_object_get_string(sub_obj);

    /* Parse subject */
    if (parse_subject(subject, token_info->namespace, token_info->service_account) != 0) {
        if (error_msg) {
            snprintf(error_msg, 256, "Invalid subject format");
        }
        json_object_put(payload_obj);
        free(issuer);
        free(kid);
        return 0;
    }

    /* Fill in token info */
    token_info->authenticated = 1;
    strncpy(token_info->username, subject, K8S_MAX_USERNAME_LEN - 1);
    strncpy(token_info->issuer, issuer, K8S_MAX_ISSUER_LEN - 1);
    token_info->expiration = (time_t)exp_claim;

    fprintf(stderr, "JWT Validator: ✅ Token validated successfully\n");
    fprintf(stderr, "JWT Validator: Namespace: %s\n", token_info->namespace);
    fprintf(stderr, "JWT Validator: ServiceAccount: %s\n", token_info->service_account);

    /* Cleanup */
    json_object_put(payload_obj);
    free(issuer);
    free(kid);
    return 1;
}

/*
 * Load token from file
 */
static char *load_token_from_file(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "JWT Validator: Failed to open token file: %s\n", path);
        return NULL;
    }

    /* Get file size */
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (size <= 0 || size > 10000) {
        fprintf(stderr, "JWT Validator: Invalid token file size: %ld\n", size);
        fclose(f);
        return NULL;
    }

    char *token = malloc(size + 1);
    if (!token) {
        fclose(f);
        return NULL;
    }

    size_t read_size = fread(token, 1, size, f);
    fclose(f);

    token[read_size] = '\0';

    /* Trim whitespace */
    while (read_size > 0 && (token[read_size - 1] == '\n' || token[read_size - 1] == '\r' || token[read_size - 1] == ' ')) {
        token[--read_size] = '\0';
    }

    return token;
}

/*
 * Initialize JWT validator for local cluster
 * Auto-configures using pod's mounted ServiceAccount
 */
int jwt_crypto_init(void)
{
    if (g_initialized) {
        fprintf(stderr, "JWT Validator: Already initialized\n");
        return 0;
    }

    /* Initialize local cluster configuration */
    memset(&g_local_cluster, 0, sizeof(k8s_cluster_config_t));

    strncpy(g_local_cluster.name, "local", K8S_MAX_NAME_LEN - 1);
    strncpy(g_local_cluster.issuer, "https://kubernetes.default.svc.cluster.local", K8S_MAX_ISSUER_LEN - 1);
    strncpy(g_local_cluster.api_server, "https://kubernetes.default.svc", K8S_MAX_ISSUER_LEN - 1);

    g_local_cluster.ca_cert_path = strdup("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt");
    g_local_cluster.token_path = strdup("/var/run/secrets/kubernetes.io/serviceaccount/token");
    g_local_cluster.keys_ttl = DEFAULT_JWKS_TTL;
    g_local_cluster.keys = NULL;
    g_local_cluster.keys_cached_at = 0;
    g_local_cluster.jwks_uri = NULL;
    g_local_cluster.oidc_discovery_url = NULL;

    /* Load ServiceAccount token for API access */
    g_local_cluster.auth_token = load_token_from_file(g_local_cluster.token_path);
    if (!g_local_cluster.auth_token) {
        fprintf(stderr, "JWT Validator: Warning: Failed to load token from %s\n", g_local_cluster.token_path);
    }

    g_initialized = 1;
    fprintf(stderr, "JWT Validator: Initialized for local cluster\n");
    fprintf(stderr, "JWT Validator: API Server: %s\n", g_local_cluster.api_server);
    fprintf(stderr, "JWT Validator: Issuer: %s\n", g_local_cluster.issuer);

    return 0;
}

/*
 * Cleanup
 */
void jwt_crypto_cleanup(void)
{
    if (!g_initialized) {
        return;
    }

    /* Free JWKS keys */
    k8s_jwks_key_t *key = g_local_cluster.keys;
    while (key) {
        k8s_jwks_key_t *next = key->next;
        free(key->public_key_pem);
        free(key);
        key = next;
    }

    /* Free dynamically allocated strings */
    free(g_local_cluster.oidc_discovery_url);
    free(g_local_cluster.jwks_uri);
    free(g_local_cluster.ca_cert_path);
    free(g_local_cluster.token_path);
    free(g_local_cluster.auth_token);

    memset(&g_local_cluster, 0, sizeof(k8s_cluster_config_t));
    g_initialized = 0;

    fprintf(stderr, "JWT Validator: Cleaned up\n");
}
