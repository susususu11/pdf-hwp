import assert from 'node:assert';
import { textFromRuns } from '../assets/converter/core.js';
const r = (text, x, y, w = 30, h = 14) => ({ text, x, y, w, h });
assert.strictEqual(textFromRuns([]), '');
assert.strictEqual(textFromRuns([r('기술', 10, 20, 30), r('지원', 40, 20, 30)]), '기술지원');
assert.strictEqual(textFromRuns([r('구분', 10, 20, 30), r('예산', 100, 20, 30)]), '구분 예산');
assert.strictEqual(textFromRuns([r('첫 줄', 10, 20), r('둘째 줄', 10, 40)]), '첫 줄\n둘째 줄');
assert.strictEqual(textFromRuns([r('오른쪽 칸', 300, 20), r('왼쪽 칸', 10, 20)]), '오른쪽 칸\n왼쪽 칸');
console.log('text ok');
