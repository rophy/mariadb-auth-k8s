const request = require('supertest');
const ClusterConfig = require('../src/cluster-config');
const createServer = require('../src/server');

describe('Server HTTP Status Codes', () => {
  let app;
  let clusterConfig;

  beforeEach(() => {
    // Create mock cluster config
    clusterConfig = new ClusterConfig();
    clusterConfig.clusters.set('test-cluster', {
      name: 'test-cluster',
      issuer: 'https://kubernetes.test.local',
      api_server: 'https://test-api:6443'
    });

    app = createServer(clusterConfig);
  });

  describe('POST /api/v1/validate - HTTP Status Codes', () => {
    it('should return 400 for missing cluster_name', async () => {
      const response = await request(app)
        .post('/api/v1/validate')
        .send({ token: 'some-token' });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('invalid_request');
      expect(response.body.message).toContain('cluster_name');
    });

    it('should return 400 for missing token', async () => {
      const response = await request(app)
        .post('/api/v1/validate')
        .send({ cluster_name: 'test-cluster' });

      expect(response.status).toBe(400);
      expect(response.body.error).toBe('invalid_request');
      expect(response.body.message).toContain('token');
    });

    it('should return 400 for cluster_not_found error', async () => {
      const response = await request(app)
        .post('/api/v1/validate')
        .send({
          cluster_name: 'unknown-cluster',
          token: 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.invalid'
        });

      expect(response.status).toBe(400);
      expect(response.body.authenticated).toBe(false);
      expect(response.body.error).toBe('cluster_not_found');
    });

    it('should return 401 for invalid token format', async () => {
      const response = await request(app)
        .post('/api/v1/validate')
        .send({
          cluster_name: 'test-cluster',
          token: 'not-a-valid-jwt'
        });

      expect(response.status).toBe(401);
      expect(response.body.authenticated).toBe(false);
      expect(response.body.error).toBe('invalid_token');
    });

    it('should return 401 for expired token', async () => {
      // This is a token with exp in the past
      const expiredToken = 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCIsImtpZCI6InRlc3Qta2V5In0.eyJrdWJlcm5ldGVzLmlvL3NlcnZpY2VhY2NvdW50L25hbWVzcGFjZSI6ImRlZmF1bHQiLCJrdWJlcm5ldGVzLmlvL3NlcnZpY2VhY2NvdW50L3NlcnZpY2UtYWNjb3VudC5uYW1lIjoidGVzdC11c2VyIiwiaXNzIjoiaHR0cHM6Ly9rdWJlcm5ldGVzLnRlc3QubG9jYWwiLCJleHAiOjE2MDA4MDAwMDB9.fake';

      const response = await request(app)
        .post('/api/v1/validate')
        .send({
          cluster_name: 'test-cluster',
          token: expiredToken
        });

      expect(response.status).toBe(401);
      expect(response.body.authenticated).toBe(false);
      // Could be token_expired or invalid_signature depending on which check fails first
      expect(['token_expired', 'invalid_token', 'invalid_signature']).toContain(response.body.error);
    });
  });

  describe('GET /health', () => {
    it('should return 200 with status ok', async () => {
      const response = await request(app).get('/health');

      expect(response.status).toBe(200);
      expect(response.body.status).toBe('ok');
      expect(response.body.clusters).toBe(1);
    });
  });

  describe('GET /api/v1/clusters', () => {
    it('should return list of clusters', async () => {
      const response = await request(app).get('/api/v1/clusters');

      expect(response.status).toBe(200);
      expect(response.body.clusters).toEqual(['test-cluster']);
      expect(response.body.count).toBe(1);
    });
  });

  describe('404 handler', () => {
    it('should return 404 for unknown endpoints', async () => {
      const response = await request(app).get('/unknown');

      expect(response.status).toBe(404);
      expect(response.body.error).toBe('not_found');
    });
  });
});
