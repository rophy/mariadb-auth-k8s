/*
 * Kubernetes JWT Token Validator
 *
 * Validates Kubernetes ServiceAccount JWT tokens using OIDC discovery
 * and cryptographic signature verification (no TokenReview API needed).
 */

#ifndef K8S_JWT_VALIDATOR_H
#define K8S_JWT_VALIDATOR_H

#include <time.h>

/* Maximum lengths for various fields */
#define K8S_MAX_ISSUER_LEN 256
#define K8S_MAX_NAMESPACE_LEN 128
#define K8S_MAX_NAME_LEN 128
#define K8S_MAX_USERNAME_LEN 256
#define K8S_MAX_AUDIENCE_LEN 256
#define K8S_MAX_KEY_ID_LEN 64

/* JWKS key cache entry */
typedef struct k8s_jwks_key {
    char kid[K8S_MAX_KEY_ID_LEN];       /* Key ID */
    char *public_key_pem;               /* PEM-formatted public key */
    time_t cached_at;                   /* When this key was cached */
    struct k8s_jwks_key *next;          /* Linked list */
} k8s_jwks_key_t;

/* Single cluster configuration (local cluster only) */
typedef struct k8s_cluster_config {
    char name[K8S_MAX_NAME_LEN];        /* Cluster name for logging */
    char issuer[K8S_MAX_ISSUER_LEN];    /* Expected issuer URL */
    char api_server[K8S_MAX_ISSUER_LEN]; /* Kubernetes API server URL */
    char *ca_cert_path;                 /* Path to CA certificate */
    char *token_path;                   /* Path to ServiceAccount token for API access */
    char *auth_token;                   /* Cached token for API requests */

    /* OIDC endpoints (discovered dynamically) */
    char *oidc_discovery_url;           /* /.well-known/openid-configuration */
    char *jwks_uri;                     /* JWKS endpoint URL */

    /* Cached JWKS keys */
    k8s_jwks_key_t *keys;               /* Linked list of cached keys */
    time_t keys_cached_at;              /* When keys were last fetched */
    time_t keys_ttl;                    /* Cache TTL in seconds (default: 3600) */
} k8s_cluster_config_t;

/* Token validation result */
typedef struct {
    int authenticated;                  /* 1 if token is valid, 0 otherwise */
    char username[K8S_MAX_USERNAME_LEN]; /* Full username from 'sub' claim */
    char namespace[K8S_MAX_NAMESPACE_LEN]; /* Extracted namespace */
    char service_account[K8S_MAX_NAME_LEN]; /* Extracted service account name */
    char issuer[K8S_MAX_ISSUER_LEN];    /* Token issuer */
    time_t expiration;                  /* Token expiration time */
} k8s_jwt_token_info_t;

/*
 * Initialize JWT validator for local cluster
 *
 * Automatically configures the local Kubernetes cluster using the pod's
 * mounted ServiceAccount credentials.
 *
 * @return 0 on success, -1 on error
 */
int k8s_jwt_validator_init(void);

/*
 * Validate a JWT token from the local cluster
 *
 * This function:
 * 1. Parses the JWT to extract the issuer
 * 2. Fetches JWKS keys if needed (with caching)
 * 3. Verifies the JWT signature using cached public keys
 * 4. Validates JWT claims (issuer, audience, expiration)
 * 5. Extracts identity information from the token
 *
 * @param token JWT token string
 * @param token_info Output: token validation result
 * @param error_msg Output: error message if validation fails (can be NULL)
 * @return 1 if token is valid, 0 otherwise
 */
int k8s_jwt_validate_token(
    const char *token,
    k8s_jwt_token_info_t *token_info,
    char *error_msg
);

/*
 * Discover OIDC configuration for the local cluster
 *
 * Fetches /.well-known/openid-configuration and updates the cluster config
 * with jwks_uri and other OIDC metadata.
 *
 * @return 0 on success, -1 on error
 */
int k8s_jwt_discover_oidc(void);

/*
 * Fetch and cache JWKS keys for the local cluster
 *
 * @param force_refresh If 1, refresh even if cache is valid
 * @return 0 on success, -1 on error
 */
int k8s_jwt_fetch_jwks(int force_refresh);

/*
 * Clean up resources
 */
void k8s_jwt_validator_cleanup(void);

#endif /* K8S_JWT_VALIDATOR_H */
