import { test, expect } from '@playwright/test';

// End-to-end smokes for the surfaces touched by the PR#13 review fixes. These
// are the pages whose privileged work now runs through a different mechanism
// (allowlisted ufw wrapper, root cron drop-in, engine-aware database stats), so
// they are worth driving in a browser — a passing unit test would not catch a
// sudoers path that the web SAPI cannot actually execute.

const login = async (page) => {
    await page.goto('/login');
    await page.fill('input#email', 'admin@laranode.test');
    await page.fill('input#password', 'password');
    await page.click('button:has-text("Log in")');
    await page.waitForURL(/dashboard/);
};

// TopNavi renders exactly one theme button per authenticated layout.
const toggleTheme = (page) => page.locator('nav button.font-bold').first();

const expectDarkModeRoundTrip = async (page) => {
    await toggleTheme(page).click();
    await expect(page.locator('html')).toHaveClass(/dark/);

    await toggleTheme(page).click();
    await expect(page.locator('html')).not.toHaveClass(/dark/);
};

test('firewall page reports the real UFW status through the allowlisted wrapper', async ({ page }) => {
    await login(page);
    await page.goto('/admin/firewall');
    await expect(page.getByRole('heading', { name: /firewall/i }).first()).toBeVisible();

    // The badge comes from `laranode-ufw.sh status` via www-data's sudo grant.
    // If the wrapper or its drop-in were wrong the page would render "Unknown".
    await expect(page.getByText(/active/i).first()).toBeVisible();

    await expectDarkModeRoundTrip(page);
});

test('backups page renders and still offers the create form', async ({ page }) => {
    await login(page);
    await page.goto('/backups');
    await expect(page.getByRole('heading', { name: /backups/i }).first()).toBeVisible();

    await expectDarkModeRoundTrip(page);
});

test('databases page renders while an engine is unreachable', async ({ page }) => {
    await login(page);
    await page.goto('/databases');
    await expect(page.getByRole('heading', { name: /databases/i }).first()).toBeVisible();

    await expectDarkModeRoundTrip(page);
});

test('cron page renders for an admin', async ({ page }) => {
    await login(page);
    await page.goto('/cron-jobs');
    await expect(page.getByRole('heading', { name: /cron/i }).first()).toBeVisible();

    await expectDarkModeRoundTrip(page);
});
