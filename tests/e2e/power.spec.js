import { test, expect } from '@playwright/test';
import { execFileSync } from 'node:child_process';

// Browser-level proof of the Power page against the lab container (`make up`).
// The lab is a full install (panel DB = hosting DB), so: Reverb can sleep, the hosting DB cannot.
const LAB = process.env.LAB_CONTAINER || 'laranode-lab';
const BIN = process.env.LAB_BIN || '/home/laranode_ln/panel/laranode-scripts/bin';

const lab = (cmd) => execFileSync('docker', ['exec', LAB, 'bash', '-c', cmd], { encoding: 'utf8', env: { ...process.env, MSYS_NO_PATHCONV: '1' } });

async function login(page) {
    await page.goto('/login');
    await page.fill('input#email', 'admin@laranode.test');
    await page.fill('input#password', 'password');
    await page.click('button:has-text("Log in")');
    await page.waitForURL(/dashboard/);
}

test.beforeAll(() => {
    // the lab's Reverb can crash-restart (systemd revives it in ~5 s); start from a settled "active"
    lab('for i in $(seq 1 30); do systemctl is-active --quiet laranode-reverb.service && sleep 2 && systemctl is-active --quiet laranode-reverb.service && exit 0; sleep 1; done; exit 1');
    // what the installer does: register only what Laranode installed (sleep stays OFF until toggled)
    // The manifest is required (fail closed): the lab is a full Laranode install, so it lists
    // every service as managed:true (the installer writes this file on a real host).
    lab(`mkdir -p /etc/laranode && printf '%s\\n' '{"version":1,"services":[' '{"unit":"laranode-reverb.service","managed":true,"role":"reverb","reason":"lab"},' '{"unit":"laranode-queue-worker.service","managed":true,"role":"queue","reason":"lab"},' '{"unit":"php8.4-fpm.service","managed":true,"role":"php","reason":"lab"},' '{"unit":"mysql.service","managed":true,"role":"database","reason":"lab"}' ']}' > /etc/laranode/service-manifest.json && chmod 644 /etc/laranode/service-manifest.json`);
    lab(`bash ${BIN}/laranode-managed-register.sh reverb queue fpm hostdb`);
});

test.afterAll(() => {
    try { lab(`${BIN}/laranode-sleep.sh reverb disable`); } catch { /* already off */ }
});

test('Power page: badge, toggle, idle minutes, manual wake', async ({ page }) => {
    await login(page);
    await page.goto('/admin/power');
    await expect(page.getByRole('heading', { name: 'Power' })).toBeVisible();

    // every service has a state badge; Reverb is up and sleep is off by default
    await expect(page.getByTestId('state-reverb')).toHaveText(/running/i, { timeout: 20000 });
    await expect(page.getByRole('checkbox', { name: 'sleep reverb' })).not.toBeChecked({ timeout: 30000 });

    // panel DB shares the hosting DB instance: it can never be put to sleep
    await expect(page.getByText(/cannot sleep: panel DB/i)).toBeVisible();
    await expect(page.getByRole('checkbox', { name: 'sleep hostdb' })).toBeDisabled();

    // toggle on with 1 idle minute: the socket takes over, the real service sleeps
    await page.getByLabel('idle minutes for reverb').fill('1');
    await page.getByRole('checkbox', { name: 'sleep reverb' }).click();
    await expect(page.getByRole('checkbox', { name: 'sleep reverb' })).toBeChecked({ timeout: 30000 });
    await expect(page.getByTestId('state-reverb')).toHaveText(/sleeping/i, { timeout: 30000 });

    // manual wake
    await page.getByRole('button', { name: 'wake reverb' }).click();
    await expect(page.getByTestId('state-reverb')).toHaveText(/running/i, { timeout: 30000 });

    // toggle off restores the original state
    await page.getByRole('checkbox', { name: 'sleep reverb' }).click();
    await expect(page.getByRole('checkbox', { name: 'sleep reverb' })).not.toBeChecked({ timeout: 30000 });
    await expect(page.getByTestId('state-reverb')).toHaveText(/running/i, { timeout: 15000 });
});

test('Power page is admin-only', async ({ page, request }) => {
    const res = await request.get('/admin/power/status', { failOnStatusCode: false, maxRedirects: 0 });
    expect([302, 401, 403]).toContain(res.status());
});
