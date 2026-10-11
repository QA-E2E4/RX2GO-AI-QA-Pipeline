import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';

const input = path.resolve('reports/results.json');
if (!fs.existsSync(input)) {
  console.error('reports/results.json not found. Run Playwright tests first.');
  process.exit(1);
}

const report = JSON.parse(fs.readFileSync(input, 'utf8'));
const tests: Array<{ title: string; status: string; error?: string }> = [];

function walkSuite(suite: any, parents: string[] = []) {
  const prefix = [...parents, suite.title].filter(Boolean);

  for (const spec of suite.specs ?? []) {
    for (const t of spec.tests ?? []) {
      const result = t.results?.[t.results.length - 1];
      tests.push({
        title: [...prefix, spec.title].filter(Boolean).join(' > '),
        status: result?.status ?? t.status ?? 'unknown',
        error: result?.error?.message
      });
    }
  }

  for (const child of suite.suites ?? []) walkSuite(child, prefix);
}

for (const suite of report.suites ?? []) walkSuite(suite);

const normalize = (s: string) => {
  if (s === 'passed') return 'PASS';
  if (s === 'skipped') return 'SKIP';
  if (s === 'failed' || s === 'timedOut') return 'FAIL';
  return 'BLOCKED';
};

const mapped = tests.map(t => ({ ...t, qa: normalize(t.status) }));
const overall = mapped.some(t => t.qa === 'FAIL') ? 'FAIL' : mapped.some(t => t.qa === 'BLOCKED') ? 'BLOCKED' : 'PASS';
const date = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Warsaw' }).format(new Date());

const lines = [
  `*TESTING REPORT*`,
  ``,
  `*Task:* Rx2GO automated regression`,
  `*Environment:* ${process.env.TEST_ENV ?? 'HOT'}`,
  `*Date:* ${date}`,
  `*User:* ${process.env.QA_USER ?? 'QA automation'}`,
  `*Method:* ${process.env.TEST_METHOD ?? 'Automated E2E: Playwright'}`,
  `*Result:* ${overall}`,
  ``,
  `*Scenarios:*`,
  ...mapped.map(t => `- ${t.qa} — ${t.title}${t.error ? ` — ${t.error.split('\n')[0]}` : ''}`),
  ``,
  `*Evidence:* Playwright HTML report, screenshots/video/trace on failure, Allure results.`
];

fs.mkdirSync('reports', { recursive: true });
const output = path.resolve('reports/jira-report.md');
fs.writeFileSync(output, lines.join('\n'));
console.log(lines.join('\n'));
console.log(`\nSaved: ${output}`);

