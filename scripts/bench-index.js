// k6 压测脚本：打索引接口的**本地命中**态（并发扩展性）。
// 上游隔离由 bench.sh 负责（official 读路径已关闭，回源只会落到桩服务）。
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE || 'http://127.0.0.1:18080';
const PATH = '/index/be/nc/bench-alpha?organization=benchorg0';

export default function () {
  const res = http.get(BASE + PATH);
  check(res, { 'status is 200': (r) => r.status === 200 });
}
