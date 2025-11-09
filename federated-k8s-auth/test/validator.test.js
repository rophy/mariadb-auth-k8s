const ClusterConfig = require('../src/cluster-config');
const TokenValidator = require('../src/validator');
const { SignJWT, generateKeyPair } = require('jose');
const fs = require('fs');
const path = require('path');

describe('TokenValidator', () => {
  let clusterConfig;
  let validator;
  let keyPair;

  beforeAll(async () => {
    // Generate RSA key pair for testing
    keyPair = await generateKeyPair('RS256');
  });

  beforeEach(async () => {
    // Create mock cluster config
    clusterConfig = new ClusterConfig();
    clusterConfig.clusters.set('test-cluster', {
      name: 'test-cluster',
      api_server: 'https://test-api:6443'
    });

    validator = new TokenValidator(clusterConfig);
  });

  describe('extractUsername', () => {
    it('should extract username from Kubernetes ServiceAccount token claims', () => {
      const payload = {
        'kubernetes.io/serviceaccount/namespace': 'default',
        'kubernetes.io/serviceaccount/service-account.name': 'test-user'
      };

      const username = validator.extractUsername('test-cluster', payload);
      expect(username).toBe('test-cluster/default/test-user');
    });

    it('should extract username from subject claim with system:serviceaccount format', () => {
      const payload = {
        sub: 'system:serviceaccount:app-ns:user1'
      };

      const username = validator.extractUsername('test-cluster', payload);
      expect(username).toBe('test-cluster/app-ns/user1');
    });

    it('should use subject as-is if no match', () => {
      const payload = {
        sub: 'custom-user'
      };

      const username = validator.extractUsername('test-cluster', payload);
      expect(username).toBe('test-cluster/custom-user');
    });

    it('should throw error if no username can be extracted', () => {
      const payload = {};

      expect(() => validator.extractUsername('test-cluster', payload))
        .toThrow('Unable to extract username from token claims');
    });
  });

  describe('validateToken - basic checks', () => {
    it('should return cluster_not_found for unknown cluster', async () => {
      const result = await validator.validateToken('unknown-cluster', 'fake-token');

      expect(result.authenticated).toBe(false);
      expect(result.error).toBe('cluster_not_found');
    });

    it('should return invalid_token for malformed JWT', async () => {
      const result = await validator.validateToken('test-cluster', 'not-a-jwt');

      expect(result.authenticated).toBe(false);
      expect(result.error).toBe('invalid_token');
    });

    it('should return token_expired for expired token', async () => {
      // Create expired token
      const token = await new SignJWT({
        'kubernetes.io/serviceaccount/namespace': 'default',
        'kubernetes.io/serviceaccount/service-account.name': 'test-user',
        iss: 'https://kubernetes.test.local'
      })
        .setProtectedHeader({ alg: 'RS256', kid: 'test-key' })
        .setExpirationTime('1h ago')
        .sign(keyPair.privateKey);

      const result = await validator.validateToken('test-cluster', token);

      expect(result.authenticated).toBe(false);
      expect(result.error).toBe('token_expired');
    });
  });
});

describe('ClusterConfig', () => {
  let clusterConfig;

  beforeEach(() => {
    clusterConfig = new ClusterConfig();
  });

  describe('getCluster', () => {
    it('should return cluster by name', () => {
      clusterConfig.clusters.set('test', { name: 'test' });
      const cluster = clusterConfig.getCluster('test');
      expect(cluster).toEqual({ name: 'test' });
    });

    it('should return undefined for unknown cluster', () => {
      const cluster = clusterConfig.getCluster('unknown');
      expect(cluster).toBeUndefined();
    });
  });

  describe('listClusters', () => {
    it('should return list of cluster names', () => {
      clusterConfig.clusters.set('cluster1', { name: 'cluster1' });
      clusterConfig.clusters.set('cluster2', { name: 'cluster2' });

      const list = clusterConfig.listClusters();
      expect(list).toEqual(['cluster1', 'cluster2']);
    });
  });

  describe('count', () => {
    it('should return number of clusters', () => {
      clusterConfig.clusters.set('cluster1', { name: 'cluster1' });
      clusterConfig.clusters.set('cluster2', { name: 'cluster2' });

      expect(clusterConfig.count()).toBe(2);
    });
  });
});
