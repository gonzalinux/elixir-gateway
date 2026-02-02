import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
  vus: 10,
  duration: '60s',
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  }
};

let requestCount = 0;
let currentToken = generateRandomToken();

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

  // Generate new token every 60 requests
  if (requestCount % 60 === 0) {
    currentToken = generateRandomToken();
  }
  requestCount++;

  const params = {
    headers: {
      'Host': 'seveneat.com',
      'Authorization': `Bearer ${currentToken}`,
    },
  };

  const res = http.get(baseUrl, params);

  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time ok': (r) => r.timings.duration < 1000,
  });

  sleep(0.1);
}
