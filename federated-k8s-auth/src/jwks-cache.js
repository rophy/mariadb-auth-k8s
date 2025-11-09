const axios = require('axios');
const https = require('https');
const fs = require('fs');

/**
 * JWKS cache with TTL and automatic refresh
 */
class JWKSCache {
  constructor(ttl = 3600 * 1000) { // Default 1 hour
    this.cache = new Map();
    this.ttl = ttl;
  }

  /**
   * Get JWKS from cache or fetch if expired
   * @param {string} jwksUri - JWKS endpoint URL
   * @param {object} cluster - Cluster configuration (for custom CA)
   */
  async getJWKS(jwksUri, cluster = null) {
    const cached = this.cache.get(jwksUri);

    // Return cached if not expired
    if (cached && Date.now() < cached.expiresAt) {
      return cached.keys;
    }

    // Fetch fresh JWKS
    const keys = await this.fetchJWKS(jwksUri, cluster);

    // Cache with TTL
    this.cache.set(jwksUri, {
      keys,
      expiresAt: Date.now() + this.ttl
    });

    return keys;
  }

  /**
   * Fetch JWKS from endpoint
   */
  async fetchJWKS(jwksUri, cluster = null) {
    try {
      const axiosConfig = {
        timeout: 10000,
        headers: {
          'Accept': 'application/json, application/jwk-set+json'
        }
      };

      // Add custom CA cert if provided
      if (cluster && cluster.ca_cert_path && fs.existsSync(cluster.ca_cert_path)) {
        const ca = fs.readFileSync(cluster.ca_cert_path, 'utf8');
        axiosConfig.httpsAgent = new https.Agent({
          ca: ca,
          rejectUnauthorized: true
        });
      }

      // Add bearer token if provided
      if (cluster && cluster.token_path && fs.existsSync(cluster.token_path)) {
        const token = fs.readFileSync(cluster.token_path, 'utf8').trim();
        axiosConfig.headers['Authorization'] = `Bearer ${token}`;
      }

      const response = await axios.get(jwksUri, axiosConfig);

      if (!response.data || !response.data.keys) {
        throw new Error('Invalid JWKS response: missing keys array');
      }

      console.log(`[JWKSCache] Fetched JWKS from ${jwksUri}: ${response.data.keys.length} keys`);
      return response.data.keys;
    } catch (error) {
      console.error(`[JWKSCache] Failed to fetch JWKS from ${jwksUri}:`, error.message);
      throw new Error(`jwks_fetch_failed: ${error.message}`);
    }
  }

  /**
   * Clear cache entry
   */
  invalidate(jwksUri) {
    this.cache.delete(jwksUri);
  }

  /**
   * Clear all cache
   */
  clear() {
    this.cache.clear();
  }

  /**
   * Get cache size
   */
  size() {
    return this.cache.size;
  }
}

module.exports = JWKSCache;
