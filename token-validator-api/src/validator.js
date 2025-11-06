const { jwtVerify, decodeJwt, createRemoteJWKSet } = require('jose');
const OIDCDiscovery = require('./oidc-discovery');
const JWKSCache = require('./jwks-cache');

/**
 * JWT Token Validator
 */
class TokenValidator {
  constructor(clusterConfig) {
    this.clusterConfig = clusterConfig;
    this.oidcDiscovery = new OIDCDiscovery();
    this.jwksCache = new JWKSCache();
  }

  /**
   * Validate token and return authentication result
   * @param {string} clusterName - Cluster name from username
   * @param {string} token - JWT token to validate
   * @returns {Promise<object>} Authentication result
   */
  async validateToken(clusterName, token) {
    try {
      // Get cluster configuration
      const cluster = this.clusterConfig.getCluster(clusterName);
      if (!cluster) {
        return {
          authenticated: false,
          error: 'cluster_not_found',
          message: `No configuration found for cluster: ${clusterName}`
        };
      }

      // Decode token to inspect claims (without verification)
      let decoded;
      try {
        decoded = decodeJwt(token);
      } catch (error) {
        return {
          authenticated: false,
          error: 'invalid_token',
          message: `Failed to decode JWT: ${error.message}`
        };
      }

      // Check token expiration
      if (decoded.exp && decoded.exp < Math.floor(Date.now() / 1000)) {
        return {
          authenticated: false,
          error: 'token_expired',
          message: 'Token has expired'
        };
      }

      // Check issuer (warn if mismatch, but don't reject)
      if (cluster.issuer && decoded.iss !== cluster.issuer) {
        console.warn(`[Validator] Issuer mismatch for cluster ${clusterName}: expected ${cluster.issuer}, got ${decoded.iss}`);
      }

      // Get OIDC configuration
      const oidcConfig = await this.oidcDiscovery.getConfiguration(decoded.iss || cluster.issuer, cluster);

      // Get JWKS
      const jwks = await this.jwksCache.getJWKS(oidcConfig.jwks_uri, cluster);

      // Create JWKS getter for jose
      const getKey = async (protectedHeader, token) => {
        const kid = protectedHeader.kid;
        if (!kid) {
          throw new Error('Token missing kid in header');
        }

        const key = jwks.find(k => k.kid === kid);
        if (!key) {
          throw new Error(`No key found for kid: ${kid}`);
        }

        return key;
      };

      // Verify token signature
      let verified;
      try {
        verified = await jwtVerify(token, getKey, {
          issuer: decoded.iss,
          // Don't validate audience for Kubernetes tokens (they may not have aud)
        });
      } catch (error) {
        return {
          authenticated: false,
          error: 'invalid_signature',
          message: `Token signature verification failed: ${error.message}`
        };
      }

      // Extract username from token claims
      const username = this.extractUsername(clusterName, verified.payload);

      return {
        authenticated: true,
        username: username,
        expiration: verified.payload.exp || null
      };
    } catch (error) {
      console.error('[Validator] Validation error:', error);
      return {
        authenticated: false,
        error: 'internal_error',
        message: `Unexpected error during validation: ${error.message}`
      };
    }
  }

  /**
   * Extract username from JWT claims
   * Format: cluster_name/namespace/serviceaccount
   */
  extractUsername(clusterName, payload) {
    // Kubernetes ServiceAccount tokens have standard claims
    const namespace = payload['kubernetes.io/serviceaccount/namespace'];
    const serviceAccount = payload['kubernetes.io/serviceaccount/service-account.name'];

    if (namespace && serviceAccount) {
      return `${clusterName}/${namespace}/${serviceAccount}`;
    }

    // Fallback to subject claim
    if (payload.sub) {
      // Subject format is typically: system:serviceaccount:namespace:name
      const match = payload.sub.match(/^system:serviceaccount:([^:]+):([^:]+)$/);
      if (match) {
        return `${clusterName}/${match[1]}/${match[2]}`;
      }

      // Use subject as-is if no match
      return `${clusterName}/${payload.sub}`;
    }

    throw new Error('Unable to extract username from token claims');
  }
}

module.exports = TokenValidator;
