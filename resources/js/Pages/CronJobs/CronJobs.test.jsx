import { render, screen } from '@testing-library/react';
import { test, expect, vi } from 'vitest';
import CronJobsIndex from './Index';

// Stub @inertiajs/react so the component (and future imports) don't need Echo/Ziggy
vi.mock('@inertiajs/react', () => ({
    Head: ({ title }) => <title>{title}</title>,
    router: { post: vi.fn(), delete: vi.fn() },
    usePage: () => ({ props: { auth: { user: { id: 1, role: 'user', username: 'testuser' } } } }),
    Link: ({ href, children, ...rest }) => <a href={href} {...rest}>{children}</a>,
}));

// Stub AuthenticatedLayout (not yet used in stub but safe for future)
vi.mock('@/Layouts/AuthenticatedLayout', () => ({
    default: ({ children, header }) => (
        <div>
            <div data-testid="header">{header}</div>
            <div data-testid="content">{children}</div>
        </div>
    ),
}));

// Stub route() global
global.route = (name, params) => {
    const map = {
        'cron-jobs.store': '/cron-jobs',
        'cron-jobs.destroy': '/cron-jobs/delete',
        'cron-jobs.toggle': '/cron-jobs/toggle',
        'cron-jobs.index': '/cron-jobs',
    };
    if (params) return (map[name] ?? `/${name}`) + '/' + (params.cronJob ?? '');
    return map[name] ?? `/${name}`;
};

test('renders cron job count when cronJobs prop provided', () => {
    const cronJobs = [
        { id: 1, schedule: '* * * * *', command: 'php /home/testuser_ln/artisan inspire', label: 'Every minute', active: true },
        { id: 2, schedule: '0 2 * * *', command: 'php /home/testuser_ln/artisan schedule:run', label: null, active: false },
    ];

    render(<CronJobsIndex cronJobs={cronJobs} />);

    // Stub renders cronJobs.length — 2 jobs → '2'
    expect(screen.getByText('2')).toBeInTheDocument();
});

test('renders zero when no cron jobs', () => {
    render(<CronJobsIndex cronJobs={[]} />);

    expect(screen.getByText('0')).toBeInTheDocument();
});
