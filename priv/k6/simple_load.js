import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
  scenarios: {
    simple_test: {
      executor: 'per-vu-iterations',
      vus: 5,              // 5 virtual users
      iterations: 10,      // 10 iterations each = 50 total requests
      maxDuration: '30s',  // Complete within 30 seconds
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  }
};

function generateRandomToken() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let token = '';
  for (let i = 0; i < 32; i++) {
    token += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return token;
}

export default function () {
  const baseUrl = __ENV.BASE_URL || "https://localhost:4001";

  // Each VU uses a unique token (creates different sessions for load distribution testing)
  const vuToken = `vu${__VU}_${generateRandomToken()}`;

  const params = {
    headers: {
      'Host': 'seveneat.com',
      'Authorization': `Bearer ${vuToken}`,
    },
  };

  const res = http.get(baseUrl, params);

  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time ok': (r) => r.timings.duration < 1000,
  });

  sleep(1); // Wait 1s between requests (spreads 50 requests over ~10 seconds)
}
