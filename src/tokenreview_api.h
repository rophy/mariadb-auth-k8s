/*
 * Kubernetes TokenReview API Client
 *
 * This module provides functionality to validate Kubernetes ServiceAccount
 * tokens using the TokenReview API.
 */

#ifndef K8S_TOKEN_VALIDATOR_H
#define K8S_TOKEN_VALIDATOR_H

#include <time.h>

/* Maximum lengths for token info fields */
#define K8S_MAX_NAMESPACE_LEN 253
#define K8S_MAX_NAME_LEN 253
#define K8S_MAX_USERNAME_LEN 512
#define K8S_MAX_UID_LEN 128

/**
 * Structure to hold validated token information
 */
typedef struct {
    int authenticated;                          /* 1 if token is valid, 0 otherwise */
    char namespace[K8S_MAX_NAMESPACE_LEN + 1]; /* ServiceAccount namespace */
    char service_account[K8S_MAX_NAME_LEN + 1]; /* ServiceAccount name */
    char username[K8S_MAX_USERNAME_LEN + 1];    /* Full username from K8s */
    char uid[K8S_MAX_UID_LEN + 1];             /* User UID */
    time_t validated_at;                        /* Timestamp of validation */
} k8s_token_info_t;

/**
 * Configuration for Kubernetes API access
 */
typedef struct {
    const char *api_server_url;  /* K8s API server URL (default: https://kubernetes.default.svc) */
    const char *ca_cert_path;    /* Path to CA certificate (default: /var/run/secrets/.../ca.crt) */
    const char *token_path;      /* Path to service account token for auth (default: /var/run/.../token) */
    int timeout_seconds;         /* HTTP timeout (default: 10) */
} k8s_config_t;

/**
 * Initialize Kubernetes token validator with default configuration
 *
 * @param config Configuration structure to initialize
 */
void k8s_config_init_default(k8s_config_t *config);

/**
 * Validate a Kubernetes ServiceAccount token using TokenReview API
 *
 * This function calls the Kubernetes TokenReview API to validate the provided
 * token and extract ServiceAccount information.
 *
 * @param token The JWT token to validate
 * @param info Output structure to store token information
 * @param config Configuration for K8s API access (can be NULL for defaults)
 * @return 1 if validation successful, 0 if failed or invalid
 */
int k8s_validate_token(const char *token, k8s_token_info_t *info, const k8s_config_t *config);

/**
 * Parse namespace and service account from Kubernetes username
 *
 * Kubernetes usernames have the format:
 * system:serviceaccount:namespace:serviceaccount-name
 *
 * @param username The full username from TokenReview
 * @param namespace Output buffer for namespace
 * @param namespace_len Size of namespace buffer
 * @param service_account Output buffer for service account name
 * @param sa_len Size of service account buffer
 * @return 1 if successfully parsed, 0 otherwise
 */
int k8s_parse_username(const char *username, char *namespace, size_t namespace_len,
                       char *service_account, size_t sa_len);

#endif /* K8S_TOKEN_VALIDATOR_H */
